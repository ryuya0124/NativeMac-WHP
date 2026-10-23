"""Loopback streaming NVDEC/NVENC service for the authored VT component.

Only fixed codec/dimension/configuration fields cross the boundary. No caller
can select an executable, path, GPU index or FFmpeg arguments. Guest-wide
selection is installed separately by the explicit profile. NV12 is copied.
"""
import argparse
import base64
import json
from pathlib import Path
import socket
import socketserver
import struct
import threading
import time
import queue

from stream import Decoder
from cuda_identity import selected_device
from lz4.block import compress as lz4_compress
from gpu_control import GpuControl

MAX_PACKET = 8 * 1024 * 1024


class PeerClosed(EOFError):
    """The client closed between complete protocol messages."""


def read_exact(connection, count, clean_eof=False):
    result = bytearray()
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            if clean_eof and not result:
                raise PeerClosed('Client closed')
            raise EOFError('Truncated stream')
        result.extend(part)
    return bytes(result)


def read_message(connection, limit):
    length, = struct.unpack('!I', read_exact(connection, 4, clean_eof=True))
    if not 1 <= length <= limit:
        raise ValueError('Invalid message length')
    return read_exact(connection, length)


def write_message(connection, body):
    connection.sendall(struct.pack('!I', len(body)) + body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port, ffmpeg, worker=None,encoder_worker=None,gpu_index=0,gpu_worker=None,gpu_control=None):
        self.ffmpeg, self.worker, self.encoder_worker = ffmpeg, worker, encoder_worker
        self.gpu_index=gpu_index
        self.gpu_worker,self.gpu_control=gpu_worker,gpu_control
        self.slots = threading.BoundedSemaphore(2)
        super().__init__(('127.0.0.1', port), Handler)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        if not self.server.slots.acquire(blocking=False):
            self.request.settimeout(1)
            try: write_message(self.request,b'B')
            except OSError: pass
            return
        decoder = None
        gpu_control=None;target_ready=queue.Queue(1)
        feed_errors = []
        client_closed = threading.Event()
        started=time.monotonic();frames=0;dropped_frames=0;raw_bytes=wire_bytes=0
        receive_seconds=compression_seconds=write_seconds=0.0
        gpu_prepare_seconds=gpu_copy_seconds=0.0
        reused_targets=rebound_targets=0
        completed=False
        try:
            self.request.settimeout(20)
            if not self.request.recv(1,socket.MSG_PEEK):return # A local readiness check has no protocol input.
            request = json.loads(read_message(self.request, 100000))
            if not isinstance(request,dict):
                raise ValueError('Session must be an object')
            encode=request.get('operation')=='encode'
            fields={'version','operation','codec','width','height','bitrate','frameRate','keyInterval'} if encode else {'version', 'codec', 'width', 'height', 'configuration'}
            extras={'profile'} if encode else {'compression','output'}
            if not fields<=set(request)<=fields|extras:
                raise ValueError('Invalid session fields')
            if type(request['version']) is not int or request['version'] != 1 or request['codec'] not in (('h264','hevc') if encode else ('h264','hevc','vp9')):
                raise ValueError('Unsupported session version or codec')
            if type(request['width']) is not int or type(request['height']) is not int:
                raise ValueError('Dimensions must be integers')
            configuration = b'' if encode else base64.b64decode(request['configuration'], validate=True)
            compression=request.get('compression')
            if compression not in (None,'lz4-raw'):raise ValueError('Unsupported transport compression')
            compress=lz4_compress if compression else None
            output=request.get('output')
            if output not in (None,'shared-gpu-v1','shared-gpu-v2'):raise ValueError('Unsupported video output')
            gpu_frames=not encode and output in ('shared-gpu-v1','shared-gpu-v2') and self.server.gpu_worker is not None and self.server.gpu_control is not None
            gpu_reuse=gpu_frames and output=='shared-gpu-v2'
            if gpu_frames:gpu_control=GpuControl(self.server.gpu_control)
            settings=None
            if encode:
                if not self.server.encoder_worker:raise ValueError('NVENC API worker is not configured')
                settings={k:request[k] for k in ('bitrate','frameRate','keyInterval')}
                if any(type(v) is not int for v in settings.values()) or not 64000<=settings['bitrate']<=400000000 or not 1<=settings['frameRate']<=120 or not 1<=settings['keyInterval']<=600:raise ValueError('Invalid encoder settings')
                settings['profile']=request.get('profile',0)
                if type(settings['profile']) is not int or settings['profile'] not in ((0,1,2) if request['codec']=='h264' else (0,)):raise ValueError('Unsupported encoder profile')
            decoder = Decoder(self.server.ffmpeg, request['codec'], request['width'],
                              request['height'], configuration,worker=self.server.encoder_worker if encode else self.server.gpu_worker if gpu_frames else self.server.worker,encoder=encode,encoder_settings=settings,gpu_index=self.server.gpu_index,gpu_frames=gpu_frames)
            print(json.dumps({'stage':'encode-start' if encode else 'decode-start','codec':request['codec'],'width':request['width'],'height':request['height'],
                              'backend':'api' if self.server.worker else 'cli','output':output if gpu_frames else 'cpu-nv12'}),flush=True)
            write_message(self.request, b'A'+decoder.configuration if encode else b'W' if gpu_reuse else b'V' if gpu_frames else b'A')
            self.request.settimeout(300)

            # Read target-ready metadata independently of worker input
            # backpressure. Otherwise a second compressed packet waiting for
            # the first GPU slot would hide that first target's readiness.
            gpu_input=queue.Queue(65);queued_bytes=0;input_lock=threading.Lock()
            def gpu_writer():
                nonlocal queued_bytes
                try:
                    while not decoder.closed.is_set():
                        try:body=gpu_input.get(timeout=.1)
                        except queue.Empty:continue
                        with input_lock:queued_bytes-=len(body)
                        if body==b'F':decoder.finish();return
                        if body==b'G':decoder.flush();continue
                        timestamp,=struct.unpack('!q',body[1:9])
                        decoder.send(body[10:],timestamp,bool(body[9]))
                except (EOFError,OSError,ValueError,RuntimeError,TimeoutError) as error:
                    if not client_closed.is_set():feed_errors.append(type(error).__name__+': '+str(error)[:160])
                    decoder.close()
            if gpu_frames:threading.Thread(target=gpu_writer,daemon=True).start()

            def feed():
                nonlocal queued_bytes
                try:
                    while True:
                        body = read_message(self.request, decoder.size+10 if encode else MAX_PACKET + 10)
                        if gpu_frames and body[:1]==b'T' and len(body)==33:
                            try:target_ready.put((body[1:17],body[17:]),timeout=1)
                            except queue.Full:raise ValueError('Duplicate GPU target readiness')
                            continue
                        if gpu_frames:
                            if body not in (b'F',b'G') and (len(body)<11 or body[:1]!=b'P' or body[9] not in (0,1)):raise ValueError('Invalid GPU input packet')
                            with input_lock:
                                if queued_bytes+len(body)>64*1024*1024:raise ValueError('GPU input byte limit')
                                queued_bytes+=len(body)
                            try:gpu_input.put_nowait(body)
                            except queue.Full:raise ValueError('GPU input packet limit')
                            continue
                        if body == b'F':
                            decoder.finish()
                            return
                        if body == b'G':
                            decoder.flush()
                            continue
                        if len(body) < 11 or body[:1] != b'P' or body[9] not in (0, 1):
                            raise ValueError('Invalid compressed packet')
                        timestamp, = struct.unpack('!q', body[1:9])
                        decoder.send(body[10:], timestamp, bool(body[9]))
                except PeerClosed:
                    client_closed.set()
                    decoder.close()
                except (EOFError, OSError, ValueError, RuntimeError, TimeoutError) as error:
                    feed_errors.append(type(error).__name__+': '+str(error)[:160])
                    decoder.close()

            sender = threading.Thread(target=feed, daemon=True)
            sender.start()
            while True:
                before=time.monotonic()
                frame = decoder.receive(timeout=300)
                receive_seconds+=time.monotonic()-before
                if frame is None:
                    break
                pixels, metadata = frame
                if metadata.get('barrier'):
                    write_message(self.request,b'G')
                    continue
                if metadata.get('dropped'):
                    write_message(self.request,b'K'+struct.pack('!q',metadata['pts']))
                    frames+=1;dropped_frames+=1;continue
                if gpu_frames:
                    if not gpu_control.imported:gpu_control.import_source(decoder.process.pid,decoder.gpu_source)
                    preparing=time.monotonic()
                    capability=gpu_control.arm(request['width'],request['height'])
                    write_message(self.request,b'T'+struct.pack('!q',metadata['pts'])+capability)
                    deadline=time.monotonic()+20
                    while True:
                        if client_closed.is_set() or decoder.closed.is_set():raise PeerClosed('Client closed while preparing GPU target')
                        try:ready=target_ready.get(timeout=.1);break
                        except queue.Empty:
                            if time.monotonic()>=deadline:raise TimeoutError('GPU target readiness deadline')
                    requested,actual=ready
                    if requested!=capability:raise ValueError('GPU target capability mismatch')
                    if actual!=capability:
                        if not gpu_reuse:raise ValueError('Legacy GPU target capability mismatch')
                        if gpu_reuse and gpu_control.reuse(capability,actual):
                            reused_targets+=1;actual=capability
                        else:
                            write_message(self.request,b'R'+capability);wire_bytes+=17
                            rebound_targets+=1
                            deadline=time.monotonic()+20
                            while True:
                                if client_closed.is_set() or decoder.closed.is_set():raise PeerClosed('Client closed during GPU rebind')
                                try:requested,actual=target_ready.get(timeout=.1);break
                                except queue.Empty:
                                    if time.monotonic()>=deadline:raise TimeoutError('GPU target rebind deadline')
                            if requested!=capability or actual!=capability:raise ValueError('GPU target rebind mismatch')
                    gpu_prepare_seconds+=time.monotonic()-preparing
                    copying=time.monotonic()
                    gpu_control.copy(capability,actual,metadata['generation'],park=gpu_reuse)
                    gpu_copy_seconds+=time.monotonic()-copying
                    write_message(self.request,b'S'+struct.pack('!q',metadata['pts'])+actual)
                    frames+=1;wire_bytes+=50;continue
                numerator, denominator = metadata['timeBase']
                ns = (metadata['pts'] * numerator * 1000000000) // denominator
                raw_bytes+=len(pixels)
                tag=b'R';payload=pixels
                if compress:
                    before=time.monotonic()
                    packed=compress(pixels,mode='fast',acceleration=1,store_size=False)
                    compression_seconds+=time.monotonic()-before
                    if len(packed)<len(pixels):tag=b'L';payload=packed
                wire_bytes+=len(payload)
                before=time.monotonic()
                write_message(self.request, tag + struct.pack('!q', ns) + (bytes([metadata['key']]) if encode else b'') + payload)
                write_seconds+=time.monotonic()-before
                frames += 1
            if feed_errors or decoder.errors or decoder.process.wait(timeout=5):
                raise RuntimeError('Hardware stream failed')
            write_message(self.request, b'E' + struct.pack('!I', frames))
            if gpu_frames:self.request.shutdown(socket.SHUT_RD)
            sender.join(timeout=2)
            print(json.dumps({'stage':'encode-complete' if encode else 'decode-complete','frames':frames,'seconds':round(time.monotonic()-started,4)}),flush=True)
            completed=True
        except (EOFError, OSError, ValueError, RuntimeError, TimeoutError) as error:
            cancelled=client_closed.is_set() and not feed_errors and decoder is not None and not decoder.errors
            print(json.dumps({'stage':'session-cancelled' if cancelled else 'session-error','error': 'Client closed' if cancelled else str(error)[:160],
                              'workerErrors':decoder.errors[:4] if decoder else [],
                              'inputErrors':feed_errors[:4],
                              'frames':frames}),flush=True)
            if not cancelled:
                try:
                    write_message(self.request, b'X')
                except OSError:
                    pass
        finally:
            if gpu_control:gpu_control.close()
            if decoder:
                decoder.close()
                print(json.dumps({'stage':'session-closed','frames':frames,'rawPixelBytes':raw_bytes,'wirePayloadBytes':wire_bytes,
                                  'droppedFrames':dropped_frames,'decodedFrames':frames-dropped_frames,
                                  'receiveWaitSeconds':round(receive_seconds,4),'compressionSeconds':round(compression_seconds,4),
                                  'gpuTargetPrepareSeconds':round(gpu_prepare_seconds,4),'gpuTargetCopySeconds':round(gpu_copy_seconds,4),
                                  'gpuReusedTargets':reused_targets,'gpuReboundTargets':rebound_targets,
                                  'socketWriteSeconds':round(write_seconds,4),'seconds':round(time.monotonic()-started,4)}),flush=True)
            try:
                self.request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.server.slots.release()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=54883)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--worker', type=Path, help='Optional locally built hardware-only API worker')
    parser.add_argument('--encoder-worker',type=Path,help='Locally built NVENC API worker')
    parser.add_argument('--gpu-name',help='Actual selected Windows Vulkan renderer; required if multiple CUDA adapters exist')
    parser.add_argument('--gpu-worker',type=Path,help='Dedicated shared-GPU NVDEC worker, explicit opt-in')
    parser.add_argument('--gpu-control-file',type=Path,help='Private host-only GPU metadata endpoint configuration')
    args = parser.parse_args()
    if not args.ffmpeg.is_file():
        parser.error('FFmpeg executable missing')
    if args.worker and not args.worker.is_file():parser.error('Native worker executable missing')
    if args.encoder_worker and not args.encoder_worker.is_file():parser.error('NVENC worker executable missing')
    if bool(args.gpu_worker)!=bool(args.gpu_control_file):parser.error('GPU output requires both worker and private control configuration')
    if args.gpu_worker and (not args.gpu_worker.is_file() or not args.gpu_control_file.is_file()):parser.error('GPU output dependency missing')
    print(json.dumps({'stage':'hardware-device-initialization'}),flush=True)
    gpu_index,gpu_name=selected_device(args.gpu_name)
    print(json.dumps({'listener': '127.0.0.1', 'port': args.port,'gpu':gpu_name,'cudaOrdinal':gpu_index,
                      'sessions': 2, 'softwareFallback': False}), flush=True)
    with Server(args.port, args.ffmpeg, args.worker.resolve() if args.worker else None,args.encoder_worker.resolve() if args.encoder_worker else None,gpu_index,args.gpu_worker.resolve() if args.gpu_worker else None,args.gpu_control_file.resolve() if args.gpu_control_file else None) as server:
        server.serve_forever()
