#!/usr/bin/env bash
# Phase 2.EP — capture the SPI1 flash-op command model traces ([spi1] lines) to
# confirm RDID returns 0xEF4016 and READ commands serve real flash_blob data.
# CORELOG throttles TCG hard, so we only need the first seconds of boot.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1 VELXIO_CORELOG=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-25}"
rm -f /tmp/spi1_err.txt /tmp/spi1_out.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/spi1_out.txt 2>/tmp/spi1_err.txt
echo "exit=$? (timeout=${TMO}s, CORELOG on)"
echo "=== [spi1] command traces (op / addr / nbytes / W0) ==="
tr -d "\000" </tmp/spi1_err.txt | grep -aE "\[spi1\]" | head -48
echo "=== distinct opcodes seen ==="
tr -d "\000" </tmp/spi1_err.txt | grep -aoE "op=0x[0-9a-f]+" | sort | uniq -c
echo "=== memspi / no-response on stdout (should be empty) ==="
tr -d "\000" </tmp/spi1_out.txt | grep -aiE "memspi|no response" | head
echo "=== serial marker ==="
tr -d "\000" </tmp/spi1_out.txt | grep -aiE "ESP32-P4 blink" | head -1
