"""Pinned TLS transport between this VM and fixed host codec/audio services.

No SSH, media files, selectable upstream endpoints, or unbounded queues.
Each connection has one I/O thread, including both directions of its SSL object.
"""
import argparse
from collections import deque
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import select
import socket
import ssl
import threading
import time

LIMIT = 256 * 1024


def exact(connection, size):
    result = bytearray()
    while len(result) < size:
        data = connection.recv(size - len(result))
        if not data:
            raise EOFError('Transport closed')
        result.extend(data)
    return bytes(result)


def relay(a, b):
    endpoints = (a, b)
    pending = (deque(), deque())
    offsets, sizes = [0, 0], [0, 0]
    read_wants, write_wants = [1, 1], [2, 2]
    ended = [False, False]
    started = activity = time.monotonic()
    copied = [0, 0]
    for connection in endpoints:
        connection.setblocking(False)
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    while True:
        now = time.monotonic()
        if now - activity > 300 or now - started > 3600:
            raise TimeoutError('Media connection deadline')
        if any(ended[i] and not pending[1-i] for i in range(2)):
            return copied
        readable, writable = [], []
        buffered = set()
        for i, connection in enumerate(endpoints):
            mask = 0
            if not ended[i] and sizes[1-i] < LIMIT:
                mask |= read_wants[i]
                if isinstance(connection, ssl.SSLSocket) and connection.pending():
                    buffered.add(connection)
            if pending[i]:
                mask |= write_wants[i]
            if mask & 1:
                readable.append(connection)
            if mask & 2:
                writable.append(connection)
        ready_read, ready_write, _ = select.select(readable, writable, [], 0 if buffered else 1)
        ready_read = set(ready_read) | buffered
        ready_write = set(ready_write)
        for i, connection in enumerate(endpoints):
            if pending[i] and connection in (ready_read if write_wants[i] == 1 else ready_write):
                try:
                    count = connection.send(memoryview(pending[i][0])[offsets[i]:])
                    if not count:
                        raise EOFError('Media write closed')
                    offsets[i] += count
                    sizes[i] -= count
                    copied[i] += count
                    if offsets[i] == len(pending[i][0]):
                        pending[i].popleft()
                        offsets[i] = 0
                    write_wants[i] = 2
                    activity = time.monotonic()
                except ssl.SSLWantReadError:
                    write_wants[i] = 1
                except (ssl.SSLWantWriteError, BlockingIOError):
                    write_wants[i] = 2
            if not ended[i] and sizes[1-i] < LIMIT and connection in (ready_read if read_wants[i] == 1 else ready_write):
                try:
                    data = connection.recv(min(65536, LIMIT-sizes[1-i]))
                    if not data:
                        ended[i] = True
                    else:
                        pending[1-i].append(data)
                        sizes[1-i] += len(data)
                        activity = time.monotonic()
                    read_wants[i] = 1
                except ssl.SSLWantWriteError:
                    read_wants[i] = 2
                except (ssl.SSLWantReadError, BlockingIOError):
                    read_wants[i] = 1


def load(path, host):
    config = json.loads(path.read_text(encoding='utf-8-sig'))
    required = ({'listenAddress','listenPort','certificate','privateKey','secretFile','codecPort','audioPort'} if host else
                {'hostAddress','hostPort','certificate','certificateSHA256','secret','audio'})
    if not isinstance(config, dict) or set(config) != required:
        raise ValueError('Unexpected direct-media configuration fields')
    address = ipaddress.ip_address(config['listenAddress' if host else 'hostAddress'])
    if address.version != 4 or address.is_unspecified or address.is_multicast or address.is_loopback:
        raise ValueError('An explicit host IPv4 interface is required')
    for key in (('listenPort','codecPort','audioPort') if host else ('hostPort',)):
        if type(config[key]) is not int or not 1024 <= config[key] <= 65535:
            raise ValueError('Invalid media port')
    if host:
        if len({config['listenPort'],config['codecPort'],config['audioPort']}) != 3:
            raise ValueError('Distinct media ports are required')
        for key in ('certificate','privateKey','secretFile'):
            value = Path(config[key])
            config[key] = value if value.is_absolute() else path.resolve().parent/value
        secret = config['secretFile'].read_bytes()
    else:
        certificate = Path(config['certificate'])
        config['certificate'] = certificate if certificate.is_absolute() else path.resolve().parent/certificate
        secret = bytes.fromhex(config['secret'])
        if len(bytes.fromhex(config['certificateSHA256'])) != 32 or type(config['audio']) is not bool:
            raise ValueError('Invalid certificate pin or audio selection')
    if len(secret) != 32:
        raise ValueError('A 256-bit media client secret is required')
    return config, secret


