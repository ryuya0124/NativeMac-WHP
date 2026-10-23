"""Create an authored fixture and an independent decode byte baseline.

Windows only: codec children use host.hardware_job's fixed 20 s / 1 GiB bound.
No browser video, user movie, shader or credential is used as fixture data.
"""
import argparse
import base64
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import struct

from host import hardware_job
from cuda_identity import selected_device


def payload(dump):
    return b''.join(bytes.fromhex(line.split(':', 1)[1][1:40].replace(' ', ''))
                    for line in dump.splitlines() if ':' in line)


def vp9_configuration(video):
    """Read the muxer's actual vpcC box, which ffprobe omits as extradata."""
    data=video.read_bytes()
    def boxes(start,end):
        while start<end:
            if end-start<8:raise ValueError('Truncated authored MP4 box')
            size=int.from_bytes(data[start:start+4],'big');kind=data[start+4:start+8];header=8
            if size==1:
                if end-start<16:raise ValueError('Truncated large MP4 box')
                size=int.from_bytes(data[start+8:start+16],'big');header=16
            if size==0:size=end-start
            if size<header or start+size>end:raise ValueError('Invalid authored MP4 box size')
            begin,stop=start+header,start+size
            if kind==b'vpcC':yield data[begin:stop]
            elif kind in (b'moov',b'trak',b'mdia',b'minf',b'stbl'):yield from boxes(begin,stop)
            elif kind==b'stsd':yield from boxes(begin+8,stop)
            elif kind==b'vp09':yield from boxes(begin+78,stop)
            start=stop
    records=list(boxes(0,len(data)))
    if len(records)!=1 or not 12<=len(records[0])<=65536:raise ValueError('Expected one authored VP9 configuration')
    return records[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--width',type=int,default=320)
    parser.add_argument('--height',type=int,default=180)
    parser.add_argument('--frames',type=int,default=90)
    parser.add_argument('--codec',choices=('h264','hevc','vp9'),default='h264')
    parser.add_argument('--vp9-alt-ref',action='store_true',help='Request encoder alternate references; the encoder may omit them')
    parser.add_argument('--vp9-hidden-key',action='store_true',help='Replace the first keyframe with an invisible keyframe plus redisplay superframe')
    parser.add_argument('--vp9-show-existing',action='store_true',help='Insert a reference-surface redisplay after the authored keyframe')
    parser.add_argument('--bframes',type=int,choices=(0,2),default=2)
    parser.add_argument('--gpu-name',help='Actual selected renderer name; required when several CUDA adapters exist')
    args = parser.parse_args()
    if args.codec=='vp9' and args.bframes:parser.error('VP9 requires --bframes 0; use --vp9-alt-ref for invisible references')
    if args.vp9_alt_ref and args.codec!='vp9':parser.error('--vp9-alt-ref requires VP9')
    if args.vp9_show_existing and args.codec!='vp9':parser.error('--vp9-show-existing requires VP9')
    if args.vp9_hidden_key and (args.codec!='vp9' or args.vp9_show_existing):parser.error('--vp9-hidden-key requires VP9 and excludes --vp9-show-existing')
    w,h,n=args.width,args.height,args.frames
    gpu_index,gpu_name=selected_device(args.gpu_name)
    output_frames=n+int(args.vp9_show_existing)
    if not 128<=w<=3840 or not 128<=h<=2160 or w%2 or h%2 or not 4<=n or output_frames>120 or w*h*3//2*output_frames>64*1024*1024:parser.error('Even dimensions, 4..120 output frames, at most 64 MiB of fixture pixels required')
    args.out.mkdir(parents=True, exist_ok=False)
    video = (args.out / 'fixture.mp4').resolve()
    baseline = (args.out / 'baseline.nv12').resolve()
    encoder_options=(['-c:v','libvpx-vp9','-deadline','good' if args.vp9_alt_ref else 'realtime','-cpu-used','4' if args.vp9_alt_ref else '8','-threads','4','-lag-in-frames','16' if args.vp9_alt_ref else '0',
                      '-auto-alt-ref','1' if args.vp9_alt_ref else '0','-pix_fmt','yuv420p'] if args.codec=='vp9' else
                     ['-c:v',args.codec+'_nvenc','-gpu',str(gpu_index),'-bf',str(args.bframes),'-surfaces','4','-rc-lookahead','0','-pix_fmt','nv12'])
    encoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-f', 'lavfi', '-i', f'testsrc2=size={w}x{h}:rate=30', '-an', '-frames:v', str(n),
        *encoder_options,'-g','30',str(video)])
    if args.vp9_show_existing or args.vp9_hidden_key:
        source=json.loads(subprocess.check_output([str(args.ffprobe),'-v','error','-select_streams','v:0','-show_packets','-show_data','-of','json',str(video)],timeout=15))
        packets=[payload(packet['data']) for packet in source['packets']]
        if len(packets)!=n or packets[0][0]&0xfe!=0x82:raise ValueError('Expected an authored profile-0 visible keyframe')
        ivf=args.out/'show-existing.ivf'
        with ivf.open('wb') as stream:
            stream.write(struct.pack('<4sHH4sHHIIII',b'DKIF',0,32,b'VP90',w,h,60,1,output_frames,0))
            for index,packet in enumerate(packets):
                if index==0 and args.vp9_hidden_key:
                    hidden=bytes([packet[0]&~2])+packet[1:]
                    magnitude=max(1,(len(hidden).bit_length()+7)//8)
                    marker=0xc0|((magnitude-1)<<3)|1
                    packet=hidden+b'\x88'+bytes([marker])+len(hidden).to_bytes(magnitude,'little')+(1).to_bytes(magnitude,'little')+bytes([marker])
                stream.write(struct.pack('<IQ',len(packet),index*2));stream.write(packet)
                if index==0 and args.vp9_show_existing:
                    # Profile 0, show_existing_frame=1, frame_to_show_map_idx=0.
                    # A keyframe refreshes every reference slot. No new decode
                    # occurs here, but a new presentation timestamp is required.
                    stream.write(struct.pack('<IQ',1,1));stream.write(b'\x88')
        video=(args.out/'fixture-show-existing.mp4').resolve()
        hardware_job([str(args.ffmpeg),'-hide_banner','-loglevel','error','-nostdin','-i',str(ivf),'-an','-c:v','copy',str(video)])
    # FFmpeg's CUVID wrapper omits show_existing_frame outputs. For this
    # regression fixture only, compare the authored hardware worker against
    # FFmpeg's separate software VP9 reference. This is never a live fallback.
    reference_options=(['-c:v','vp9','-i',str(video),'-pix_fmt','nv12'] if args.vp9_show_existing or args.vp9_hidden_key else
                       ['-hwaccel','cuda','-hwaccel_device',str(gpu_index),'-hwaccel_output_format','cuda',
                        '-c:v',args.codec+'_cuvid','-i',str(video),'-vf','hwdownload,format=nv12'])
    decoded = hardware_job([str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin',
        *reference_options,'-an','-threads:v', '1', '-fps_mode', 'passthrough','-enc_time_base:v','1/1000000000','-f', 'rawvideo', str(baseline)])
    report = json.loads(subprocess.check_output([str(args.ffprobe), '-v', 'error',
        '-select_streams', 'v:0', '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(video)], timeout=15))
    description = report['streams'][0]
    time_base = Fraction(description['time_base'])
    packets = report['packets']
    assert len(packets) == output_frames
    fixture = {'codec':args.codec,'width': description['width'], 'height': description['height'],
        'configuration': base64.b64encode(vp9_configuration(video) if args.codec=='vp9' else payload(description['extradata'])).decode(),
        'packets': [{'pts': round(int(p['pts']) * time_base * 1000000000),
                     'dts': round(int(p['dts']) * time_base * 1000000000),
                     'duration': round(int(p['duration']) * time_base * 1000000000),
                     'key': 'K' in p.get('flags', ''),
                     'data': base64.b64encode(payload(p['data'])).decode()} for p in packets]}
    pts = [packet['pts'] for packet in fixture['packets']]
    assert (pts != sorted(pts)) == bool(args.bframes), 'Fixture must exercise the requested reordering mode'
    assert baseline.stat().st_size == w*h*3//2*output_frames
    (args.out / 'input.json').write_text(json.dumps(fixture), encoding='utf-8')
    print(json.dumps({'authoredSyntheticFixture': True,'gpu':gpu_name,'cudaOrdinal':gpu_index,'codec':args.codec,'width':w,'height':h,'frames':output_frames,'showExistingFrame':args.vp9_show_existing,'hiddenKeySuperframe':args.vp9_hidden_key, 'inputReordered': bool(args.bframes),
                      'fixtureEncoder':'libvpx-vp9' if args.codec=='vp9' else 'nvenc',
                      'fixtureEncode': encoded,'referenceDecoder':'ffmpeg-software-vp9' if args.vp9_show_existing or args.vp9_hidden_key else 'nvdec',
                      'referenceDecode': decoded,'liveDecodeSoftwareFallback': False}))


if __name__ == '__main__':
    main()
