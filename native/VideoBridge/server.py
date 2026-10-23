"""Experimental loopback streaming NVDEC service for the authored VT probe.

Only fixed codec/dimension/configuration fields cross the boundary. No caller
can select an executable, path, GPU index or FFmpeg arguments. Not installed or
selected by ordinary macOS apps yet. The transport currently copies NV12 bytes.
"""
import argparse
import base64
import json
from pathlib import Path
import socket
import socketserver
import struct
import threading

from stream import Decoder

MAX_PACKET = 8 * 1024 * 1024


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise EOFError('Truncated stream')
        result.extend(part)
    return bytes(result)


def read_message(connection, limit):
    length, = struct.unpack('!I', read_exact(connection, 4))
    if not 1 <= length <= limit:
        raise ValueError('Invalid message length')
    return read_exact(connection, length)


def write_message(connection, body):
    connection.sendall(struct.pack('!I', len(body)) + body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port, ffmpeg):
        self.ffmpeg = ffmpeg
        self.slots = threading.BoundedSemaphore(2)
        super().__init__(('127.0.0.1', port), Handler)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        if not self.server.slots.acquire(blocking=False):
            return
        decoder = None
        try:
            self.request.settimeout(20)
            request = json.loads(read_message(self.request, 100000))
            if set(request) != {'version', 'codec', 'width', 'height', 'configuration'}:
                raise ValueError('Invalid session fields')
            if request['version'] != 1 or request['codec'] not in ('h264', 'hevc'):
                raise ValueError('Unsupported session version or codec')
            if type(request['width']) is not int or type(request['height']) is not int:
                raise ValueError('Dimensions must be integers')
            configuration = base64.b64decode(request['configuration'], validate=True)
            decoder = Decoder(self.server.ffmpeg, request['codec'], request['width'],
                              request['height'], configuration)
            write_message(self.request, b'A')
            self.request.settimeout(300)
            feed_errors = []

            def feed():
                try:
                    while True:
                        body = read_message(self.request, MAX_PACKET + 10)
                        if body == b'F':
                            decoder.finish()
                            return
                        if len(body) < 11 or body[:1] != b'P' or body[9] not in (0, 1):
                            raise ValueError('Invalid compressed packet')
                        timestamp, = struct.unpack('!q', body[1:9])
                        decoder.send(body[10:], timestamp, bool(body[9]))
                except (EOFError, OSError, ValueError, RuntimeError, TimeoutError) as error:
                    feed_errors.append(type(error).__name__)
                    decoder.close()

            sender = threading.Thread(target=feed, daemon=True)
            sender.start()
            frames = 0
            while True:
                frame = decoder.receive(timeout=300)
                if frame is None:
                    break
                pixels, metadata = frame
                numerator, denominator = metadata['timeBase']
                ns = (metadata['pts'] * numerator * 1000000000) // denominator
                write_message(self.request, b'R' + struct.pack('!q', ns) + pixels)
                frames += 1
            if feed_errors or decoder.errors or decoder.process.wait(timeout=5):
                raise RuntimeError('Hardware stream failed')
            write_message(self.request, b'E' + struct.pack('!I', frames))
            sender.join(timeout=2)
        except (EOFError, OSError, ValueError, RuntimeError, TimeoutError):
            try:
                write_message(self.request, b'X')
            except OSError:
                pass
        finally:
            if decoder:
                decoder.close()
            try:
                self.request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.server.slots.release()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=54883)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    args = parser.parse_args()
    if not args.ffmpeg.is_file():
        parser.error('FFmpeg executable missing')
    print(json.dumps({'listener': '127.0.0.1', 'port': args.port,
                      'sessions': 2, 'softwareFallback': False}), flush=True)
    with Server(args.port, args.ffmpeg) as server:
        server.serve_forever()
