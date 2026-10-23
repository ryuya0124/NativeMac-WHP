"""Keep bounded codec/audio services and the direct pinned TLS transport alive.

Codec/audio listeners remain on loopback. Only the authenticated TLS listener
is bound to the explicitly configured Windows interface. No SSH media route.
Windows job ownership prevents orphan codec/tunnel processes on VM shutdown.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import ctypes as c
from ctypes import wintypes as w
import re
import os


class ChildScope:
    def __init__(self,root,parent_pid):
        sys.path.insert(0,str(root/'native/VideoBridge'))
        from host import ExtendedLimits
        self.kernel=c.WinDLL('kernel32',use_last_error=True)
        for name,args,result in (
            ('CreateJobObjectW',[c.c_void_p,w.LPCWSTR],w.HANDLE),
            ('SetInformationJobObject',[w.HANDLE,c.c_int,c.c_void_p,w.DWORD],w.BOOL),
            ('AssignProcessToJobObject',[w.HANDLE,w.HANDLE],w.BOOL),
            ('OpenProcess',[w.DWORD,w.BOOL,w.DWORD],w.HANDLE),
            ('WaitForSingleObject',[w.HANDLE,w.DWORD],w.DWORD),
            ('CloseHandle',[w.HANDLE],w.BOOL)):
            function=getattr(self.kernel,name);function.argtypes=args;function.restype=result
        self.job=self.kernel.CreateJobObjectW(None,None)
        self.parent=None
        if not self.job:raise OSError(c.get_last_error(),'CreateJobObject')
        limits=ExtendedLimits();limits.basic.flags=0x2000
        if not self.kernel.SetInformationJobObject(self.job,9,c.byref(limits),c.sizeof(limits)):
            self.close();raise OSError(c.get_last_error(),'SetInformationJobObject')
        if parent_pid:
            self.parent=self.kernel.OpenProcess(0x100000,False,parent_pid)
            if not self.parent:
                self.close();raise RuntimeError('VM launcher process is unavailable')

    def parent_alive(self):
        return not self.parent or self.kernel.WaitForSingleObject(self.parent,0)==258

    def start(self,command,**kwargs):
        process=subprocess.Popen(command,creationflags=0x4|0x08000000,**kwargs)
        handle=w.HANDLE(int(process._handle))
        native=c.WinDLL('ntdll');native.NtResumeProcess.argtypes=[w.HANDLE]
        if not self.kernel.AssignProcessToJobObject(self.job,handle) or native.NtResumeProcess(handle)!=0:
            process.kill();process.wait();raise RuntimeError('Could not own the codec process tree')
        return process

    def close(self):
        if self.job:self.kernel.CloseHandle(self.job);self.job=None
        if self.parent:self.kernel.CloseHandle(self.parent);self.parent=None


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path)
    parser.add_argument('--ffmpeg',type=Path)
    parser.add_argument('--transport-config',type=Path)
    parser.add_argument('--port',type=int,default=54883)
    parser.add_argument('--vm-launcher-pid',type=int)
    parser.add_argument('--stop-file',type=Path)
    parser.add_argument('--ready-file',type=Path)
    parser.add_argument('--audio',action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    if args.config:
        config=json.loads(args.config.read_text(encoding='utf-8-sig'))
        if not isinstance(config,dict) or set(config)-{'ffmpeg','port','audio','transportConfig'}:
            parser.error('Unexpected configuration fields; SSH media forwarding is not supported')
        for key,attribute in (('ffmpeg','ffmpeg'),('port','port'),('audio','audio'),('transportConfig','transport_config')):
            if key in config:setattr(args,attribute,config[key])
    if type(args.audio) is not bool or type(args.port) is not int or not 1024<=args.port<=65534:
        parser.error('Invalid audio selection or codec port')
    if args.vm_launcher_pid is not None and args.vm_launcher_pid<=0:parser.error('Invalid VM launcher PID')
    for name in ('ffmpeg','transport_config'):
        value=getattr(args,name)
        if not value:parser.error('FFmpeg and direct TLS configuration are required')
        value=Path(value);value=value if value.is_absolute() else root/value
        if not value.is_file():parser.error('Required local service dependency is missing')
        setattr(args,name,value)
    sys.path.insert(0,str(root/'native/MediaTransport'))
    from transport import load
    direct,_=load(args.transport_config,True)
    if direct['codecPort']!=args.port or direct['audioPort']!=args.port+1:
        parser.error('Direct TLS upstream ports must match the local media services')
    probe_scope=ChildScope(root,args.vm_launcher_pid)
    try:
        probe=probe_scope.start([sys.executable,str(root/'scripts/Probe-VGpu.py'),str(root/'artifacts/vgpu/reims_vgpu_c.dll'),
            '--identity-only','--report',str(root/'artifacts/video-renderer-identity.json')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        output,_=probe.communicate(timeout=45)
        if probe.returncode:raise RuntimeError('Windows renderer identity probe failed')
        renderer=json.loads(output)
    finally:probe_scope.close()
    if renderer.get('vulkanDeviceType')==4 or not renderer.get('hostGPUName'):raise RuntimeError('A real Windows renderer is required')
    for address,port in [('127.0.0.1',args.port),*([('127.0.0.1',args.port+1)] if args.audio else []),(direct['listenAddress'],direct['listenPort'])]:
        with socket.socket() as check:check.bind((address,port))
    logs=root/'artifacts/video-service';logs.mkdir(parents=True,exist_ok=True)
    children=[];scope=ChildScope(root,args.vm_launcher_pid)
    def stopping():return not scope.parent_alive() or (args.stop_file and args.stop_file.exists())
    try:
        with (logs/'host.log').open('ab',buffering=0) as host_log:
            gpu_options=[]
            gpu_control=os.environ.get('NATIVEMAC_VIDEO_CONTROL_FILE')
            if gpu_control:
                control=Path(gpu_control)
                gpu_worker=root/'artifacts/video-worker/NativeMacNvdecGpuWorker.exe'
                if not control.is_absolute() or not control.is_file() or not gpu_worker.is_file():raise RuntimeError('Shared GPU video dependencies missing')
                gpu_options=['--gpu-worker',str(gpu_worker),'--gpu-control-file',str(control)]
            children.append(scope.start([sys.executable,str(root/'native/VideoBridge/server.py'),'--ffmpeg',str(args.ffmpeg.resolve()),
                '--worker',str(root/'artifacts/video-worker/NativeMacNvdecWorker.exe'),
                '--encoder-worker',str(root/'artifacts/video-worker/NativeMacCodecWorker.exe'),
                '--gpu-name',renderer['hostGPUName'],'--port',str(args.port),*gpu_options],stdout=host_log,stderr=host_log))
            if args.audio:
                children.append(scope.start([sys.executable,str(root/'native/AudioBridge/server.py'),'--port',str(args.port+1)],stdout=host_log,stderr=host_log))
            children.append(scope.start([sys.executable,str(root/'native/MediaTransport/transport.py'),'host','--config',str(args.transport_config.resolve())],stdout=host_log,stderr=host_log))
            deadline=time.monotonic()+90
            endpoints=[('127.0.0.1',args.port),*([('127.0.0.1',args.port+1)] if args.audio else []),(direct['listenAddress'],direct['listenPort'])]
            while True:
                if stopping():return
                if any(child.poll() is not None for child in children):raise RuntimeError('Media service startup failed; inspect its local log')
                try:
                    for endpoint in endpoints:
                        with socket.create_connection(endpoint,timeout=.2):pass
                    break
                except OSError:
                    if time.monotonic()>deadline:raise TimeoutError('Direct media service readiness deadline')
                    time.sleep(.1)
            if args.ready_file:
                pending=args.ready_file.with_suffix('.pending')
                pending.write_text(json.dumps({'servicePid':os.getpid(),'launcherPid':args.vm_launcher_pid,'port':args.port,'transport':'pinned-tls-direct'}),encoding='utf-8')
                pending.replace(args.ready_file)
            print('Direct TLS media services ready for '+renderer['hostGPUName']+'. No SSH media route.',flush=True)
            while not stopping():
                if any(child.poll() is not None for child in children):raise RuntimeError('A direct media service exited; inspect its local log')
                time.sleep(.5)
    except KeyboardInterrupt:pass
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
        scope.close()
        if args.ready_file:args.ready_file.unlink(missing_ok=True)


if __name__=='__main__':main()
