"""Execute an authored NV12 encode/decode round trip through the host transport.

Run this in the Intel VM with a loopback SSH forward to host.py. This qualifies
the transport and hardware codec path, not Safari or VideoToolbox integration.
No video file, browser cookies or account data is read.
"""
import argparse
import json
from urllib.request import Request, urlopen
from urllib.parse import urlencode, urlsplit


def fixture(width, height, frames):
    output = bytearray()
    for frame in range(frames):
        output.extend(32 + ((x//16+y//16+frame) % 16)*10
                      for y in range(height) for x in range(width))
        output.extend(bytes((96, 160))*(width*height//4))
    return bytes(output)


def request(base, operation, codec, data, width, height, frames):
    url = base + f'/v1/{operation}/{codec}?' + urlencode(dict(width=width, height=height, frames=frames))
    req = Request(url, data=data, method='POST', headers={'Content-Type': 'application/octet-stream'})
    with urlopen(req, timeout=30) as response:
        result = response.read(64*1024*1024+1)
        if len(result) > 64*1024*1024:
            raise RuntimeError('Oversized response')
        expected = codec + ('_nvenc' if operation == 'encode' else '_cuvid')
        if response.headers.get('X-NativeMac-Engine') != expected:
            raise RuntimeError('Hardware engine was not selected')
        if response.headers.get('X-NativeMac-Frames') != str(frames):
            raise RuntimeError('Incorrect frame count')
        return result, {key: response.headers['X-NativeMac-'+key] for key in ('Engine', 'GPU', 'Frames', 'Seconds', 'Peak-MiB')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='http://127.0.0.1:54882')
    parser.add_argument('--width', type=int, default=320)
    parser.add_argument('--height', type=int, default=180)
    parser.add_argument('--frames', type=int, default=12)
    args = parser.parse_args()
    url = urlsplit(args.base)
    if url.scheme != 'http' or url.hostname != '127.0.0.1' or url.path or url.query or url.fragment:
        parser.error('Use an HTTP loopback SSH forward')
    w, h, n = args.width, args.height, args.frames
    if w < 16 or h < 16 or w > 3840 or h > 2160 or w % 2 or h % 2 or not 1 <= n <= 120 or w*h*3//2*n > 64*1024*1024:
        parser.error('Unsupported fixture size')
    original = fixture(w, h, n)
    for codec in ('h264', 'hevc'):
        compressed, encoder = request(args.base, 'encode', codec, original, w, h, n)
        decoded, decoder = request(args.base, 'decode', codec, compressed, w, h, n)
        if len(decoded) != len(original):
            raise RuntimeError('Not all decoded frames were returned')
        luma, chroma, stride = 0, 0, w*h*3//2
        for frame in range(n):
            start = frame*stride
            luma += sum(abs(a-b) for a, b in zip(original[start:start+w*h], decoded[start:start+w*h]))
            chroma += sum(abs(a-b) for a, b in zip(original[start+w*h:start+stride], decoded[start+w*h:start+stride]))
        luma /= w*h*n
        chroma /= w*h*n//2
        passed = luma < 4 and chroma < 4 and encoder['GPU'] == decoder['GPU']
        print(json.dumps({'codec': codec, 'width': w, 'height': h, 'frames': n,
                          'encodedBytes': len(compressed), 'decodedBytes': len(decoded),
                          'lumaMAE': luma, 'chromaMAE': chroma,
                          'encoder': encoder, 'decoder': decoder,
                          'videoToolboxRegistered': False, 'passed': passed}), flush=True)
        if not passed:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
