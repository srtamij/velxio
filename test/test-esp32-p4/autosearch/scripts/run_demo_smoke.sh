#!/usr/bin/env bash
# Phase 2.EE regression check — pure DEMO path (no VELXIO_REAL_SCHED/REAL_INIT).
# The systimer router must still raise the legacy CPU line 17 for the tick so the
# non-real modes stay byte-identical after the Phase 2.EE interrupt-matrix routing.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU=$HOME/qemu-p4-build/qemu-system-riscv32
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
rm -f /tmp/demo_err.txt
timeout -s KILL 10 "$QEMU" -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/dev/null 2>/tmp/demo_err.txt
echo "exit=$? (demo path, 10s, no REAL_SCHED)"
echo "=== crash/abort? ==="
tr -d '\000' </tmp/demo_err.txt | grep -aiE "abort|Guru|panic|segfault|assert" | head -3
echo "=== device events (peripherals + tick path alive) ==="
tr -d '\000' </tmp/demo_err.txt | grep -aoE "\[esp32p4\.[a-z0-9_]+\]" | sort | uniq -c | sort -rn | head -8
echo "=== total stderr lines ==="
tr -d '\000' </tmp/demo_err.txt | grep -c .
