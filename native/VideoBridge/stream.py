"""Experimental persistent NVDEC worker; not yet a VideoToolbox driver.

Compressed packets keep their presentation timestamps in streaming Matroska.
FFmpeg's tee muxer returns NV12 packets and a separate framecrc timestamp
channel. No decoder, pixel conversion or fallback runs in Python.
"""
import ctypes as c
from ctypes import wintypes as w
import queue
import re
import subprocess
import threading
import time

from host import ExtendedLimits
import matroska


class Decoder:
    def __init__(self, ffmpeg, codec, width, height, configuration):
        initial=matroska.header(codec,width,height,configuration)
        self.size=width*height*3//2
        self.raw=queue.Queue(4);self.metadata=queue.Queue(4)
        self.closed=threading.Event();self.raw_done=threading.Event()
        self.metadata_done=threading.Event();self.write_lock=threading.Lock()
        self.receive_lock=threading.Lock();self.credits=threading.Condition()
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
                     '-hwaccel','cuda','-hwaccel_device','0','-hwaccel_output_format','cuda',
                     '-c:v',codec+'_cuvid','-f','matroska','-i','pipe:0',
                     '-map','0:v:0','-an','-vf','hwdownload,format=nv12',
                     '-c:v','rawvideo','-threads:v','1','-fps_mode','passthrough',
                     '-enc_time_base:v','1/1000000000',
                     '-f','tee','[f=rawvideo]pipe:1|[f=framecrc]pipe:2']
            self.process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,bufsize=0,creationflags=0x4|0x08000000)
            handle=w.HANDLE(int(self.process._handle))
            if not self.kernel.AssignProcessToJobObject(self.job,handle):
                self.process.kill();raise OSError(c.get_last_error(),'AssignProcessToJobObject')
            native=c.WinDLL('ntdll');native.NtResumeProcess.argtypes=[w.HANDLE]
            if native.NtResumeProcess(handle)!=0:raise RuntimeError('Cannot resume codec worker')
            for function in (self._read_raw,self._read_metadata,self._watchdog):
                threading.Thread(target=function,daemon=True).start()
            self._write(initial)
        except BaseException:
            self.close();raise

    def _put(self, destination, value):
        while not self.closed.is_set():
            try:destination.put(value,timeout=.2);return
            except queue.Full:continue

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
        packet=matroska.packet(data,presentation_nanoseconds,keyframe)
        with self.write_lock:
            deadline=time.monotonic()+20
            with self.credits:
                while self.pending>=64 and not self.closed.is_set():
                    remaining=deadline-time.monotonic()
                    if remaining<=0:raise TimeoutError('Codec input backpressure deadline exceeded')
                    self.credits.wait(timeout=min(.2,remaining))
                if self.closed.is_set():raise RuntimeError('Codec worker closed')
                if not self.pending:self.last_progress=time.monotonic()
                self.pending+=1
            self._write(packet)

    def finish(self):
        with self.write_lock:self.process.stdin.close()

    def receive(self, timeout=20):
        with self.receive_lock:return self._receive(timeout)

    def _receive(self, timeout):
        deadline=time.monotonic()+timeout
        def take(source, done):
            while time.monotonic()<deadline and not self.closed.is_set():
                try:return source.get(timeout=min(.2,max(.001,deadline-time.monotonic())))
                except queue.Empty:
                    if done.is_set() and source.empty():return None
            raise TimeoutError('Codec frame deadline exceeded')
        pixels=take(self.raw,self.raw_done)
        metadata=take(self.metadata,self.metadata_done)
        if pixels is None or metadata is None:
            if pixels is not None or metadata is not None:raise RuntimeError('Unpaired codec output')
            if self.process.poll() not in (None,0):raise RuntimeError('NVDEC worker failed')
            return None
        with self.credits:
            self.pending=max(0,self.pending-1);self.credits.notify_all()
        self.last_activity=time.monotonic()
        return pixels,metadata

    def _watchdog(self):
        while not self.closed.wait(.2):
            now=time.monotonic()
            stalled=self.pending and not self.raw.full() and not self.metadata.full() and now-self.last_progress>20
            if now-self.started>3600 or now-self.last_activity>300 or stalled:
                self.errors.append('Codec session deadline exceeded');self.close();return

    def close(self):
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
