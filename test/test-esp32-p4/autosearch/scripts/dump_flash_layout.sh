#!/usr/bin/env bash
# Phase 2.EN grounding — where are the ESP image magic (0xE9) and partition table
# in the blink merged.bin? Flash offsets map to the guest flash-cache window.
set -u
BIN=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.merged.bin
python3 - "$BIN" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print("file size:", hex(len(d)))
for off in (0x0, 0x1000, 0x2000, 0x8000, 0x9000, 0xf000, 0x10000, 0x20000, 0x30000):
    if off < len(d):
        print(f"  off {off:#08x}: {d[off:off+8].hex()}  first={d[off]:#04x}")
# All 0xE9 image-magic locations in the first 512 KB (esp_image_header_t.magic)
print("0xE9 magic candidates (byte==E9 AND next-byte==segment_count 1..16):")
n = 0
for off in range(0, min(len(d), 0x80000), 0x1000):
    if d[off] == 0xE9 and 1 <= d[off+1] <= 16:
        print(f"  {off:#08x}: {d[off:off+4].hex()}")
        n += 1
        if n >= 8: break
# Partition table entries start with 0xAA 0x50 (ESP_PARTITION_MAGIC = 0x50AA LE)
print("partition-table magic 0xAA50 scan around 0x8000:")
for off in range(0x8000, min(len(d), 0x9000), 0x20):
    if d[off:off+2] == b"\xaa\x50":
        typ = d[off+2]; sub = d[off+3]
        import struct
        addr, size = struct.unpack("<II", d[off+4:off+12])
        label = d[off+12:off+28].split(b"\x00")[0].decode("latin1")
        print(f"  entry@{off:#06x}: type={typ} sub={sub:#04x} addr={addr:#08x} size={size:#08x} label={label!r}")
PY
