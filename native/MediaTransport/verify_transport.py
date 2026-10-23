"""Check pinned TLS authentication and duplex/EOF behavior with authored bytes.

Uses private local host configuration. Does not save media, display credentials,
or establish an SSH connection. Run beside the owned host TLS service.
"""
import argparse
import hashlib
import json
import random
import socket
import ssl
import threading
from pathlib import Path
from transport import load, connect_host, exact, relay


def client_context(certificate):
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['nativemac-media/1'])
    if certificate:context.load_verify_locations(cafile=str(certificate))
    return context


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-config',type=Path,required=True)
    args=parser.parse_args()
    host,secret=load(args.host_config,True)
    certificate=host['certificate']
    der=ssl.PEM_cert_to_DER_cert(certificate.read_text())
    config={'hostAddress':host['listenAddress'],'hostPort':host['listenPort'],
            'certificateSHA256':hashlib.sha256(der).hexdigest()}
    context=client_context(certificate)
    verified=[]
    for name,choice,token,ctx in [
        ('wrong-certificate-pin',dict(config,certificateSHA256='00'*32),secret,context),
        ('wrong-client-secret',config,bytes(value^255 for value in secret),context),
        ('untrusted-certificate',config,secret,client_context(None))]:
        try:
            connection=connect_host(choice,token,ctx,b'V');connection.close()
        except (ValueError,EOFError,OSError):verified.append(name)
        else:raise AssertionError(name+' unexpectedly authenticated')
    connection=connect_host(config,secret,context,b'V');connection.close()
    verified.append('correct-pin-and-secret')
    # Separate local TLS fixture: no codec worker, app content or network media.
    server_context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(str(certificate),str(host['privateKey']))
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(1)
    left,right=socket.socketpair();errors=[];counts=[]
    def echo():
        try:
            right.settimeout(10)
            while True:
                data=right.recv(65536)
                if not data:break
                right.sendall(data)
        except BaseException as error:errors.append(type(error).__name__)
        finally:right.close()
    def forward():
        secure=None
        try:
            accepted,_=listener.accept();accepted.settimeout(5)
            secure=server_context.wrap_socket(accepted,server_side=True)
            counts.extend(relay(secure,left))
        except BaseException as error:errors.append(type(error).__name__)
        finally:
            if secure:secure.close()
            left.close();listener.close()
    workers=[threading.Thread(target=echo),threading.Thread(target=forward)]
    for worker in workers:worker.start()
    total=0
    with socket.create_connection(listener.getsockname(),timeout=5) as plain:
        with context.wrap_socket(plain,server_hostname='NativeMacMedia') as secure:
            secure.settimeout(10);secure.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            rng=random.Random(580)
            for size in [1,7,65535,262144]*16:
                payload=rng.randbytes(size)
                secure.sendall(payload)
                assert exact(secure,size)==payload
                total+=size
    for worker in workers:
        worker.join(10)
        assert not worker.is_alive(),'Duplex/EOF fixture did not finish'
    assert not errors,errors
    assert counts==[total,total],counts
    print(json.dumps({'passed':True,'authenticationChecks':verified,'duplexBytesEachDirection':total,'eofDrained':True,'sshUsed':False}))


if __name__=='__main__':main()
