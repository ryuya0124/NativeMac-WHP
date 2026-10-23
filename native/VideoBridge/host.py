"""Bounded loopback NVENC/NVDEC transport for authored VM video tests.

This transport does not register a VideoToolbox encoder or decoder. Use an SSH
tunnel to reach its loopback listener from the guest. There is no software codec
fallback and callers cannot supply executable paths or FFmpeg command options.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.parse import parse_qs, urlsplit

MAX_BYTES = 64 * 1024 * 1024


class BasicLimits(c.Structure):
    _fields_ = [('processTime', c.c_longlong), ('jobTime', c.c_longlong),
                ('flags', w.DWORD), ('minWS', c.c_size_t), ('maxWS', c.c_size_t),
                ('active', w.DWORD), ('affinity', c.c_size_t),
                ('priority', w.DWORD), ('scheduling', w.DWORD)]


class IOCounts(c.Structure):
    _fields_ = [(name, c.c_ulonglong) for name in
                ('readOps', 'writeOps', 'otherOps', 'readBytes', 'writeBytes', 'otherBytes')]


class ExtendedLimits(c.Structure):
    _fields_ = [('basic', BasicLimits), ('io', IOCounts),
                ('processLimit', c.c_size_t), ('jobLimit', c.c_size_t),
                ('peakProcess', c.c_size_t), ('peakJob', c.c_size_t)]


def hardware_job(command):
    """Run only this FFmpeg process tree, with a 20 s / 1 GiB job limit.

    This video-worker bound is separate from the translator's 500 MiB ceiling.
    CUDA initialization and decoder surfaces already approach 512 MiB at FHD.
    """
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [c.c_void_p, w.LPCWSTR]
    kernel.CreateJobObjectW.restype = w.HANDLE
    kernel.SetInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
    kernel.QueryInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.c_void_p]
    kernel.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise OSError(c.get_last_error(), 'CreateJobObject')
    process = None
    try:
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000 | 0x200  # Kill on close; job memory limit.
        limits.jobLimit = 1024 * 1024 * 1024
        if not kernel.SetInformationJobObject(job, 9, c.byref(limits), c.sizeof(limits)):
            raise OSError(c.get_last_error(), 'SetInformationJobObject')
        with tempfile.TemporaryFile() as errors:
            start = time.monotonic()
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=errors,
                                       creationflags=0x4 | 0x08000000)
            if not kernel.AssignProcessToJobObject(job, w.HANDLE(int(process._handle))):
                process.kill()
                raise OSError(c.get_last_error(), 'AssignProcessToJobObject')
            native = c.WinDLL('ntdll')
            native.NtResumeProcess.argtypes = [w.HANDLE]
            if native.NtResumeProcess(w.HANDLE(int(process._handle))) != 0:
                raise RuntimeError('Cannot resume codec process')
            try:
                process.wait(timeout=max(0.01, 20 - (time.monotonic() - start)))
            except subprocess.TimeoutExpired as error:
                kernel.TerminateJobObject(job, 124)
                process.wait()
                raise RuntimeError('Hardware codec deadline exceeded') from error
            if process.returncode != 0:
                kernel.QueryInformationJobObject(job, 9, c.byref(limits), c.sizeof(limits), None)
                print(json.dumps({'stage': 'hardware-job-failed', 'exit': process.returncode,
                                  'peakMiB': round(limits.peakJob/1024/1024, 3)}), flush=True)
                # Keep driver diagnostics local; do not return host paths to a client.
                raise RuntimeError('Hardware codec failed; software fallback is disabled')
            if not kernel.QueryInformationJobObject(job, 9, c.byref(limits), c.sizeof(limits), None):
                raise OSError(c.get_last_error(), 'QueryInformationJobObject')
            return {'seconds': round(time.monotonic()-start, 4),
                    'peakMiB': round(limits.peakJob/1024/1024, 3)}
    finally:
        kernel.CloseHandle(job)
        if process is not None and process.poll() is None:
            process.wait()


def dimensions(query):
    if set(query) != {'width', 'height', 'frames'} or any(len(v) != 1 for v in query.values()):
        raise ValueError('Expected width, height and frames exactly once')
    width, height, frames = (int(query[k][0]) for k in ('width', 'height', 'frames'))
    if not (16 <= width <= 3840 and 16 <= height <= 2160 and 1 <= frames <= 120):
        raise ValueError('Unsupported dimensions or frame count')
    size = width * height * 3 // 2 * frames
    if width % 2 or height % 2 or size > MAX_BYTES:
        raise ValueError('NV12 dimensions must be even and the batch at most 64 MiB')
    return width, height, frames, size


class CodecServer(HTTPServer):
    def __init__(self, port, ffmpeg, gpu_name):
        self.ffmpeg, self.gpu_name = ffmpeg, gpu_name
        super().__init__(('127.0.0.1', port), Handler)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, _format, *_args):
        pass

    def reply(self, status, body, content_type='application/json', headers=None):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        if self.path != '/v1/info':
            return self.reply(404, b'{}')
        self.reply(200, json.dumps({'transport': 1, 'gpu': self.server.gpu_name,
                                   'encoders': ['h264_nvenc', 'hevc_nvenc'],
                                   'decoders': ['h264_cuvid', 'hevc_cuvid'],
                                   'softwareFallback': False,
                                   'videoToolboxRegistered': False}).encode())

    def do_POST(self):
        try:
            url = urlsplit(self.path)
            if url.path not in ('/v1/encode/h264', '/v1/encode/hevc',
                                '/v1/decode/h264', '/v1/decode/hevc'):
                return self.reply(404, b'{}')
            width, height, frames, raw_size = dimensions(parse_qs(url.query, keep_blank_values=True))
            if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length', [])) != 1:
                raise ValueError('A single Content-Length is required')
            length = int(self.headers['Content-Length'])
            encode = '/encode/' in url.path
            if not 0 < length <= MAX_BYTES or (encode and length != raw_size):
                raise ValueError('Invalid input length')
            codec = url.path.rsplit('/', 1)[1]
            engine = codec + ('_nvenc' if encode else '_cuvid')
            with tempfile.TemporaryDirectory(prefix='nativemac-codec-') as folder:
                root = Path(folder)
                source, output = root/'input', root/'output'
                remaining = length
                with source.open('wb') as stream:
                    while remaining:
                        part = self.rfile.read(min(1024*1024, remaining))
                        if not part:
                            raise ValueError('Truncated input')
                        stream.write(part)
                        remaining -= len(part)
                command = [self.server.ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-y']
                if encode:
                    command += ['-f', 'rawvideo', '-pixel_format', 'nv12', '-video_size', f'{width}x{height}',
                                '-framerate', '30', '-i', str(source), '-an', '-c:v', engine,
                                '-gpu', '0', '-bf', '0', '-preset', 'p4', '-tune', 'ull',
                                '-rc', 'constqp', '-qp', '18', '-movflags', '+faststart', '-f', 'mp4']
                else:
                    command += ['-hwaccel', 'cuda', '-hwaccel_device', '0', '-hwaccel_output_format', 'cuda',
                                '-c:v', engine, '-i', str(source), '-an', '-vf', 'hwdownload,format=nv12',
                                '-f', 'rawvideo']
                command += ['-threads:v', '1', '-frames:v', str(frames), str(output)]
                measured = hardware_job(command)
                size = output.stat().st_size
                if not 0 < size <= MAX_BYTES or (not encode and size != raw_size):
                    raise RuntimeError('Unexpected codec output size or frame count')
                headers = {'X-NativeMac-Engine': engine, 'X-NativeMac-GPU': self.server.gpu_name,
                           'X-NativeMac-Frames': frames, 'X-NativeMac-Seconds': measured['seconds'],
                           'X-NativeMac-Peak-MiB': measured['peakMiB']}
                self.reply(200, output.read_bytes(), 'video/mp4' if encode else 'application/octet-stream', headers)
                print(json.dumps({'operation': 'encode' if encode else 'decode', 'engine': engine,
                                  'width': width, 'height': height, 'frames': frames, **measured}), flush=True)
        except (ValueError, TimeoutError) as error:
            self.reply(400, json.dumps({'error': str(error)}).encode())
        except (OSError, RuntimeError) as error:
            self.reply(503, json.dumps({'error': str(error)}).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=54880)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    args = parser.parse_args()
    if not args.ffmpeg or not Path(args.ffmpeg).is_file():
        parser.error('An installed FFmpeg with NVENC and CUVID support is required')
    gpu = subprocess.check_output(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader', '--id=0'],
                                  encoding='utf-8', timeout=5).strip()
    if not gpu or '\n' in gpu or '\r' in gpu:
        raise RuntimeError('Expected one NVIDIA GPU')
    with CodecServer(args.port, str(Path(args.ffmpeg).resolve()), gpu) as server:
        print(json.dumps({'listening': '127.0.0.1', 'port': server.server_port, 'gpu': gpu}), flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
