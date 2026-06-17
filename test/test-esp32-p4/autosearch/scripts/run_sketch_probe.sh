#!/usr/bin/env bash
# Probe how far an arbitrary compiled sketch boots on the current emulator,
# and which peripheral device events fire. Usage: run_sketch_probe.sh [sketch]
set -u
SK=${1:-periph_test}
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/$SK/build/esp32.esp32.esp32p4
QEMU=$HOME/qemu-p4-build/qemu-system-riscv32
ELF=$BASE/$SK.ino.elf
BIN=$BASE/$SK.ino.merged.bin
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf

run_mode() {
  mode="$1"; shift
  log=/tmp/probe_$mode.log; err=/tmp/probe_${mode}_err.txt
  rm -f "$log" "$err"
  env "$@" timeout -s KILL 14 "$QEMU" -M esp32p4 -kernel "$ELF" \
    -drive file="$BIN",if=mtd,format=raw -nographic \
    -d in_asm,int -D "$log" >/dev/null 2>"$err"
  echo "############ MODE=$mode  (trace lines: $(wc -l < "$log" 2>/dev/null)) ############"
  echo "-- app/sketch milestones reached --"
  for s in app_main initArduino loopTask _Z5setupv _Z4loopv; do
    n=$(grep -cE "^IN: ${s}\$" "$log" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then echo "  REACHED $s"; else echo "  ----    $s"; fi
  done
  echo "-- peripheral device events (count by device, from stderr) --"
  grep -aoE "\[esp32p4\.(gpio|i2c|spi[0-9]?|ledc|uart[0-9]?|usb_serial_jtag|rmt|adc)\]" "$err" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -15
  echo "-- sample device lines --"
  grep -aE "\[esp32p4\.(gpio|i2c|spi|ledc|usb_serial_jtag)\]" "$err" 2>/dev/null | head -6
  echo "-- last IN: functions --"
  grep "^IN: " "$log" 2>/dev/null | tail -4
  echo "-- first synchronous fault (if any) --"
  grep -aE "async:0" "$log" 2>/dev/null | head -1
  echo
}

run_mode realsched VELXIO_REAL_SCHED=1
run_mode realinit  VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
