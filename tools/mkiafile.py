#!/usr/bin/env python3
"""Wrap an HP 10391B relocatable inverse assembler (.R) into the disk file
that HP logic analyzers load (what IALDOWN.EXE creates on the analyzer).

    mkiafile.py IN.R OUTFILE "DESCRIPTION" [A|B|C|D]

Layout (verified byte-for-byte against analyzer-generated files):

  0x000  LIF volume header     ("HFSLIF", directory at sector 1)
  0x100  LIF directory         one entry "WS_FILE", type 0xC302, start
                               sector 2, length in 256-byte sectors
  0x200  data sectors          each 256-byte sector holds a big-endian
                               length word and up to 254 bytes of the
                               stream below; the last one is zero padded

  stream = u32be(len(R) + 1) + description (32 chars, space padded)
           + Invasm option byte + contents of the .R file

Only the option byte for "B" (0x00) has been verified against real files.
"""
import sys

OPTION_BYTE = {"B": 0x00}

LIF_VOLUME = bytes.fromhex(
    "80004846534c49460000000110000000"
    "00000001000000000000000100000001"
    "00000020111111111111"
) + bytes(0xF8 - 0x2A) + bytes.fromhex("111111111111") + bytes(2)


def build(rdata: bytes, desc: str, option: str) -> bytes:
    if option not in OPTION_BYTE:
        raise SystemExit(f"Invasm option {option!r} not supported (only B is verified)")
    d = desc.encode("ascii")
    if len(d) > 32:
        raise SystemExit("description must be 32 characters or fewer")
    stream = ((len(rdata) + 1).to_bytes(4, "big") + d.ljust(32, b" ")
              + bytes([OPTION_BYTE[option]]) + rdata)
    sectors = b""
    for i in range(0, len(stream), 254):
        chunk = stream[i:i + 254]
        sectors += (len(chunk).to_bytes(2, "big") + chunk).ljust(256, b"\0")
    nsect = len(sectors) // 256
    entry = (b"WS_FILE   " + bytes.fromhex("c302") + (2).to_bytes(4, "big")
             + nsect.to_bytes(4, "big") + bytes(6) + bytes.fromhex("8001")
             + bytes.fromhex("00000080"))
    end = bytes(10) + bytes.fromhex("ffff") + bytes(20)
    directory = (entry + end).ljust(256, b"\0")
    assert len(LIF_VOLUME) == 256
    return LIF_VOLUME + directory + sectors


def main():
    if len(sys.argv) not in (4, 5):
        raise SystemExit(__doc__)
    rfile, out, desc = sys.argv[1:4]
    option = sys.argv[4].upper() if len(sys.argv) == 5 else "B"
    with open(rfile, "rb") as f:
        data = build(f.read(), desc, option)
    with open(out, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main()
