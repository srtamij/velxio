#!/usr/bin/env bash
# Phase 2.ED lead #3 — does deterministic instruction-counted timing (-icount)
# change the dual-core yield storm? If the boot reaches loop()/GPIO2 with -icount
# but not without, the dual-core hang is a pure TCG round-robin timing race.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1 VELXIO_CORELOG=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
SHIFT="${1:-2}"
rm -f /tmp/ic_err.txt /tmp/ic_out.txt
timeout -s KILL 18 "$QEMU" -accel tcg,thread=single -smp 2 -icount "shift=${SHIFT}" \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/ic_out.txt 2>/tmp/ic_err.txt
echo "exit=$? (icount shift=${SHIFT})"
echo "=== QEMU errors (if any) ==="
grep -aiE "error|unsupported|cannot|invalid" /tmp/ic_err.txt | grep -aivE "esp32p4\.|corelog" | head -3
echo "=== core0 IRQ causes ==="
grep -aE "hart=0 IRQ" /tmp/ic_err.txt | grep -aoE "cause=[0-9]+" | sort | uniq -c
echo "=== core1 IRQ causes ==="
grep -aE "hart=1 IRQ" /tmp/ic_err.txt | grep -aoE "cause=[0-9]+" | sort | uniq -c
echo "=== GPIO pin 2 toggles (loop reached if >0) ==="
grep -ac "pin 2" /tmp/ic_err.txt
echo "=== abort / reboot? ==="
grep -aiE "abort|Rebooting" /tmp/ic_out.txt | head -2
