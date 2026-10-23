"""Trusted Windows-only GPU metadata and handle handoff; never pixel transport.

The guest receives only fresh 128-bit target capabilities. Exported Win32
handles remain on this host, and are duplicated into the authenticated local
consumer's process, discovered from its exact loopback listening endpoint.
"""
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
import secrets
import socket
import struct


def exact(connection,size):
    result=bytearray()
    while len(result)<size:
        part=connection.recv(size-len(result))
        if not part:raise EOFError('GPU control closed')
        result.extend(part)
    return bytes(result)


def listener_owner(port):
    ip=c.WinDLL('iphlpapi');ip.GetExtendedTcpTable.argtypes=[c.c_void_p,c.POINTER(w.DWORD),w.BOOL,w.ULONG,c.c_int,w.ULONG]
    size=w.DWORD();status=ip.GetExtendedTcpTable(None,c.byref(size),False,2,3,0)
    if status!=122 or not 4<=size.value<=16*1024*1024:raise RuntimeError('GPU listener ownership unavailable')
    data=c.create_string_buffer(size.value)
    if ip.GetExtendedTcpTable(data,c.byref(size),False,2,3,0):raise RuntimeError('GPU listener ownership changed')
    raw=data.raw[:size.value];count,=struct.unpack_from('<I',raw)
    if count>(len(raw)-4)//24:raise RuntimeError('GPU listener ownership bounds')
    found=[]
    for i in range(count):
        state,address,local_port,_,_,pid=struct.unpack_from('<6I',raw,4+i*24)
        if state==2 and struct.pack('<I',address)==socket.inet_aton('127.0.0.1') and socket.ntohs(local_port&65535)==port:found.append(pid)
    if len(found)!=1 or found[0]==0:raise RuntimeError('GPU listener owner is ambiguous')
    return found[0]


class GpuControl:
    def __init__(self,config_file):
        data=Path(config_file).read_bytes()
        if len(data)!=36 or data[4:]==bytes(32):raise ValueError('Invalid private GPU control configuration')
        self.port,=struct.unpack('<I',data[:4]);self.socket=None;self.current=None;self.imported=False;self.targets=set()
        if not 1024<=self.port<=65535:raise ValueError('Invalid GPU control port')
        try:
            self.socket=socket.create_connection(('127.0.0.1',self.port),timeout=25)
            self.socket.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
            self.socket.sendall(b'NMV1'+data[4:])
            if exact(self.socket,1)!=b'A':raise RuntimeError('GPU control authentication refused')
            self.owner=listener_owner(self.port)
        except BaseException:
            self.close();raise

    def operation(self,code,capability=bytes(16),argument=bytes(8),extra=b''):
        if len(capability)!=16 or len(argument)!=8:raise ValueError('Invalid GPU metadata size')
        self.socket.sendall(code+capability+argument+extra)
        return struct.unpack('<I',exact(self.socket,4))[0]

    def import_source(self,process_id,descriptor):
        if self.imported or len(descriptor)!=72:raise ValueError('Invalid GPU source descriptor')
        if listener_owner(self.port)!=self.owner:raise RuntimeError('GPU consumer process changed')
        if type(process_id) is not int or not 0<process_id<=0xffffffff:raise ValueError('Invalid GPU producer process')
        # The consumer duplicates the worker-owned handles after receiving the
        # complete request. Cancellation cannot strand remote duplicates.
        status=self.operation(b'I',extra=struct.pack('<Q',process_id)+descriptor)
        if status:raise RuntimeError('GPU source import refused')
        self.imported=True

    def arm(self,width,height):
        if self.current is not None:raise RuntimeError('GPU target is already pending')
        capability=secrets.token_bytes(16)
        if self.operation(b'A',capability,struct.pack('<II',width,height)):raise RuntimeError('GPU target reservation refused')
        self.current=capability;return capability

    def reuse(self,capability,previous):
        if capability!=self.current or previous==capability:raise RuntimeError('GPU target reuse mismatch')
        if previous not in self.targets:raise RuntimeError('GPU target was not parked by this session')
        if self.operation(b'R',capability,extra=previous):
            # An expired or discarded backing cannot be retried. Release the
            # old capability even when the guest must materialize a new one.
            self.operation(b'D',previous)
            self.targets.discard(previous)
            return False
        self.targets.discard(previous)
        return True

    def copy(self,capability,actual,generation,park=False):
        if capability!=self.current or actual!=capability:raise RuntimeError('GPU target request mismatch')
        if self.operation(b'Q',capability)!=2:raise RuntimeError('GPU target is not bound')
        if self.operation(b'C',capability,struct.pack('<Q',generation)):raise RuntimeError('GPU target copy refused')
        if self.operation(b'P' if park else b'D',capability):raise RuntimeError('GPU target release refused')
        if park:self.targets.add(capability)
        self.current=None

    def close(self):
        if self.socket:
            try:
                if self.current:self.operation(b'D',self.current)
                for capability in self.targets:self.operation(b'D',capability)
            except (OSError,EOFError):pass
            self.socket.close();self.socket=None;self.current=None;self.targets.clear()
