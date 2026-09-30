#!/usr/bin/env python3
"""Pack standard PNG representations into an ICNS container, without iconutil."""
from pathlib import Path
import struct
import sys

source = Path(sys.argv[1])
output = Path(sys.argv[2])
representations = [
    (b'icp4', 'icon_16x16.png'), (b'icp5', 'icon_32x32.png'),
    (b'icp6', 'icon_32x32@2x.png'), (b'ic07', 'icon_128x128.png'),
    (b'ic08', 'icon_256x256.png'), (b'ic09', 'icon_512x512.png'),
    (b'ic10', 'icon_512x512@2x.png'), (b'ic11', 'icon_16x16@2x.png'),
    (b'ic12', 'icon_32x32@2x.png'), (b'ic13', 'icon_128x128@2x.png'),
    (b'ic14', 'icon_256x256@2x.png'),
]
chunks = []
for kind, filename in representations:
    png = (source / filename).read_bytes()
    chunks.append(kind + struct.pack('>I', 8 + len(png)) + png)
body = b''.join(chunks)
output.write_bytes(b'icns' + struct.pack('>I', 8 + len(body)) + body)
