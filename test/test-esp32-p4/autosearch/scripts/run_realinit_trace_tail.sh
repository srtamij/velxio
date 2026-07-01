#!/usr/bin/env bash
# Phase 2.ED — capture the TAIL of the dual-core boot's -d in_asm trace without
# filling the disk: pipe the (gigabytes) trace through `tail -c` which streams and
# keeps only the last N MB in memory. Reveals exactly what core 0 executes at the
# steady-state stall (spin loop vs frozen).
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-20}"
KEEP="${2:-8}"   # MB of trailing trace to keep
rm -f /tmp/tt.log
# -D /dev/stdout sends the in_asm trace to stdout; corelog/errors go to stderr(dropped).
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 \
  -d in_asm -D /dev/stdout -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  2>/dev/null | tail -c "${KEEP}000000" > /tmp/tt.log
echo "kept $(wc -c < /tmp/tt.log) bytes"
echo "=== unique PCs in the trailing trace (the stall's hot loop) ==="
grep -aoE "^0x4ff[0-9a-f]+:" /tmp/tt.log | sort | uniq -c | sort -rn | head -20
echo "=== last 40 executed instruction addresses (raw) ==="
grep -aoE "^0x[0-9a-f]+:" /tmp/tt.log | tail -40 | sort -u | head -40
