"""Keep the bounded codec service and one authenticated guest SSH forward alive.

No LAN codec listener. Guest-wide opt-in is installed separately inside the VM.
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
    parser.add_argument('--config',type=Path,help='Local, ignored connection configuration; contains no passwords')
    parser.add_argument('--ffmpeg',type=Path)
    parser.add_argument('--guest-user')
    parser.add_argument('--known-hosts',type=Path)
    parser.add_argument('--ssh-port',type=int,help='Previously qualified loopback SSH listener')
    parser.add_argument('--host-key-alias')
    parser.add_argument('--jump',help='Optional already authorized SSH jump target')
    parser.add_argument('--port',type=int,default=54883)
    parser.add_argument('--vm-launcher-pid',type=int)
    parser.add_argument('--stop-file',type=Path)
    parser.add_argument('--ready-file',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    if args.config:
        config=json.loads(args.config.read_text(encoding='utf-8-sig'))
        allowed={'ffmpeg','guestUser','knownHosts','sshPort','hostKeyAlias','jump','port'}
        if not isinstance(config,dict) or set(config)-allowed:parser.error('Unexpected video-service configuration fields')
        for key,attribute in (('ffmpeg','ffmpeg'),('guestUser','guest_user'),('knownHosts','known_hosts'),('sshPort','ssh_port'),('hostKeyAlias','host_key_alias'),('jump','jump'),('port','port')):
            if key in config:setattr(args,attribute,config[key])
    for attribute in ('ffmpeg','known_hosts'):
        value=getattr(args,attribute)
        if not value:parser.error('FFmpeg and a trusted known-hosts file are required')
        value=Path(value);setattr(args,attribute,value if value.is_absolute() else root/value)
    if not args.ffmpeg.is_file():parser.error('FFmpeg is unavailable')
    if not args.known_hosts.is_file():parser.error('A previously trusted guest known-hosts file is required')
    if not isinstance(args.guest_user,str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}',args.guest_user):parser.error('Invalid guest user')
    if args.jump and not re.fullmatch(r'[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+(?::[0-9]+)?',args.jump):parser.error('Invalid SSH jump target')
    if args.host_key_alias and not re.fullmatch(r'[A-Za-z0-9_.-]+',args.host_key_alias):parser.error('Invalid host key alias')
    ssh_port=args.ssh_port
    if type(ssh_port) is not int or type(args.port) is not int or not 1<=ssh_port<=65535 or not 1<=args.port<=65535:parser.error('Invalid TCP port')
    if args.vm_launcher_pid is not None and args.vm_launcher_pid<=0:parser.error('Invalid VM launcher PID')
    # Probe the same Vulkan DLL used by Start-VM; no model label or GPU ordinal is configured here.
    probe_scope=ChildScope(root,args.vm_launcher_pid)
    try:
        probe=probe_scope.start([sys.executable,str(root/'scripts/Probe-VGpu.py'),str(root/'artifacts/vgpu/reims_vgpu_c.dll'),
            '--identity-only','--report',str(root/'artifacts/video-renderer-identity.json')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        output,_=probe.communicate(timeout=45)
        if probe.returncode:raise RuntimeError('Windows renderer identity probe failed')
        renderer=json.loads(output)
    finally:probe_scope.close()
    if renderer.get('vulkanDeviceType')==4 or not renderer.get('hostGPUName'):raise RuntimeError('A real Windows renderer is required')
    # Refuse an existing listener: a new SSH tunnel must never reach another service accidentally.
    with socket.socket() as check:check.bind(('127.0.0.1',args.port))
    logs=root/'artifacts/video-service';logs.mkdir(parents=True,exist_ok=True)
    children=[]
    scope=ChildScope(root,args.vm_launcher_pid)
    def stopping():return not scope.parent_alive() or (args.stop_file and args.stop_file.exists())
    try:
        with (logs/'host.log').open('ab',buffering=0) as host_log,(logs/'ssh.log').open('ab',buffering=0) as ssh_log:
            print('Starting the bounded native hardware codec service.',flush=True)
            host=scope.start([sys.executable,str(root/'native/VideoBridge/server.py'),'--ffmpeg',str(args.ffmpeg.resolve()),
                '--worker',str(root/'artifacts/video-worker/NativeMacNvdecWorker.exe'),
                '--encoder-worker',str(root/'artifacts/video-worker/NativeMacCodecWorker.exe'),
                '--gpu-name',renderer['hostGPUName'],'--port',str(args.port)],stdout=host_log,stderr=host_log)
            children.append(host)
            deadline=time.monotonic()+90
            while True:
                if stopping():return
                if host.poll() is not None:raise RuntimeError('Hardware codec service startup failed; inspect its local log')
                try:
                    with socket.create_connection(('127.0.0.1',args.port),timeout=.2):break
                except OSError:
                    if time.monotonic()>deadline:raise TimeoutError('Codec service readiness deadline')
                    time.sleep(.1)
            if args.ready_file:
                pending=args.ready_file.with_suffix('.pending')
                pending.write_text(json.dumps({'servicePid':os.getpid(),'launcherPid':args.vm_launcher_pid,'port':args.port}),encoding='utf-8')
                pending.replace(args.ready_file)
            command=['ssh','-N','-T','-p',str(ssh_port),'-o','BatchMode=yes','-o','ExitOnForwardFailure=yes',
                '-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3',
                '-o','UserKnownHostsFile='+str(args.known_hosts.resolve())]
            if args.jump:command+=['-J',args.jump]
            if args.host_key_alias:command+=['-o','HostKeyAlias='+args.host_key_alias]
            command+=['-R',f'127.0.0.1:54885:127.0.0.1:{args.port}',args.guest_user+'@127.0.0.1']
            print('Codec service started for '+renderer['hostGPUName']+'. Waiting for the authenticated guest forward.',flush=True)
            deadline=time.monotonic()+180
            while not stopping():
                tunnel=scope.start(command,stdout=ssh_log,stderr=ssh_log)
                children.append(tunnel);opened=time.monotonic()
                while not stopping() and tunnel.poll() is None:
                    if host.poll() is not None:raise RuntimeError('Hardware codec service exited; inspect its local log')
                    if time.monotonic()-opened>30:deadline=time.monotonic()+180
                    time.sleep(.5)
                if stopping():break
                children.remove(tunnel)
                if time.monotonic()>deadline:raise TimeoutError('Guest SSH forward remained unavailable for 180 seconds')
                for _ in range(10):
                    if stopping():break
                    time.sleep(.5)
    except KeyboardInterrupt:
        pass
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
        scope.close()
        if args.ready_file:args.ready_file.unlink(missing_ok=True)


if __name__=='__main__':main()
