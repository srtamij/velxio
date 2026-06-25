#!/usr/bin/env bash
# REAL_INIT boot WITHOUT -d tracing (fast) — decide whether the initArduino
# spin is a real hang (dual-core IPC to absent core 1) or just trace slowness.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
rm -f /tmp/u2_err.txt
timeout -s KILL 25 "$QEMU" -accel tcg,thread=single -smp 2 -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/u2_out.txt 2>/tmp/u2_err.txt
echo "=== GPIO pin 2 (LED) transitions (loop reached if >0) ==="
grep -ac "pin 2" /tmp/u2_err.txt
echo "=== device-event summary (stderr) ==="
grep -aoE "\[esp32p4\.[a-z_0-9]+\]" /tmp/u2_err.txt 2>/dev/null | sort | uniq -c | sort -rn | head -12
echo "=== REAL-INIT confirmation ==="
grep -aE "REAL-INIT|ets_rom_layout_p" /tmp/u2_err.txt 2>/dev/null | head -3
