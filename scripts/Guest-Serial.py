"""Log the development VM's serial port and submit local diagnostic commands."""
import pathlib
import socket
import time

root = pathlib.Path(__file__).resolve().parent.parent
commands = root / 'artifacts/guest-command.txt'
if commands.exists():
    commands.unlink()
with socket.create_connection(('127.0.0.1', 5906), timeout=10) as sock, (root / 'artifacts/guest-serial.log').open('wb') as log:
    sock.settimeout(0.2)
    print('Serial logger connected to loopback port 5906.', flush=True)
    while True:
        try:
            data = sock.recv(65536)
            if not data:
                break
            log.write(data)
            log.flush()
        except socket.timeout:
            pass
        if commands.exists():
            text = commands.read_text(encoding='utf-8')
            commands.unlink()
            sock.sendall(text.replace('\r\n', '\n').replace('\n', '\r').encode())
            print('Submitted guest diagnostic command.', flush=True)
