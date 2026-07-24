#!/usr/bin/env bash
# Phase 2.EO — after un-skipping esp_ota_get_running_partition the boot hangs
# (core 0 WFI). Trace the app-side partition/OTA/flash-op call sequence to find
# the blocker (the stub returned instantly; the real path does more).
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-20}"
rm -f /tmp/ota_trace.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 -icount shift=2 \
  -d in_asm -D /dev/stdout -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  2>/dev/null | grep -aE "^IN: (esp_ota|esp_partition|ensure_partitions|spi_flash|Update|_ZN14UpdateClass|esp_image|bootloader_|image_validate|esp_flash_read|s_flash_op|spi_flash_op|cache2phys|esp_mmu|xSemaphore|_Z10initvariantv|_Z11initArduinov|_Z5setupv|read_otadata)" | awk '!seen[$0]++' > /tmp/ota_trace.txt
echo "exit=$?"
echo "=== unique app fns on the partition/OTA/flash path (first-execution order) ==="
head -70 /tmp/ota_trace.txt
echo "=== total ==="; wc -l < /tmp/ota_trace.txt
echo "ALLDONE"
