#!/usr/bin/env bash
# Phase 2.EP diag — is the partition-stub un-skip causing a REBOOT LOOP (early-init
# functions re-run) or reaching the flash-read path? Count executions across a full
# in_asm trace. >1 for pmu_init/call_start_cpu0 = reset loop.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-12}"
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 -d in_asm -D /dev/stdout \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic 2>/dev/null \
  | grep -aE '^IN: ' > /tmp/all_in.txt
echo "total IN blocks: $(wc -l </tmp/all_in.txt)"
echo "=== execution counts (reboot markers vs flash-read path) ==="
for f in pmu_init call_start_cpu0 esp_perip_clk_init start_cpu0_default \
         spi_flash_hal_read spi_flash_hal_common_command esp_flash_read \
         spi_flash_op_block_func spi_flash_disable_interrupts_caches_and_other_cpu \
         read_otadata esp_ota_get_running_partition esp_partition_read \
         spi_flash_chip_generic_read initArduino _Z5setupv; do
  c=$(grep -acE "^IN: ${f}([ +]|$)" /tmp/all_in.txt)
  printf '  %6s  %s\n' "$c" "$f"
done
echo "=== last 8 distinct functions executed (where it ends up) ==="
grep -aE '^IN: ' /tmp/all_in.txt | tail -60 | awk '{print $2}' | awk '!seen[$0]++' | tail -8
