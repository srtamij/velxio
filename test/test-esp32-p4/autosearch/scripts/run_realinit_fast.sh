#!/usr/bin/env bash
# Phase 2.EE — low-overhead real dual-core boot to observe the ACTUAL blink
# cadence. VELXIO_CORELOG is OFF (its per-IRQ/per-read fprintf spam throttles TCG
# to ~1% realtime); the GPIO pin-toggle events (esp32p4_gpio.c:154) are NOT gated
# on corelog, so we still see every "pin 2 -> {0,1}" transition. No -icount:
# systimer counter is VIRTUAL_RT-anchored, so delay() cadence follows the guest's
# virtual clock at whatever rate TCG sustains.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-90}"
rm -f /tmp/rf_err.txt /tmp/rf_out.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/rf_out.txt 2>/tmp/rf_err.txt
echo "exit=$? (timeout=${TMO}s, no icount, corelog OFF)"
echo "=== GPIO pin 2 transitions (continuous blink = HIGH>1 AND LOW>1) ==="
tr -d "\000" </tmp/rf_err.txt | grep -aoE "pin 2 -> [01]" | sort | uniq -c
echo "=== full pin-2 transition timeline (order matters) ==="
tr -d "\000" </tmp/rf_err.txt | grep -aoE "pin 2 -> [01]" | head -40
echo "=== abort/panic? ==="
tr -d "\000" </tmp/rf_err.txt | grep -aiE "abort|Guru|panic|Rebooting" | head -3
