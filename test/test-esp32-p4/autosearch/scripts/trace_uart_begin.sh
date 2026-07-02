#!/usr/bin/env bash
# Phase 2.EJ — stream the -d in_asm trace through grep keeping ONLY uart/clk
# related "IN: func" lines, to see how far Serial.begin()'s call chain gets
# (uartBegin -> uart_driver_install -> uart_param_config -> uart_set_pin) and
# where it diverges into an error/cleanup path. in_asm logs each TB's first
# translation with the symbol name, so the first pass of the sequence shows.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
unset VELXIO_CORELOG
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-25}"
rm -f /tmp/uart_trace.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 -icount shift=2 \
  -d in_asm -D /dev/stdout -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  2>/dev/null | grep -aE "^IN: (uart|_Z9uartBegin|.*HardwareSerial|.*Print|esp_clk_tree|periph_module|clk_tree|uart_ll|esp_intr_alloc|intr_matrix|serial|gpio_set_level|_Z4loopv|_Z5setupv)" > /tmp/uart_trace.txt
echo "exit=$?"
echo "=== uart/clk call sequence (unique, in order of first execution) ==="
awk '!seen[$0]++' /tmp/uart_trace.txt | head -60
echo "=== total lines ==="
wc -l < /tmp/uart_trace.txt
echo "ALLDONE"
