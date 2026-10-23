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


def payload(dump):
    return b''.join(bytes.fromhex(line.split(':', 1)[1][1:40].replace(' ', ''))
                    for line in dump.splitlines() if ':' in line)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    video = (args.out / 'fixture.mp4').resolve()
    baseline = (args.out / 'baseline.nv12').resolve()
    encoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=30', '-an', '-frames:v', '90',
        '-c:v', 'h264_nvenc', '-gpu', '0', '-bf', '2', '-g', '30', '-pix_fmt', 'nv12', str(video)])
    decoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-hwaccel', 'cuda', '-hwaccel_device', '0', '-hwaccel_output_format', 'cuda',
        '-c:v', 'h264_cuvid', '-i', str(video), '-an', '-vf', 'hwdownload,format=nv12',
        '-threads:v', '1', '-f', 'rawvideo', str(baseline)])
    report = json.loads(subprocess.check_output([str(args.ffprobe), '-v', 'error',
        '-select_streams', 'v:0', '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(video)], timeout=15))
    description = report['streams'][0]
    time_base = Fraction(description['time_base'])
    packets = report['packets']
    assert len(packets) == 90
    fixture = {'width': description['width'], 'height': description['height'],
        'configuration': base64.b64encode(payload(description['extradata'])).decode(),
        'packets': [{'pts': round(int(p['pts']) * time_base * 1000000000),
                     'dts': round(int(p['dts']) * time_base * 1000000000),
                     'duration': round(int(p['duration']) * time_base * 1000000000),
                     'key': 'K' in p.get('flags', ''),
                     'data': base64.b64encode(payload(p['data'])).decode()} for p in packets]}
    pts = [packet['pts'] for packet in fixture['packets']]
    assert pts != sorted(pts), 'Fixture must exercise B-frame reordering'
    assert baseline.stat().st_size == 320 * 180 * 3 // 2 * 90
    (args.out / 'input.json').write_text(json.dumps(fixture), encoding='utf-8')
    print(json.dumps({'authoredSyntheticFixture': True, 'frames': 90, 'inputReordered': True,
                      'nvenc': encoded, 'nvdecBaseline': decoded, 'softwareFallback': False}))


if __name__ == '__main__':
    main()
