"""Verify authored NVDEC frames after CUDA/Vulkan VRAM sharing and GPU image copies.

Only the isolated validation executable is accepted. Every NV12 byte is read
back *after* the Vulkan plane-image operations, for independent comparison.
This is not a sustained playback benchmark or a guest integration test.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time

from cuda_identity import selected_device
from stream import Decoder


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture',type=Path,required=True)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--worker',type=Path,required=True)
    parser.add_argument('--gpu-name',required=True,help='Actual selected Windows renderer name')
    args=parser.parse_args()
    identity=json.loads(subprocess.check_output([str(args.worker.resolve()),'--interop-info'],timeout=5))
    if identity!={'mode':'nvdec-cuda-vulkan-plane-validation','validationReadback':True,'guestIntegrated':False}:
        raise ValueError('Only the isolated GPU interop validation worker is accepted')
    if args.fixture.stat().st_size>16*1024*1024 or args.baseline.stat().st_size>64*1024*1024:
        raise ValueError('Authored fixture exceeds qualification bounds')
    fixture=json.loads(args.fixture.read_text(encoding='utf-8'))
    expected=args.baseline.read_bytes()
    packets=fixture['packets'];size=fixture['width']*fixture['height']*3//2
    if not 1<=len(packets)<=120 or len(expected)!=size*len(packets):
        raise ValueError('Bounded fixture pixels and packets must agree')
    timestamps=sorted(packet['pts'] for packet in packets)
    if len(set(timestamps))!=len(timestamps):raise ValueError('Qualification fixture timestamps must be unique')
    positions={pts:index for index,pts in enumerate(timestamps)}
    index,name=selected_device(args.gpu_name)
    received=set();errors=[];started=time.monotonic()
    with Decoder('.',fixture['codec'],fixture['width'],fixture['height'],base64.b64decode(fixture['configuration'],validate=True),
                 worker=args.worker.resolve(),gpu_index=index) as decoder:
        def feed():
            try:
                for packet in packets:decoder.send(base64.b64decode(packet['data'],validate=True),packet['pts'],packet['key'])
                decoder.finish()
            except Exception as error:errors.append(str(error))
        sender=threading.Thread(target=feed,daemon=True);sender.start()
        while True:
            result=decoder.receive()
            if result is None:break
            pixels,metadata=result;pts=metadata['pts']
            if pts not in positions or pts in received:raise AssertionError('GPU output timestamp missing or duplicated')
            offset=positions[pts]*size
            reference=expected[offset:offset+size]
            if pixels!=reference:
                mismatch=[at for at,(actual,wanted) in enumerate(zip(pixels,reference)) if actual!=wanted]
                raise AssertionError(f'GPU plane pixels differ: frame {positions[pts]}, bytes {len(mismatch)}, first offset {mismatch[0]}')
            received.add(pts)
        sender.join(timeout=3)
        if sender.is_alive() or errors or decoder.errors:raise AssertionError((errors,decoder.errors))
        if len(received)!=len(packets):raise AssertionError('GPU output frame count mismatch')
    print(json.dumps({'passed':True,'gpu':name,'cudaOrdinal':index,'codec':fixture['codec'],'width':fixture['width'],'height':fixture['height'],
                      'frames':len(received),'comparedBytes':len(expected),'mismatchingBytes':0,'timestampsMatch':True,
                      'path':'NVDEC -> CUDA device copy -> shared device-local Vulkan buffer -> optimal NV12 plane images',
                      'cpuPixelAccessBeforeVulkan':False,'gpuSemaphoreHandoff':True,'deviceIdentity':'CUDA/Vulkan UUID equality',
                      'validationReadbackBytes':len(expected),'guestIntegrated':False,'sustainedPlaybackQualified':False,
                      'workerSHA256':hashlib.sha256(args.worker.read_bytes()).hexdigest(),'secondsIncludingValidation':round(time.monotonic()-started,4)}))


if __name__=='__main__':main()
