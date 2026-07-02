#!/usr/bin/env bash
# Diagnose WHERE the Serial-free blink stalls (corelog + icount deterministic).
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink_noserial/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1 VELXIO_CORELOG=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
rm -f /tmp/nsd_err.txt /tmp/nsd_out.txt
timeout -s KILL 22 "$QEMU" -accel tcg,thread=single -smp 2 -icount shift=2 \
  -M esp32p4 -kernel "$BASE/blink_noserial.ino.elf" \
  -drive file="$BASE/blink_noserial.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/nsd_out.txt 2>/tmp/nsd_err.txt
echo "exit=$?"
echo "=== GPIO pin 2 ==="; tr -d '\000' </tmp/nsd_err.txt | grep -aoE "pin 2 -> [01]" | sort | uniq -c
echo "=== core0 PC top ==="; tr -d '\000' </tmp/nsd_err.txt | grep -aoE "c0 pc=0x[0-9a-f]+" | sort | uniq -c | sort -rn | head -4
echo "=== [vTPOEL] NULL pxEventList probe (does it stall at the SAME NULL handle)? ==="
tr -d '\000' </tmp/nsd_err.txt | grep -a "\[vTPOEL\]" | tail -2
echo "=== schedrun / tick cause=18 ==="
tr -d '\000' </tmp/nsd_err.txt | grep -aoE "schedrun=[0-9],[0-9]" | sort | uniq -c | tail -2
tr -d '\000' </tmp/nsd_err.txt | grep -ac "hart=0 IRQ cause=18"
echo "=== panic/abort ==="; tr -d '\000' </tmp/nsd_out.txt | grep -aiE "Guru|panic|abort|Rebooting" | head -2 || echo none
