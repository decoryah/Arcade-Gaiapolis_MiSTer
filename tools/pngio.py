"""Minimal PNG read/write: 8-bit truecolour, non-interlaced. No dependencies.

Enough for MAME snapshots (colour type 2, bit depth 8) and for writing the
reference renderer's own output and diff images.
"""
import struct, zlib

_SIG = b'\x89PNG\r\n\x1a\n'


def read(path):
    """-> (width, height, bytearray of w*h*3 RGB)"""
    d = open(path, 'rb').read()
    if d[:8] != _SIG:
        raise ValueError(f'{path}: not a PNG')
    i, idat, hdr, plte, trns = 8, bytearray(), None, None, None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i + 4])[0]
        typ = d[i + 4:i + 8]
        body = d[i + 8:i + 8 + ln]
        if typ == b'IHDR':
            hdr = struct.unpack('>IIBBBBB', body)
        elif typ == b'PLTE':
            plte = body
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        i += 12 + ln
    w, h, bd, ct, _cm, _fl, il = hdr
    if bd != 8 or il != 0 or ct not in (2, 3, 6):
        raise ValueError(f'{path}: unsupported PNG (depth {bd}, type {ct}, interlace {il})')
    nch = {2: 3, 3: 1, 6: 4}[ct]
    raw = zlib.decompress(bytes(idat))
    stride = w * nch
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ft = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos + stride]); pos += stride
        _unfilter(ft, line, prev, nch)
        if ct == 2:
            out[y * stride:(y + 1) * stride] = line
        elif ct == 6:
            for x in range(w):
                out[(y * w + x) * 3:(y * w + x) * 3 + 3] = line[x * 4:x * 4 + 3]
        else:
            for x in range(w):
                p = line[x] * 3
                out[(y * w + x) * 3:(y * w + x) * 3 + 3] = plte[p:p + 3]
        prev = line
    return w, h, out


def _unfilter(ft, line, prev, bpp):
    if ft == 0:
        return
    n = len(line)
    if ft == 1:
        for i in range(bpp, n):
            line[i] = (line[i] + line[i - bpp]) & 0xff
    elif ft == 2:
        for i in range(n):
            line[i] = (line[i] + prev[i]) & 0xff
    elif ft == 3:
        for i in range(n):
            a = line[i - bpp] if i >= bpp else 0
            line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xff
    elif ft == 4:
        for i in range(n):
            a = line[i - bpp] if i >= bpp else 0
            c = prev[i - bpp] if i >= bpp else 0
            b = prev[i]
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = (line[i] + pr) & 0xff
    else:
        raise ValueError(f'bad PNG filter {ft}')


def write(path, w, h, rgb):
    """rgb: bytes-like of w*h*3."""
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]
    def chunk(typ, body):
        return (struct.pack('>I', len(body)) + typ + body
                + struct.pack('>I', zlib.crc32(typ + body) & 0xffffffff))
    with open(path, 'wb') as f:
        f.write(_SIG)
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        f.write(chunk(b'IEND', b''))
