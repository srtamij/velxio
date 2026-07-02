#!/usr/bin/env bash
# Resolve any guest address (flash 0x40xxxxxx or IRAM 0x4ffxxxxx) to nearest FUNC.
set -u
ELF=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.elf
readelf -sW "$ELF" 2>/dev/null \
  | awk '$4=="FUNC" {print strtonum("0x" $2), $2, $8}' \
  | sort -n > /tmp/funcs_all.txt
for a in "$@"; do
  target=$(printf '%d' "$a")
  echo "--- $a ---"
  awk -v t="$target" '$1<=t {name=$3; base=$2} END {print "nearest FUNC <= addr:", base, name}' /tmp/funcs_all.txt
done