def connect_host(config, secret, context, channel):
    plain = secure = None
    try:
        plain = socket.create_connection((config['hostAddress'],config['hostPort']),timeout=5)
        secure = context.wrap_socket(plain,server_hostname='NativeMacMedia')
        if secure.selected_alpn_protocol() != 'nativemac-media/1':
            raise ValueError('Unknown media TLS protocol')
        certificate = hashlib.sha256(secure.getpeercert(binary_form=True)).hexdigest()
        if not hmac.compare_digest(certificate,config['certificateSHA256'].lower()):
            raise ValueError('Media host certificate pin mismatch')
        secure.sendall(b'NMT1'+channel+secret)
        if exact(secure,1) != b'A':
            raise ValueError('Media host refused session')
        return secure
    except BaseException:
        if secure:secure.close()
        elif plain:plain.close()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('host','guest'))
    parser.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    host = args.mode == 'host'
    config, secret = load(args.config, host)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if host else ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['nativemac-media/1'])
    if host:
        context.load_cert_chain(str(config['certificate']), str(config['privateKey']))
    else:
        # A dedicated CA set checks expiry and the fixed service hostname;
        # additionally pin the exact leaf before sending credentials/media.
        # No system trust store is changed.
        context.load_verify_locations(cafile=str(config['certificate']))
    slots = threading.BoundedSemaphore(6)

    def connection(local, channel=None):
        upstream = secure = None
        started = time.monotonic()
        try:
            local.settimeout(5)
            if host:
                secure = context.wrap_socket(local, server_side=True)
                if secure.selected_alpn_protocol() != 'nativemac-media/1':
                    raise ValueError('Unknown media TLS protocol')
                preface = exact(secure,37)
                if preface[:4] != b'NMT1' or preface[4:5] not in (b'V',b'A') or not hmac.compare_digest(preface[5:],secret):
                    raise ValueError('Media authentication failed')
                channel = preface[4:5]
                port = config['codecPort' if channel == b'V' else 'audioPort']
                upstream = socket.create_connection(('127.0.0.1',port),timeout=5)
                secure.sendall(b'A')
                counts = relay(secure,upstream)
            else:
                secure = connect_host(config,secret,context,channel)
                counts = relay(secure,local)
            print(json.dumps({'stage':'direct-media-closed','channel':channel.decode(),'bytes':counts,'seconds':round(time.monotonic()-started,3)}),flush=True)
        except (OSError,EOFError,ValueError,TimeoutError) as error:
            print(json.dumps({'stage':'direct-media-error','error':type(error).__name__}),flush=True)
        finally:
            for value in (secure,upstream,local):
                if value:
                    value.close()
            slots.release()

    listeners = []
    targets = [(config['listenAddress'],config['listenPort'],None)] if host else [('127.0.0.1',54885,b'V')]+([('127.0.0.1',54886,b'A')] if config['audio'] else [])
    for address,port,channel in targets:
        listener = socket.socket()
        if host and hasattr(socket,'SO_EXCLUSIVEADDRUSE'):
            listener.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
        else:
            listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        listener.bind((address,port))
        listener.listen(6)
        listeners.append((listener,channel))
    print(json.dumps({'stage':'direct-media-ready','mode':args.mode,'ports':[port for _,port,_ in targets]}),flush=True)
    while True:
        ready,_,_ = select.select([value for value,_ in listeners],[],[])
        for listener,channel in listeners:
            if listener not in ready:
                continue
            client,_ = listener.accept()
            if not slots.acquire(blocking=False):
                client.close()
                continue
            threading.Thread(target=connection,args=(client,channel),daemon=True).start()


if __name__ == '__main__':
    main()
