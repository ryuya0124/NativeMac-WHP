"""Create an authored B-frame fixture and an independent NVDEC byte baseline.

Windows only: codec children use host.hardware_job's fixed 20 s / 1 GiB bound.
No browser video, user movie, shader or credential is used as fixture data.
"""
import argparse
import base64
from fractions import Fraction
import json
from pathlib import Path
import subprocess

from host import hardware_job
from cuda_identity import selected_device


def payload(dump):
    return b''.join(bytes.fromhex(line.split(':', 1)[1][1:40].replace(' ', ''))
                    for line in dump.splitlines() if ':' in line)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--width',type=int,default=320)
    parser.add_argument('--height',type=int,default=180)
    parser.add_argument('--frames',type=int,default=90)
    parser.add_argument('--codec',choices=('h264','hevc'),default='h264')
    parser.add_argument('--bframes',type=int,choices=(0,2),default=2)
    parser.add_argument('--gpu-name',help='Actual selected renderer name; required when several CUDA adapters exist')
    args = parser.parse_args()
    w,h,n=args.width,args.height,args.frames
    gpu_index,gpu_name=selected_device(args.gpu_name)
    if not 128<=w<=3840 or not 128<=h<=2160 or w%2 or h%2 or not 4<=n<=120 or w*h*3//2*n>64*1024*1024:parser.error('Even dimensions, 4..120 frames, at most 64 MiB of fixture pixels required')
    args.out.mkdir(parents=True, exist_ok=False)
    video = (args.out / 'fixture.mp4').resolve()
    baseline = (args.out / 'baseline.nv12').resolve()
    encoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i', f'testsrc2=size={w}x{h}:rate=30', '-an', '-frames:v', str(n),
        '-c:v', args.codec+'_nvenc', '-gpu', str(gpu_index), '-bf', str(args.bframes), '-g', '30', '-surfaces','4','-rc-lookahead','0','-pix_fmt', 'nv12', str(video)])
    decoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-hwaccel', 'cuda', '-hwaccel_device', str(gpu_index), '-hwaccel_output_format', 'cuda',
        '-c:v', args.codec+'_cuvid', '-i', str(video), '-an', '-vf', 'hwdownload,format=nv12',
        '-threads:v', '1', '-f', 'rawvideo', str(baseline)])
    report = json.loads(subprocess.check_output([str(args.ffprobe), '-v', 'error',
        '-select_streams', 'v:0', '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(video)], timeout=15))
    description = report['streams'][0]
    time_base = Fraction(description['time_base'])
    packets = report['packets']
    assert len(packets) == n
    fixture = {'codec':args.codec,'width': description['width'], 'height': description['height'],
        'configuration': base64.b64encode(payload(description['extradata'])).decode(),
        'packets': [{'pts': round(int(p['pts']) * time_base * 1000000000),
                     'dts': round(int(p['dts']) * time_base * 1000000000),
                     'duration': round(int(p['duration']) * time_base * 1000000000),
                     'key': 'K' in p.get('flags', ''),
                     'data': base64.b64encode(payload(p['data'])).decode()} for p in packets]}
    pts = [packet['pts'] for packet in fixture['packets']]
    assert (pts != sorted(pts)) == bool(args.bframes), 'Fixture must exercise the requested reordering mode'
    assert baseline.stat().st_size == w*h*3//2*n
    (args.out / 'input.json').write_text(json.dumps(fixture), encoding='utf-8')
    print(json.dumps({'authoredSyntheticFixture': True,'gpu':gpu_name,'cudaOrdinal':gpu_index,'codec':args.codec,'width':w,'height':h,'frames': n, 'inputReordered': bool(args.bframes),
                      'nvenc': encoded, 'nvdecBaseline': decoded, 'softwareFallback': False}))


if __name__ == '__main__':
    main()
