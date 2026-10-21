"""Render an explicit BGRA32 guest framebuffer dump, without changing pixels."""
import argparse
import pathlib
import struct
import zlib

p = argparse.ArgumentParser()
p.add_argument('input')
p.add_argument('output')
p.add_argument('--width', type=int, required=True)
p.add_argument('--height', type=int, required=True)
a = p.parse_args()
raw = pathlib.Path(a.input).read_bytes()
assert len(raw) >= a.width * a.height * 4
rgb = bytearray(a.width * a.height * 3)
rgb[0::3], rgb[1::3], rgb[2::3] = raw[2::4], raw[1::4], raw[0::4]
filtered = b''.join(b'\0' + rgb[y*a.width*3:(y+1)*a.width*3] for y in range(a.height))

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', a.width, a.height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(filtered)) + chunk(b'IEND', b'')
pathlib.Path(a.output).write_bytes(png)
