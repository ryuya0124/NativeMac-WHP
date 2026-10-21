"""Send standard RFB input to the development VM's loopback input channel."""
import argparse
import socket
import struct
import time

p = argparse.ArgumentParser()
p.add_argument('--text')
p.add_argument('--key', action='append', default=[])
p.add_argument('--click', nargs=2, type=int)
p.add_argument('--move', nargs=2, type=int)
p.add_argument('--wheel', type=int, default=0, help='Wheel notches: positive up, negative down')
p.add_argument('--guest-size', nargs=2, type=int, default=[1280, 800])
a = p.parse_args()
keys = {'enter': 0xff0d, 'tab': 0xff09, 'escape': 0xff1b,
        'up': 0xff52, 'down': 0xff54, 'left': 0xff51, 'right': 0xff53,
        'shift': 0xffe1, 'ctrl': 0xffe3, 'alt': 0xffe9, 'meta': 0xffeb}

with socket.create_connection(('127.0.0.1', 5905), timeout=10) as s:
    def read(n):
        b = bytearray()
        while len(b) < n:
            v = s.recv(n - len(b))
            if not v:
                raise EOFError('RFB closed')
            b.extend(v)
        return bytes(b)

    read(12)
    s.sendall(b'RFB 003.008\n')
    assert 1 in read(read(1)[0])
    s.sendall(b'\x01')
    assert read(4) == b'\0' * 4
    s.sendall(b'\x01')
    width, height = struct.unpack('>HH', read(4))
    read(16)
    read(struct.unpack('>I', read(4))[0])

    def key(code, down):
        s.sendall(struct.pack('>BBHI', 4, int(down), 0, code))
        time.sleep(0.015)

    if a.click or a.move:
        x, y = a.click or a.move
        x = min(width - 1, max(0, round(x * width / a.guest_size[0])))
        y = min(height - 1, max(0, round(y * height / a.guest_size[1])))
        s.sendall(struct.pack('>BBHH', 5, 0, x, y))
        if a.click:
            s.sendall(struct.pack('>BBHH', 5, 1, x, y))
            time.sleep(0.05)
            s.sendall(struct.pack('>BBHH', 5, 0, x, y))
        for _ in range(min(abs(a.wheel), 120)):
            s.sendall(struct.pack('>BBHH', 5, 8 if a.wheel > 0 else 16, x, y))
            s.sendall(struct.pack('>BBHH', 5, 0, x, y))
            time.sleep(0.025)
    if a.text:
        for char in a.text:
            code = 0xff0d if char == '\n' else ord(char)
            key(code, True)
            key(code, False)
    for chord in a.key:
        codes = [keys[v.lower()] if v.lower() in keys else ord(v) for v in chord.split('+')]
        for code in codes:
            key(code, True)
        for code in reversed(codes):
            key(code, False)
    time.sleep(0.15)
print('Input sent to the VM over loopback RFB.')
