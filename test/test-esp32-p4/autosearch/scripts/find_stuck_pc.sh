#!/usr/bin/env bash
# Phase 2.EP — with the partition-stub un-skipped the boot stalls before setup().
# Capture the tail of an in_asm trace to find the PC(s) the cores spin on, then
# resolve them to functions. Short run; we only need the steady-state spin.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
ELF="$BASE/blink.ino.elf"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-8}"
rm -f /tmp/stuck.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 \
  -d in_asm -D /dev/stdout -M esp32p4 -kernel "$ELF" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  2>/dev/null | grep -aoE "^IN: [^ ]+" | tail -8000 > /tmp/stuck.txt
echo "exit=$?"
echo "=== most-executed functions in the last 4000 blocks (the spin) ==="
sort /tmp/stuck.txt | uniq -c | sort -rn | head -20
