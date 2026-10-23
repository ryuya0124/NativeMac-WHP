"""Fixed 48-kHz stereo-float VM playback on Windows; no microphone or file I/O."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import math
import socket
import struct
import time


class Format(c.Structure):
    _fields_=[('tag',w.WORD),('channels',w.WORD),('rate',w.DWORD),('average',w.DWORD),('align',w.WORD),('bits',w.WORD),('extra',w.WORD)]


class Header(c.Structure):
    _fields_=[('data',c.c_void_p),('size',w.DWORD),('recorded',w.DWORD),('user',c.c_size_t),('flags',w.DWORD),('loops',w.DWORD),('next',c.c_void_p),('reserved',c.c_size_t)]


class Playback:
    def __init__(self):
        self.api=c.WinDLL('winmm',use_last_error=True)
        self.api.waveOutOpen.argtypes=[c.POINTER(w.HANDLE),w.UINT,c.POINTER(Format),c.c_size_t,c.c_size_t,w.DWORD]
        for name in ('waveOutPrepareHeader','waveOutUnprepareHeader','waveOutWrite'):
            getattr(self.api,name).argtypes=[w.HANDLE,c.POINTER(Header),w.UINT]
        for name in ('waveOutClose','waveOutReset'):getattr(self.api,name).argtypes=[w.HANDLE]
        self.handle=w.HANDLE();fmt=Format(3,2,48000,384000,8,32,0)
        self.check(self.api.waveOutOpen(c.byref(self.handle),0xffffffff,c.byref(fmt),0,0,0))
        self.slots=[];self.index=0;self.frames=0;self.nonzero=0;self.reported=0
        try:
            for _ in range(4):
                data=c.create_string_buffer(16384);header=Header(c.addressof(data),16384,0,0,0,0,None,0)
                self.check(self.api.waveOutPrepareHeader(self.handle,c.byref(header),c.sizeof(header)))
                self.slots.append([data,header,False])
        except BaseException:self.close();raise

    @staticmethod
    def check(status):
        if status:raise RuntimeError('Windows audio status '+str(status))

    def write(self,block):
        data,header,used=self.slots[self.index];deadline=time.monotonic()+2
        while used and not header.flags&1:
            if time.monotonic()>deadline:raise TimeoutError('Windows audio playback deadline')
            time.sleep(.001)
        c.memmove(data,block,len(block));header.size=len(block)
        self.check(self.api.waveOutWrite(self.handle,c.byref(header),c.sizeof(header)))
        self.slots[self.index][2]=True;self.index=(self.index+1)%len(self.slots)
        self.frames+=len(block)//8
        self.nonzero+=sum(1 for value, in struct.iter_unpack('<f',block) if abs(value)>1e-6)
        if time.monotonic()-self.reported>=5:
            print(json.dumps({'stage':'windows-audio-playback','framesSubmitted':self.frames,'nonzeroSamples':self.nonzero}),flush=True);self.reported=time.monotonic()

    def close(self):
        if not self.handle:return
        self.api.waveOutReset(self.handle)
        for _,header,_ in self.slots:self.api.waveOutUnprepareHeader(self.handle,c.byref(header),c.sizeof(header))
        self.api.waveOutClose(self.handle);self.handle=None


def exact(connection,size):
    result=bytearray()
    while len(result)<size:
        value=connection.recv(size-len(result))
        if not value:raise EOFError('VM audio disconnected')
        result.extend(value)
    return bytes(result)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--port',type=int,default=54884);args=parser.parse_args()
    if not 1<=args.port<=65535:parser.error('Invalid port')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',args.port));listener.listen(1)
        print(json.dumps({'stage':'audio-ready','port':args.port}),flush=True)
        while True:
            connection,_=listener.accept();player=None
            try:
                connection.settimeout(10)
                if not connection.recv(1,socket.MSG_PEEK):continue
                if exact(connection,4)!=b'NMA1':raise ValueError('Unknown PCM protocol')
                player=Playback()
                while True:
                    size,=struct.unpack('!I',exact(connection,4))
                    if not 8<=size<=16384 or size%8:raise ValueError('Invalid PCM block size')
                    block=exact(connection,size)
                    if any(not math.isfinite(value) or abs(value)>1 for value, in struct.iter_unpack('<f',block)):raise ValueError('Invalid PCM sample')
                    player.write(block)
            except (OSError,EOFError,ValueError,RuntimeError,TimeoutError) as error:
                print(json.dumps({'stage':'audio-session-end','reason':str(error)[:120]}),flush=True)
            finally:
                if player:player.close()
                connection.close()


if __name__=='__main__':main()
