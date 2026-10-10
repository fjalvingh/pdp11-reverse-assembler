#!/bin/sh
# Assemble src/IPDP11.S with the HP 10391B assembler (iadisk/ASM.EXE)
# running under the emu2 DOS emulator (https://github.com/dmsc/emu2).
#
#   EMU2=/path/to/emu2 ./build.sh
#
# Produces out/IPDP11.R (relocatable inverse assembler), out/IPDP11.LST
# (listing) and out/IPDP11 (analyzer disk file, see tools/mkiafile.py).
set -e
cd "$(dirname "$0")"

# Find emu2: $EMU2, then PATH, then a local build in tools/emu2 (built from
# source on first use; needs git, make and a C compiler).
if [ -z "$EMU2" ]; then
    if command -v emu2 >/dev/null 2>&1; then
        EMU2=emu2
    else
        EMU2=$PWD/tools/emu2/emu2
        if [ ! -x "$EMU2" ]; then
            echo "emu2 not found, building it in tools/emu2 ..." >&2
            [ -d tools/emu2 ] || git clone --depth 1 https://github.com/dmsc/emu2 tools/emu2
            make -C tools/emu2 >/dev/null
        fi
    fi
fi
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/HP64700/TABLES" out
cp iadisk/TABLES/AIAL.txt "$W/HP64700/TABLES/AIAL"
cp iadisk/ASM.EXE "$W/"
# DOS line endings for the assembler
sed 's/$/\r/' src/IPDP11.S > "$W/IPDP11.S"

( cd "$W" && EMU2_DRIVE_C="$W" EMU2_DEFAULT_DRIVE=C "$EMU2" ASM.EXE -ox IPDP11.S ) \
    | tr -d '\r' > out/IPDP11.LST

grep -E '^Errors=' out/IPDP11.LST
cp "$W/ipdp11.r" out/IPDP11.R
if ! grep -qE '^Errors= +0$' out/IPDP11.LST; then
    echo "assembly errors, see out/IPDP11.LST" >&2
    exit 1
fi
python3 tools/mkiafile.py out/IPDP11.R out/IPDP11 "PDP-11 UNIBUS INVERSE ASSEMBLER" B
ls -l out
