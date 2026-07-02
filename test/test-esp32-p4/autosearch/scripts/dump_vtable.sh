#!/usr/bin/env bash
# Phase 2.EJ — dump Serial0's vtable (vptr = 0x40039c10) from the ELF and
# resolve each entry to a symbol, to see where the virtual write() dispatches.
set -u
ELF=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.elf
VPTR=0x40039c10
# Find the loadable section containing VPTR.
readelf -SW "$ELF" | awk -v t=$((VPTR)) '
  /\[[ 0-9]+\]/ {
    gsub(/\[|\]/," ");
    name=$2; addr=strtonum("0x"$4); off=strtonum("0x"$5); size=strtonum("0x"$6);
    if (t>=addr && t<addr+size) printf "%s fileoff=0x%x secaddr=0x%x\n", name, off+(t-addr), addr;
  }'
FOFF=$(readelf -SW "$ELF" | awk -v t=$((VPTR)) '
  /\[[ 0-9]+\]/ {
    gsub(/\[|\]/," ");
    addr=strtonum("0x"$4); off=strtonum("0x"$5); size=strtonum("0x"$6);
    if (t>=addr && t<addr+size) { printf "%d", off+(t-addr); exit }
  }')
echo "file offset: $FOFF"
echo "=== 14 vtable entries (little-endian words) ==="
xxd -s "$FOFF" -l 56 -e -g 4 "$ELF" | awk '{print $2, $3, $4, $5}'
echo "=== resolve each entry ==="
ENTRIES=$(xxd -s "$FOFF" -l 56 -e -g 4 "$ELF" | awk '{print $2, $3, $4, $5}' | tr ' ' '\n' | grep -E "^[0-9a-f]{8}$")
readelf -sW "$ELF" | awk '$4=="FUNC" {print strtonum("0x"$2), $2, $8}' | sort -n > /tmp/funcs_all2.txt
i=0
for e in $ENTRIES; do
  t=$(printf '%d' "0x$e")
  nm=$(awk -v t="$t" '$1<=t {n=$3; b=$2} $1>t {exit} END{print b, n}' /tmp/funcs_all2.txt)
  echo "vtbl[$i] = 0x$e -> $nm"
  i=$((i+1))
done
echo "ALLDONE"
