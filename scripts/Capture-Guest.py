"""Read the development VMM's loopback RFB framebuffer for boot diagnostics."""
import argparse
import pathlib
import socket
import struct
import zlib

parser = argparse.ArgumentParser()
parser.add_argument('output')
parser.add_argument('--port', type=int, default=5905)
args = parser.parse_args()


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


with socket.create_connection(('127.0.0.1', args.port), timeout=15) as sock:
    def read(size):
        data = bytearray()
        while len(data) < size:
            part = sock.recv(size - len(data))
            if not part:
                raise EOFError('RFB server closed')
            data.extend(part)
        return bytes(data)

    version = read(12)
    if not version.startswith(b'RFB 003.'):
        raise ValueError(version)
    sock.sendall(b'RFB 003.008\n')
    security = read(read(1)[0])
    if 1 not in security:
        raise ValueError('Expected development server with no authentication on loopback')
    sock.sendall(b'\x01')
    if read(4) != b'\0\0\0\0':
        raise ValueError('RFB security refused')
    sock.sendall(b'\x01')
    width, height = struct.unpack('>HH', read(4))
    read(16)
    read(struct.unpack('>I', read(4))[0])
    sock.sendall(struct.pack('>BBBBBBBBHHHBBB3x', 0, 0, 0, 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    sock.sendall(struct.pack('>BBHi', 2, 0, 1, 0))
    sock.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, width, height))
    pixels = bytearray(width * height * 3)
    if read(1) != b'\0':
        raise ValueError('Expected framebuffer update')
    read(1)
    count = struct.unpack('>H', read(2))[0]
    for _ in range(count):
        x, y, w, h, encoding = struct.unpack('>HHHHi', read(12))
        if encoding != 0:
            raise ValueError(f'Unexpected encoding {encoding}')
        raw = read(w * h * 4)
        for row in range(h):
            dest = ((y + row) * width + x) * 3
            source = row * w * 4
            for col in range(w):
                b, g, r, _a = raw[source + col * 4:source + col * 4 + 4]
                pixels[dest + col * 3:dest + col * 3 + 3] = bytes((r, g, b))
    filtered = b''.join(b'\0' + pixels[row * width * 3:(row + 1) * width * 3] for row in range(height))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(filtered)) + chunk(b'IEND', b'')
    pathlib.Path(args.output).write_bytes(png)
    print(f'Captured guest framebuffer: {width}x{height}, {count} rectangles')
