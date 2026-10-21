"""Extract Apple's original app CPIO for guest use; keep the full pkgdmg intact."""
import argparse
import hashlib
import lzma
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib

p = argparse.ArgumentParser()
p.add_argument('package', type=Path)
p.add_argument('--output', type=Path, default=Path('backend/media/Installer.cpio'))
a = p.parse_args()
with a.package.open('rb') as package:
    magic, header_size, version, toc_size, _, _ = struct.unpack('>4sHHQQI', package.read(28))
    if magic != b'xar!' or version != 1:
        raise ValueError('Expected an original Apple XAR install package')
    package.seek(header_size)
    toc = ET.fromstring(zlib.decompress(package.read(toc_size)))
    entry = next(f for f in toc.findall('./toc/file') if f.findtext('name') == 'Payload')
    data = entry.find('data')
    package.seek(header_size + toc_size + int(data.findtext('offset')))
    payload = package.read(int(data.findtext('length')))
    checksum = data.find('archived-checksum')
    if checksum is not None:
        assert checksum.attrib['style'].lower() == 'sha1'
        if hashlib.sha1(payload).hexdigest() != checksum.text:
            raise ValueError('Apple package payload checksum mismatch')

if payload[:4] != b'pbzx':
    raise ValueError('Expected a pbzx payload')
position = 12
a.output.parent.mkdir(parents=True, exist_ok=True)
with a.output.open('wb') as output:
    while position < len(payload):
        unpacked, length = struct.unpack_from('>QQ', payload, position)
        position += 16
        if unpacked > 64 * 1024 * 1024 or length > len(payload) - position:
            raise ValueError('Invalid pbzx chunk size')
        block = payload[position:position + length]
        position += length
        block = lzma.decompress(block) if block.startswith(b'\xfd7zXZ\0') else block
        if len(block) != unpacked:
            raise ValueError('Invalid pbzx chunk length')
        output.write(block)
print(f'Original app CPIO: {a.output} ({a.output.stat().st_size} bytes)')
print('For Contents/SharedSupport/SharedSupport.dmg, copy the entire original package.')
print('The Apple installer requires its original pkgdmg footer. Do not convert it.')
