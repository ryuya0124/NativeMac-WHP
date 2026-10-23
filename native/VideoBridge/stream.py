"""Bounded persistent native NVDEC/NVENC workers for the VT transport.

Compressed packets keep their presentation timestamps in streaming Matroska.
FFmpeg's tee muxer returns NV12 packets and a separate framecrc timestamp
channel in the older CLI mode. Native workers use a framed binary protocol.
No decoder, pixel conversion or fallback runs in Python.
"""
import ctypes as c
from ctypes import wintypes as w
import queue
import re
import struct
from pathlib import Path
import subprocess
import threading
import time

from host import ExtendedLimits
import matroska


class Decoder:
    def __init__(self, ffmpeg, codec, width, height, configuration,worker=None,encoder=False,encoder_settings=None,gpu_index=0,gpu_frames=False):
        if gpu_frames and (worker is None or encoder):raise ValueError('GPU frames require the dedicated NVDEC worker')
        self.gpu_frames=gpu_frames;self.gpu_source=None;self.gpu_generation=0
        if codec=='vp9':
            if encoder or worker is None:raise ValueError('VP9 requires the native decoder worker')
            if type(width) is not int or type(height) is not int or not 16<=width<=3840 or not 16<=height<=2160 or width%2 or height%2:raise ValueError('Invalid VP9 dimensions')
            if not isinstance(configuration,bytes) or len(configuration)>65536:raise ValueError('Invalid VP9 configuration')
            initial=b''
        else:initial=matroska.header(codec,width,height,configuration if not encoder else b'\1'+b'\0'*6)
        self.encoder=encoder;self.configuration=None
        if encoder and worker is None:raise ValueError('NVENC requires the native API worker')
        if type(gpu_index) is not int or not 0<=gpu_index<64:raise ValueError('Invalid host-selected CUDA ordinal')
        self.native=worker is not None
        self.ready=threading.Event()
        self.size=width*height*3//2
        self.raw=queue.Queue(4);self.metadata=queue.Queue(4)
        self.closed=threading.Event();self.raw_done=threading.Event()
        self.metadata_done=threading.Event();self.write_lock=threading.Lock()
        self.receive_lock=threading.Lock();self.close_lock=threading.Lock();self.credits=threading.Condition()
        self.errors=[];self.pending=0
        self.started=self.last_progress=self.last_activity=time.monotonic()
        self.kernel=c.WinDLL('kernel32',use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes=[c.c_void_p,w.LPCWSTR]
        self.kernel.CreateJobObjectW.restype=w.HANDLE
        self.kernel.SetInformationJobObject.argtypes=[w.HANDLE,c.c_int,c.c_void_p,w.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes=[w.HANDLE,w.HANDLE]
        self.kernel.TerminateJobObject.argtypes=[w.HANDLE,w.UINT]
        self.kernel.CloseHandle.argtypes=[w.HANDLE]
        self.job=self.kernel.CreateJobObjectW(None,None)
        self.process=None
        if not self.job:raise OSError(c.get_last_error(),'CreateJobObject')
        try:
            limits=ExtendedLimits();limits.basic.flags=0x2000|0x200
            limits.jobLimit=1024*1024*1024
            if not self.kernel.SetInformationJobObject(self.job,9,c.byref(limits),c.sizeof(limits)):
                raise OSError(c.get_last_error(),'SetInformationJobObject')
            command=[str(ffmpeg),'-hide_banner','-loglevel','error','-nostdin',
                     '-probesize','32','-analyzeduration','0','-fpsprobesize','0',
                     '-hwaccel','cuda','-hwaccel_device',str(gpu_index),'-hwaccel_output_format','cuda',
                     '-c:v',codec+'_cuvid','-f','matroska','-i','pipe:0',
                     '-map','0:v:0','-an','-vf','hwdownload,format=nv12',
                     '-c:v','rawvideo','-threads:v','1','-fps_mode','passthrough',
                     '-enc_time_base:v','1/1000000000',
                     '-f','tee','[f=rawvideo]pipe:1|[f=framecrc]pipe:2']
            if self.native:
                command=[str(worker),str(Path(ffmpeg).resolve().parent),('enc-' if encoder else '')+codec,str(width),str(height),str(gpu_index)]
                config=configuration if not encoder else b'\0'
                if encoder_settings:
                    config=struct.pack('!BIIIB',2,encoder_settings['bitrate'],encoder_settings['frameRate'],encoder_settings['keyInterval'],encoder_settings['profile'])
                initial=struct.pack('!I',len(config))+config
            self.process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,bufsize=0,creationflags=0x4|0x08000000)
            handle=w.HANDLE(int(self.process._handle))
            if not self.kernel.AssignProcessToJobObject(self.job,handle):
                self.process.kill();raise OSError(c.get_last_error(),'AssignProcessToJobObject')
            native=c.WinDLL('ntdll');native.NtResumeProcess.argtypes=[w.HANDLE]
            if native.NtResumeProcess(handle)!=0:raise RuntimeError('Cannot resume codec worker')
            readers=(self._read_native,self._read_native_errors) if self.native else (self._read_raw,self._read_metadata)
            for function in (*readers,self._watchdog):
                threading.Thread(target=function,daemon=True).start()
            self._write(initial)
            if self.native and (not self.ready.wait(20) or self.errors):raise RuntimeError('NVDEC API worker did not become ready')
        except BaseException:
            self.close();raise

    def _put(self, destination, value):
        while not self.closed.is_set():
            try:destination.put(value,timeout=.2);return
            except queue.Full:continue

    def _read_native_errors(self):
        try:
            for line in self.process.stderr:
                if line and len(self.errors)<16:self.errors.append(line.decode('utf-8','replace').strip()[:512])
        except (OSError,ValueError):pass

    def _read_native(self):
        count=0;complete=False
        def take(size):
            result=bytearray()
            while len(result)<size:
                part=self.process.stdout.read(size-len(result))
                if not part:raise EOFError('Native codec output closed')
                result.extend(part)
            return bytes(result)
        try:
            while not self.closed.is_set():
                size,=struct.unpack('!I',take(4))
                if not 1<=size<=(8*1024*1024+10 if self.encoder else self.size+9):raise RuntimeError('Native codec message limit')
                body=take(size)
                if body==b'A':
                    if not self.encoder:self.ready.set()
                    continue
                if self.gpu_frames and body[:1]==b'H' and len(body)==73 and self.gpu_source is None:
                    self.gpu_source=body[1:];continue
                if self.encoder and body[:1]==b'C' and 7<len(body)<=65537:
                    self.configuration=body[1:];self.ready.set();continue
                if body[:1]==b'D' and len(body)==5:continue
                if body[:1]==b'G' and len(body)==5:
                    self._put(self.raw,b'');self._put(self.metadata,{'barrier':True});continue
                if body[:1]==b'E' and len(body)==5:
                    complete=struct.unpack('!I',body[1:])[0]==count
                    break
                if not self.encoder and body[:1]==b'K' and len(body)==9:
                    pts,=struct.unpack('!q',body[1:])
                    self._put(self.raw,b'');self._put(self.metadata,{'pts':pts,'dropped':True,'timeBase':(1,1000000000)})
                    count+=1;self.last_progress=time.monotonic();continue
                if self.gpu_frames:
                    if body[:1]!=b'S' or len(body)!=17 or self.gpu_source is None:raise RuntimeError('Invalid GPU codec output')
                    pts,generation=struct.unpack('!qQ',body[1:])
                    if generation!=self.gpu_generation+1:raise RuntimeError('GPU codec generation mismatch')
                    self.gpu_generation=generation
                    self._put(self.raw,b'');self._put(self.metadata,{'pts':pts,'generation':generation,'gpu':True,'timeBase':(1,1000000000)})
                    count+=1;self.last_progress=time.monotonic();continue
                if body[:1]!=b'R' or (len(body)<11 if self.encoder else len(body)!=self.size+9):raise RuntimeError('Invalid native codec output')
                pts,=struct.unpack('!q',body[1:9])
                self._put(self.raw,body[10:] if self.encoder else body[9:]);self._put(self.metadata,{'pts':pts,'dts':pts,'duration':0,'key':bool(body[9]) if self.encoder else False,'timeBase':(1,1000000000)})
                count+=1;self.last_progress=time.monotonic()
            if not complete and not self.closed.is_set():raise RuntimeError('Native stream incomplete')
        except (OSError,ValueError,RuntimeError,EOFError) as error:
            if not self.closed.is_set():self.errors.append(type(error).__name__)
        finally:
            self.ready.set();self.raw_done.set();self.metadata_done.set()

    def _read_raw(self):
        try:
            while not self.closed.is_set():
                data=bytearray()
                while len(data)<self.size:
                    chunk=self.process.stdout.read(self.size-len(data))
                    if not chunk:break
                    data.extend(chunk)
                if not data:break
                if len(data)!=self.size:raise RuntimeError('Truncated NV12 frame')
                self._put(self.raw,bytes(data))
        except (OSError,ValueError,RuntimeError) as error:
            self.errors.append(type(error).__name__)
        finally:self.raw_done.set()

    def _read_metadata(self):
        time_base=None
        try:
            for line in self.process.stderr:
                text=line.decode('utf-8','replace').strip()
                match=re.fullmatch(r'#tb\s+0:\s+(\d+)/(\d+)',text)
                if match:time_base=tuple(map(int,match.groups()));continue
                if text.startswith('#'):continue
                fields=[field.strip() for field in text.split(',')]
                if len(fields)==6 and fields[0]=='0' and time_base:
                    _,dts,pts,duration,size,checksum=fields
                    if int(size)!=self.size:raise RuntimeError('Unexpected raw packet size')
                    self._put(self.metadata,{'pts':int(pts),'dts':int(dts),'duration':int(duration),
                        'timeBase':time_base,'checksum':checksum})
                    self.last_progress=time.monotonic()
                elif text and len(self.errors)<16:self.errors.append(text[:512])
        except (OSError,ValueError,RuntimeError) as error:
            self.errors.append(type(error).__name__)
        finally:self.metadata_done.set()

    def _write(self, data):
        if self.closed.is_set():raise RuntimeError('Codec worker closed')
        view=memoryview(data)
        while view:
            written=self.process.stdin.write(view)
            if not written:raise RuntimeError('Codec input closed')
            view=view[written:]
        self.last_activity=time.monotonic()

    def send(self, data, presentation_nanoseconds, keyframe):
        if self.encoder:
            if len(data)!=self.size or not 0<=presentation_nanoseconds<1<<63:raise ValueError('Invalid encoder picture')
            packet=b''
        else:
            if not data or len(data)>8*1024*1024 or type(presentation_nanoseconds) is not int or not 0<=presentation_nanoseconds<1<<63 or type(keyframe) is not bool:raise ValueError('Invalid compressed packet')
            packet=b'' if self.native else matroska.packet(data,presentation_nanoseconds,keyframe)
        if self.native:
            body=b'P'+struct.pack('!qB',presentation_nanoseconds,keyframe)+data
            packet=struct.pack('!I',len(body))+body
        with self.write_lock:
            deadline=time.monotonic()+20
            with self.credits:
                while self.pending>=(1 if self.gpu_frames else 64) and not self.closed.is_set():
                    remaining=deadline-time.monotonic()
                    if remaining<=0:raise TimeoutError('Codec input backpressure deadline exceeded')
                    self.credits.wait(timeout=min(.2,remaining))
                if self.closed.is_set():raise RuntimeError('Codec worker closed')
                if not self.pending:self.last_progress=time.monotonic()
                self.pending+=1
            self._write(packet)

    def finish(self):
        with self.write_lock:
            if self.native:self._write(struct.pack('!I',1)+b'F')
            else:self.process.stdin.close()

    def flush(self):
        if not self.native:raise RuntimeError('Nonterminal drain requires the native NVDEC worker')
        with self.write_lock:self._write(struct.pack('!I',1)+b'G')

    def receive(self, timeout=20):
        with self.receive_lock:return self._receive(timeout)

    def _receive(self, timeout):
        deadline=time.monotonic()+timeout
        def take(source, done):
            while time.monotonic()<deadline and not self.closed.is_set():
                try:return source.get(timeout=min(.2,max(.001,deadline-time.monotonic())))
                except queue.Empty:
                    if done.is_set() and source.empty():return None
            if self.closed.is_set():raise RuntimeError('Codec worker closed')
            raise TimeoutError('Codec frame deadline exceeded')
        pixels=take(self.raw,self.raw_done)
        metadata=take(self.metadata,self.metadata_done)
        if pixels is None or metadata is None:
            if pixels is not None or metadata is not None:raise RuntimeError('Unpaired codec output')
            if self.process.poll() not in (None,0):raise RuntimeError('NVDEC worker failed')
            return None
        with self.credits:
            if not metadata.get('barrier'):self.pending=max(0,self.pending-1)
            self.credits.notify_all()
        self.last_activity=time.monotonic()
        return pixels,metadata

    def _watchdog(self):
        while not self.closed.wait(.2):
            now=time.monotonic()
            stalled=self.pending and not self.raw.full() and not self.metadata.full() and now-self.last_progress>20
            if now-self.started>3600 or now-self.last_activity>300 or stalled:
                self.errors.append('Codec session deadline exceeded');self.close();return

    def close(self):
        with self.close_lock:
            if self.closed.is_set():return
            self.closed.set()
            with self.credits:self.credits.notify_all()
            if self.job:
                self.kernel.TerminateJobObject(self.job,0)
                self.kernel.CloseHandle(self.job);self.job=None
            if self.process:
                self.process.wait(timeout=5)
                for pipe in (self.process.stdin,self.process.stdout,self.process.stderr):
                    if pipe:pipe.close()

    def __enter__(self):return self
    def __exit__(self,*_args):self.close()
