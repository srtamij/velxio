#!/usr/bin/env bash
# Phase 2.EJ — where do Serial.println's TX bytes go? Run the blink and inspect
# stdout (console chardev) + stderr (device events) + UART register traffic.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1 VELXIO_CORELOG=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
rm -f /tmp/sd_out.txt /tmp/sd_err.txt
timeout -s KILL 15 "$QEMU" -accel tcg,thread=single -smp 2 \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/sd_out.txt 2>/tmp/sd_err.txt
echo "exit=$?"
echo "=== GPIO check (blink alive?) ==="
tr -d '\000' </tmp/sd_err.txt | grep -aoE "pin 2 -> [01]" | sort | uniq -c
echo "=== stdout printable strings (ALL, incl boot banner) ==="
strings -n 3 /tmp/sd_out.txt | head -30
echo "=== stdout size / HIGH-LOW count ==="
wc -c /tmp/sd_out.txt
strings /tmp/sd_out.txt | grep -cE "HIGH|LOW"
echo "=== uart events in stderr ==="
tr -d '\000' </tmp/sd_err.txt | grep -aiE "uart" | head -10
echo "=== ALLDONE ==="
