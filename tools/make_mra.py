#!/usr/bin/env python3
"""Writes the three Gaiapolis MRAs (mra/*.mra) from a MAME gaiapols.zip.

The image layout (docs/mister-memory.md) is the one target/mister/gaia_mem.sv
loads: regions in the order below, 0x1360000 bytes. The default EEPROM is a
separate download (index 2): the HPS then also saves and restores it
(<nvram index="2">), so the game's settings and records persist.

    python tools/make_mra.py /path/to/gaiapols.zip
"""
import sys, zipfile, os

SETS = [
    # setname, title, region, program ROM names, nvram file inside the zip
    ("gaiapols",  "Gaiapolis (World ver EAF)", "World", ("123eaf11.19p", "123eaf12.17p"), "gaiapols.nv"),
    ("gaiapolsj", "Gaiapolis (Japan ver JAF)", "Japan", ("123jaf11.19p", "123jaf12.17p"), "gaiapolsj/gaiapolsj.nv"),
    ("gaiapolsu", "Gaiapolis (USA ver UAF)",   "USA",   ("123uaf11.19p", "123uaf12.17p"), "gaiapolsu/gaiapolsu.nv"),
]
CRC = {   # the files of the merged set, by base name
    "123e01.36j": "9dbc9678", "123e02.34j": "b8e3f500", "123e03.36m": "fde4749f", "123e04.32n": "0d4d5b8b",
    "123e05.29n": "7d123f3e", "123e06.26n": "fa50121e", "123e07.24m": "f1a1db0f", "123e09.19l": "4b3b57e7",
    "123e13.9c": "e772f822", "123e14.2g": "65dfd3ff", "123e15.2m": "7017ff07", "123e16.2t": "a3238200",
    "123e17.2x": "bd0b9fb9", "123e18.36u": "3719b6d4", "123e19.34u": "219a7c26", "123e20.36y": "490a6f64",
    "123e21.34y": "1888947b",
    "123eaf11.19p": "9c324ade", "123eaf12.17p": "1dfa14c5",
    "123jaf11.19p": "19919571", "123jaf12.17p": "4246e595",
    "123uaf11.19p": "39dc1298", "123uaf12.17p": "c633cf52",
}

def hexdump(data):
    lines = []
    for i in range(0, len(data), 16):
        lines.append(" ".join("%02X" % b for b in data[i:i + 16]))
    return "\n".join(lines)

def mra(setname, title, region, prog, nvdata):
    p0, p1 = prog
    return f"""<misterromdescription>
    <rotation>vertical (cw)</rotation>
    <name>{title}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>1993</year>
    <manufacturer>Konami</manufacturer>
    <players>2</players>
    <joystick>8</joystick>
    <rbf>gaiapolis</rbf>
    <region>{region}</region>
    <platform>Konami pre-GX</platform>

    <!--
      Flat image for the Gaiapolis core (target/mister/gaia_mem.sv):

        0x0000000  0x300000  68000 program
        0x0300000  0x040000  Z80 sound program, 16 x 16 KB banks
        0x0340000  0x200000  K056832 tile ROM, 4bpp chunky
        0x0540000  0x180000  ROZ characters (gfx3)
        0x06C0000  0x0A0000  ROZ tile map (gfx4)
        0x0760000  0x400000  K054539 PCM
        0x0B60000  0x800000  K055673 sprite ROM, 64-bit words
        0x1360000            end

      Expects the MAME 0.289 merged romset (gaiapols.zip holding the parent and the
      two clones) or the split sets: parts are found by name, whatever folder holds them.
    -->
    <rom index="0" zip="{setname}.zip|gaiapols.zip" md5="None">

        <!-- 68000 program, 16-bit big-endian words: the even byte is the first ROM -->
        <interleave output="16">
            <part name="123e07.24m" crc="{CRC['123e07.24m']}" map="01"/>
            <part name="123e09.19l" crc="{CRC['123e09.19l']}" map="10"/>
        </interleave>
        <interleave output="16">
            <part name="{p0}" crc="{CRC[p0]}" map="01"/>
            <part name="{p1}" crc="{CRC[p1]}" map="10"/>
        </interleave>
        <part repeat="0x80000">00</part>

        <!-- Z80 sound program -->
        <part name="123e13.9c" crc="{CRC['123e13.9c']}"/>

        <!--
          K056832 tile ROM. MAME's ROM_LOADTILE_WORD is
          ROM_GROUPWORD|ROM_SKIP(3)|ROM_REVERSE, giving 5-byte groups whose
          fifth byte (the unused 5th plane) is always 0 for this game. Dropping
          it leaves 4bpp packed chunky, 4 bytes per 8-pixel row.
        -->
        <interleave output="32">
            <part name="123e16.2t" crc="{CRC['123e16.2t']}" map="0012"/>
            <part name="123e17.2x" crc="{CRC['123e17.2x']}" map="1200"/>
        </interleave>

        <!-- ROZ character ROM (gfx3), 4bpp 16x16 packed MSB -->
        <part name="123e04.32n" crc="{CRC['123e04.32n']}"/>
        <part name="123e05.29n" crc="{CRC['123e05.29n']}"/>
        <part name="123e06.26n" crc="{CRC['123e06.26n']}"/>

        <!-- ROZ tilemap ROM (gfx4): colour nibbles, then two attribute bytes -->
        <part name="123e01.36j" crc="{CRC['123e01.36j']}"/>
        <part name="123e02.34j" crc="{CRC['123e02.34j']}"/>
        <part name="123e03.36m" crc="{CRC['123e03.36m']}"/>

        <!-- K054539 PCM samples, shared by both chips -->
        <part name="123e14.2g" crc="{CRC['123e14.2g']}"/>
        <part name="123e15.2m" crc="{CRC['123e15.2m']}"/>

        <!--
          K055673 sprite ROM, 64-bit words (ROM_LOAD64_WORD, 8-byte stride).
          One 64-bit word is one complete 16-pixel row of a 4bpp tile.
        -->
        <interleave output="64">
            <part name="123e19.34u" crc="{CRC['123e19.34u']}" map="00000021"/>
            <part name="123e21.34y" crc="{CRC['123e21.34y']}" map="00002100"/>
            <part name="123e18.36u" crc="{CRC['123e18.36u']}" map="00210000"/>
            <part name="123e20.36y" crc="{CRC['123e20.36y']}" map="21000000"/>
        </interleave>
    </rom>

    <!-- the board's factory EEPROM: without it the game boots upside down with an error -->
    <rom index="2">
        <part>
{hexdump(nvdata)}
        </part>
    </rom>
    <nvram index="2" size="128"/>

    <buttons names="Button 1,Button 2,Button 3,Start,Coin" default="A,B,R,Start,Select" count="3"/>
</misterromdescription>
"""

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    z = zipfile.ZipFile(sys.argv[1])
    names = {os.path.basename(i.filename): i for i in z.infolist()}
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mra")
    os.makedirs(out, exist_ok=True)
    for setname, title, region, prog, nv in SETS:
        info = z.getinfo(nv)
        data = z.read(nv)
        assert len(data) == 128, (nv, len(data))
        for n in prog:
            assert ("%08x" % names[n].CRC) == CRC[n], (n, "%08x" % names[n].CRC, CRC[n])
        path = os.path.join(out, title + ".mra")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(mra(setname, title, region, prog, data))
        print("wrote", os.path.normpath(path), "(nvram crc %08x)" % info.CRC)

if __name__ == "__main__":
    sys.exit(main())
