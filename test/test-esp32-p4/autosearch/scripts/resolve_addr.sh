#!/usr/bin/env bash
# Resolve one or more guest addresses to the nearest preceding FUNC symbol in
# the blink ELF. Usage: resolve_addr.sh 0x4ff082ca 0x4ff082d6 ...
set -u
ELF=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.elf
readelf -sW "$ELF" 2>/dev/null \
  | awk '$4=="FUNC" && $2 ~ /^4ff0/ {print strtonum("0x" $2), $2, $8}' \
  | sort -n > /tmp/funcs.txt
for a in "$@"; do
  target=$(printf '%d' "$a")
  echo "--- $a ---"
  awk -v t="$target" '$1<=t {name=$3; base=$2} END {print "nearest FUNC <= addr:", base, name}' /tmp/funcs.txt
done
