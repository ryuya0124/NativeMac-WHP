"""Temporary, token-scoped file and command channel for this development VM."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import secrets
import shutil
import argparse
import socket

parser = argparse.ArgumentParser()
parser.add_argument('--bind', required=True, help='Windows LAN address reachable from the guest')
parser.add_argument('--port', type=int, default=5907)
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
state = root / 'artifacts/guest-channel.json'
token = secrets.token_hex(24)
address = args.bind
port = args.port
files = {
    'InstallAssistant.pkg': root / 'backend/media/InstallAssistant-26.6.2.pkg',
    'Installer.cpio': root / 'backend/media/Installer.cpio',
    'SharedSupport.dmg': root / 'backend/media/SharedSupport.dmg',
    'metal-probe-x64': root / 'artifacts/metal-probe/metal-probe-x64',
    'bitreverse-probe-x64': root / 'artifacts/metal-probe/bitreverse-probe-x64',
    'queue-burst-probe-x64': root / 'artifacts/metal-probe/queue-burst-probe-x64',
    'texture-lifetime-probe-x64': root / 'artifacts/metal-probe/texture-lifetime-probe-x64',
    'display-probe-x64': root / 'artifacts/metal-probe/display-probe-x64',
    'format-probe-x64': root / 'artifacts/metal-probe/format-probe-x64',
    'display-mode-probe-x64': root / 'artifacts/metal-probe/display-mode-probe-x64',
    'agent': root / 'artifacts/guest-agent.sh',
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # Keep the temporary capability token out of request logs.

    def route(self):
        prefix = f'/{token}/'
        return self.path[len(prefix):] if self.path.startswith(prefix) else None

    def do_GET(self):
        name = self.route()
        if name == 'next':
            task = root / 'artifacts/guest-task.sh'
            data = task.read_bytes().replace(b'\r\n', b'\n') if task.exists() else b''
            if task.exists():
                task.unlink()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif name in files:
            path = files[name]
            self.send_response(200)
            self.send_header('Content-Length', str(path.stat().st_size))
            self.end_headers()
            with path.open('rb') as source:
                shutil.copyfileobj(source, self.wfile, 1024 * 1024)
            print(f'Served {name}', flush=True)
        else:
            self.send_error(404)

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '-1'))
        if self.route() != 'result' or not 0 <= size <= 16 * 1024 * 1024:
            self.send_error(400)
            return
        data = self.rfile.read(size)
        with (root / 'artifacts/guest-task-results.log').open('ab') as f:
            f.write(data + b'\n')
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()
        print(f'Received guest result: {size} bytes', flush=True)

class LabServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def server_bind(self):
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


server = LabServer((address, port), Handler)
state.write_text(json.dumps({'base': f'http://{address}:{port}/{token}/'}))
print(f'VM lab channel listening on {address}:{port}', flush=True)
server.serve_forever()
