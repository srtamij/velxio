#!/usr/bin/env bash
# Phase 2.EH decisive validation — Serial-free blink on the real dual-core emulator.
# If pin 2 toggles repeatedly (HIGH>1 AND LOW>1) it proves tick(2.EE)/CLIC(2.EF-EG)/
# scheduler/delay/GPIO all work and isolates the remaining blocker to the Serial driver.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink_noserial/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-90}"
rm -f /tmp/ns_err.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 \
  -M esp32p4 -kernel "$BASE/blink_noserial.ino.elf" \
  -drive file="$BASE/blink_noserial.ino.merged.bin",if=mtd,format=raw -nographic \
  >/dev/null 2>/tmp/ns_err.txt
echo "exit=$? (no-Serial blink, ${TMO}s, real dual-core)"
echo "=== GPIO pin 2 transitions (continuous blink = HIGH>1 AND LOW>1) ==="
tr -d '\000' </tmp/ns_err.txt | grep -aoE "pin 2 -> [01]" | sort | uniq -c
echo "=== transition timeline (first 30) ==="
tr -d '\000' </tmp/ns_err.txt | grep -aoE "pin 2 -> [01]" | head -30 | tr '\n' ' '; echo
echo "=== panic? ==="
tr -d '\000' </tmp/ns_err.txt | grep -aiE "Guru|panic|abort" | head -2 || echo none
