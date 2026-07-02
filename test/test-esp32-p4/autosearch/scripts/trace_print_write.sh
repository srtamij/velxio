#!/usr/bin/env bash
# Phase 2.EJ — raw in_asm context AFTER Print::write(const char*): where does the
# virtual dispatch to HardwareSerial::write actually go? Capture the next TBs
# (IN: lines + first insn address) following each Print/HardwareSerial hit.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-70}"
rm -f /tmp/pw_trace.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 -icount shift=2 \
  -d in_asm -D /dev/stdout -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  2>/dev/null | grep -aA40 -E "^IN: _ZN5Print5writeEPKc" > /tmp/pw_trace.txt
echo "exit=$?"
echo "=== 40 raw lines after each Print::write(const char*) TB ==="
head -120 /tmp/pw_trace.txt
echo "ALLDONE"
