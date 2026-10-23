"""Small streaming Matroska writer for compressed VideoToolbox samples.

No video is decoded or encoded here. CodecPrivate is the original avcC/hvcC
configuration and blocks contain the original length-prefixed codec packets.
One cluster per packet preserves presentation timestamps and decode order.
"""
import struct


def size(value):
    if not 0 <= value < (1 << 56)-1:
        raise ValueError('Invalid EBML element size')
    for width in range(1, 9):
        if value < (1 << (7*width))-1:
            return (value | (1 << (7*width))).to_bytes(width, 'big')
    raise ValueError('Oversized EBML element')


def element(identifier, payload):
    return bytes.fromhex(identifier)+size(len(payload))+payload


def integer(identifier, value):
    if not 0 <= value < 1 << 64:
        raise ValueError('Invalid unsigned EBML value')
    width=max(1, (value.bit_length()+7)//8)
    return element(identifier, value.to_bytes(width, 'big'))


def header(codec, width, height, configuration):
    if codec not in ('h264', 'hevc'):
        raise ValueError('Unsupported codec')
    if not 16 <= width <= 3840 or not 16 <= height <= 2160 or width % 2 or height % 2:
        raise ValueError('Unsupported NV12 dimensions')
    if not 7 <= len(configuration) <= 65536 or configuration[0] != 1:
        raise ValueError('Expected original avcC/hvcC configuration')
    ebml=element('1a45dfa3', integer('4286',1)+integer('42f7',1)+integer('42f2',4)+
                 integer('42f3',8)+element('4282',b'matroska')+integer('4287',4)+integer('4285',2))
    info=element('1549a966',integer('2ad7b1',1)+element('4d80',b'NativeMac')+element('5741',b'NativeMac'))
    codec_id=b'V_MPEG4/ISO/AVC' if codec=='h264' else b'V_MPEGH/ISO/HEVC'
    video=element('e0',integer('b0',width)+integer('ba',height))
    track=element('ae',integer('d7',1)+integer('73c5',1)+integer('83',1)+integer('9c',0)+
                  element('86',codec_id)+element('63a2',configuration)+video)
    # Unknown-sized segment permits packets before the stream is complete.
    return ebml+bytes.fromhex('1853806701ffffffffffffff')+info+element('1654ae6b',track)


def packet(data, presentation_nanoseconds, keyframe):
    if not 0 < len(data) <= 8*1024*1024:
        raise ValueError('Unsupported compressed packet length')
    if not 0 <= presentation_nanoseconds < 1 << 63:
        raise ValueError('Unsupported packet timestamp')
    block=b'\x81'+struct.pack('>hB',0,0x80 if keyframe else 0)+data
    return element('1f43b675',integer('e7',presentation_nanoseconds)+element('a3',block))
