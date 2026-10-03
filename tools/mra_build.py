#!/usr/bin/env python3
# Taken unchanged from plasticbugs/analogue-pocket-gaiapolis (tools/mra_build.py, GPL-3.0); here it builds the
# simulation images from mra/*.mra:  python tools/mra_build.py "mra/Gaiapolis (World ver EAF).mra" gaiapols.zip out.rom
"""Build the Pocket .rom image for the Gaiapolis core from a MAME romset.

A core is FPGA gateware: it cannot unzip a romset or run a script, so the ROM
image has to be assembled on a computer. This reads the .mra description and a
MAME `gaiapols` romset -- either the zip or a directory of loose files -- checks
every part's CRC32, assembles the image in the order the .mra gives, and
verifies the finished image against the md5 recorded in the .mra.

Supported MRA elements (the standard MiSTer subset):

  <part name="x" crc="y" [offset="0x1000" length="0x800"]/>
        a ROM, or a slice of one.
  <part repeat="N">FF</part>
        a run of literal bytes.
  <interleave output="16"> <part name=.. crc=.. map="01"/> ... </interleave>
        byte-interleave several ROMs into 16-bit words. Each digit of `map` is
        one byte of the output word, read RIGHT TO LEFT as the MRA format and
        mra-tools-c do: the rightmost digit is the word's first byte.  A digit
        is the 1-based byte of that part in the word ("01" = this ROM supplies
        the first/even byte; "10" = the second/odd byte).

Nothing but Python 3 is required. The same .mra works with the standard MiSTer
mra tools.

Usage:
    mra_build.py <file.mra> <romset.zip|romset_dir> [out.rom]
"""
import sys, os, zipfile, hashlib, zlib
import xml.etree.ElementTree as ET


def load_parts(path):
    """Every file in a zip or a directory, as (member path, lowercase base name, bytes).

    A MERGED romset keeps each clone's files in the parent's zip, and where a
    clone's ROM has the parent's name but other contents (MAME's "sldh") it is
    stored under the clone's subdirectory, e.g. nbajamte4/l4_..._ug12.ug12
    beside the parent's l4_..._ug12.ug12.  So files are not keyed by base name
    alone -- the last one read would win -- and get_part picks by CRC."""
    out = []
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                full = os.path.join(root, f)
                with open(full, 'rb') as fh:
                    out.append((os.path.relpath(full, path), f.lower(), fh.read()))
        if not out:
            sys.exit(f'error: {path} contains no files')
        return out
    if not os.path.exists(path):
        sys.exit(f'error: {path} not found')
    try:
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if not info.is_dir():
                    out.append((info.filename, os.path.basename(info.filename).lower(), zf.read(info)))
    except zipfile.BadZipFile:
        sys.exit(f'error: {path} is neither a directory nor a readable zip')
    return out


def _crc(data):
    return zlib.crc32(data) & 0xffffffff


def literal_bytes(node):
    text = (node.text or '').split()
    if not text:
        sys.exit('error: <part> with no name and no body')
    try:
        pattern = bytes(int(tok, 16) for tok in text)
    except ValueError:
        sys.exit(f'error: <part> body is not hex bytes: {node.text!r}')
    repeat = int(node.get('repeat', '1'), 0)
    return f'<fill {pattern.hex()} x{repeat}>', pattern * repeat


def get_part(parts, node):
    name = node.get('name')
    if name is None:
        return literal_bytes(node)
    crc = node.get('crc')
    # "a|b" accepts either (the MRA format allows alternatives)
    want = {int(c, 16) for c in crc.split('|')} if crc else None
    named = [(p, d) for p, b, d in parts if b == name.lower()]
    data = None
    if want is None:
        if named:
            # no CRC to choose by: prefer the copy at the top of the set
            data = min(named, key=lambda pd: pd[0].count('/'))[1]
    else:
        # the file of that name whose CRC matches (a merged set can hold a
        # clone's same-named file in a subdirectory), else any file with that
        # CRC: older dumps carry some files under other names (nbau12.u12
        # for l1_nba_jam_u12_sound_rom.u12), and the CRC identifies them.
        data = next((d for p, d in named if _crc(d) in want), None)
        if data is None:
            data = next((d for p, b, d in parts if _crc(d) in want), None)
        if data is None and named:
            got = ', '.join(f'{p} crc {_crc(d):08x}' for p, d in named)
            sys.exit(f'error: {name}: no copy has crc {crc} (found {got}); '
                     f'this .mra wants a different revision of the set')
    if data is None:
        sys.exit(f'error: {name} is missing from the romset')
    offset = int(node.get('offset', '0'), 0)
    length = node.get('length')
    if length is not None:
        length = int(length, 0)
        if offset + length > len(data):
            sys.exit(f'error: {name} slice {offset:#x}+{length:#x} exceeds {len(data):#x}')
        return f'{name}[{offset:#x}:{offset + length:#x}]', data[offset:offset + length]
    if offset:
        return f'{name}[{offset:#x}:]', data[offset:]
    return name, data


def do_interleave(parts, node):
    width = int(node.get('output', '16'), 0)
    if width % 8:
        sys.exit(f'error: interleave output="{width}" is not a whole number of bytes')
    nbytes = width // 8
    sources = []
    for child in node:
        if child.tag != 'part':
            sys.exit(f'error: <{child.tag}> inside <interleave> is not supported')
        m = child.get('map')
        if m is None or len(m) != nbytes:
            sys.exit(f'error: {child.get("name")} inside <interleave> needs a {nbytes}-digit map')
        label, data = get_part(parts, child)
        sources.append((label, data, m))
    # each source supplies `k` bytes of every output word, where k = number of
    # non-zero digits in its map; its data is consumed k bytes at a time
    n_words = None
    for label, data, m in sources:
        k = sum(1 for d in m if d != '0')
        if k == 0:
            sys.exit(f'error: {label} map {m} supplies no bytes')
        if len(data) % k:
            sys.exit(f'error: {label} length {len(data)} is not a multiple of {k}')
        words = len(data) // k
        if n_words is None:
            n_words = words
        elif words != n_words:
            sys.exit(f'error: interleave parts have different word counts ({label})')
    out = bytearray(n_words * nbytes)
    for label, data, m in sources:
        k = sum(1 for d in m if d != '0')
        for pos, d in enumerate(reversed(m)):     # rightmost digit = first byte
            if d == '0':
                continue
            src_index = int(d) - 1     # which of this part's k bytes per word
            out[pos::nbytes] = data[src_index::k]
    labels = ' + '.join(f'{l}(map {m})' for l, _, m in sources)
    return f'interleave{width}[{labels}]', bytes(out)


def build(mra_path, romset_path, verbose=False):
    tree = ET.parse(mra_path)
    rom = tree.getroot().find('rom')
    if rom is None:
        sys.exit('error: no <rom> element in the .mra')
    parts = load_parts(romset_path)
    image = bytearray()
    for node in rom:
        if node.tag == 'part':
            label, data = get_part(parts, node)
        elif node.tag == 'interleave':
            label, data = do_interleave(parts, node)
        else:
            continue
        if verbose:
            print(f'  {len(image):#08x}  {len(data):7d}  {label}')
        image += data
    expected = rom.get('md5')
    actual = hashlib.md5(image).hexdigest()
    if expected and expected.lower() != 'none' and expected.lower() != actual:
        sys.exit(f'error: built image md5 {actual} does not match the .mra ({expected})')
    return bytes(image), actual


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mra_path, romset_path = sys.argv[1], sys.argv[2]
    tree = ET.parse(mra_path)
    setname = tree.getroot().findtext('setname') or 'out'
    out_path = sys.argv[3] if len(sys.argv) > 3 else f'{setname}.rom'
    image, md5 = build(mra_path, romset_path, verbose=True)
    with open(out_path, 'wb') as f:
        f.write(image)
    print(f'wrote {out_path}: {len(image)} bytes, md5 {md5}')


if __name__ == '__main__':
    main()
