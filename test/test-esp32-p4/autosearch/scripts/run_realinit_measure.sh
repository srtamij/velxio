#!/usr/bin/env bash
# Phase 2.EC — run with VELXIO_REAL_INIT (+ REAL_SCHED): un-skip do_system_init
# so the REAL heap/esp_timer/queue init runs. Measure where the real init
# blocks (expected: esp_psram_init, since CONFIG_SPIRAM=y).
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
TRACE=/tmp/ri.log
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1
# Phase 2.EC: real Espressif ESP32-P4 mask ROM (fixes ets_rom_layout_p @0x4FC1FFFC).
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
rm -f "$TRACE" /tmp/ri_err.txt

timeout -s KILL 15 "$QEMU" -accel tcg,thread=single -smp 2 -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  -d in_asm,int -D "$TRACE" >/tmp/ri_out.txt 2>/tmp/ri_err.txt

echo "############ 0. ROM-load confirmation (REAL-INIT) ############"
grep -E "REAL-INIT|ets_rom_layout_p|ROM section pass|loaded ROM ELF" "$TRACE" /tmp/ri_err.txt 2>/dev/null | head -8
echo

echo "############ 1. init / heap / psram functions reached ############"
for s in do_system_init_fn esp_psram_init esp_psram_chip_init mmu_psram_flash_init \
         init_heap heap_caps_init esp_timer_init esp_timer_early_init init_newlib \
         esp_mmu_map esp_cache_msync spi_flash_init_chip_state s_psram_size; do
  n=$(grep -cE "^IN: .*${s}" "$TRACE" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && echo "  REACHED ${s} (${n})"
done
echo
echo "############ 1a. HP core 1 (dual-core) progress ############"
grep -aE "core 1 instantiated|core 1 RELEASED" /tmp/ri_err.txt 2>/dev/null
n_cs1=$(grep -acE "4ff00b66" "$TRACE" 2>/dev/null)
echo "  core1 reached call_start_cpu1 (0x4ff00b66): ${n_cs1:-0}"
echo "  core1 ROM-reset-path PCs (0x4fc000xx):"
grep -aoE "^0x4fc000[0-9a-f][0-9a-f]:" "$TRACE" 2>/dev/null | sort | uniq -c | sort -rn | head -5
echo

echo "############ 1a2. core 1 IPC servicing (does core 1 take the crosscore IRQ?) ############"
for s in esp_crosscore_isr xPortStartScheduler ipc_task call_start_cpu1 esp_ipc_call_and_wait; do
  n=$(grep -cE "^IN: ${s}\$" "$TRACE" 2>/dev/null)
  echo "  ${s}: ${n:-0}"
done
echo "  FROM_CPU_1 -> core1 RAISE count: $(grep -ac 'FROM_CPU_1=1 -> core1' /tmp/ri_err.txt 2>/dev/null)"
echo

echo "############ 1b. deep boot milestones (scheduler/app/setup/loop) ############"
for s in esp_startup_start_app vTaskStartScheduler main_task app_main initArduino _Z5setupv _Z4loopv loopTask; do
  n=$(grep -cE "^IN: ${s}\$" "$TRACE" 2>/dev/null)
  if [ "${n:-0}" -gt 0 ]; then echo "  REACHED $s ($n)"; else echo "  ----    $s"; fi
done
echo

echo "############ 2. first SYNCHRONOUS CPU exception (async:0 = real trap) ############"
# async:0 = synchronous exception (a real fault, not a timer/IRQ which are async:1)
grep -nE "do_interrupt: .*async:0" "$TRACE" 2>/dev/null | head -4
EXLINE=$(grep -nE "do_interrupt: .*async:0" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${EXLINE:-}" ]; then
  echo "--- last 20 IN: functions BEFORE the fault (line $EXLINE) ---"
  grep -n "^IN: " "$TRACE" | awk -F: -v L="$EXLINE" '$1 < L' | tail -20
  echo "--- raw trace 12 lines before the fault ---"
  START=$((EXLINE - 12)); sed -n "${START},${EXLINE}p" "$TRACE"
fi
echo
echo "############ 2c. last 6 ASYNC interrupts (async:1 = IRQ deliveries) ############"
grep -aE "do_interrupt: .*async:1" "$TRACE" 2>/dev/null | tail -6
echo
echo "############ 3. last 15 IN: functions (where it ended) ############"
grep "^IN: " "$TRACE" | tail -15
echo
echo "############ 3b. raw trace tail (hang/loop body — in_asm) ############"
grep "^0x" "$TRACE" 2>/dev/null | tail -30
echo
echo "############ 3c. hottest repeated PC (poll target) ############"
grep -oE "^0x[0-9a-f]+:" "$TRACE" 2>/dev/null | sort | uniq -c | sort -rn | head -8
echo
echo "############ 3d. abort caller chain (non-format IN: before first abort) ############"
AB=$(grep -n "IN: abort" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${AB:-}" ]; then
  echo "first 'IN: abort' at trace line $AB"
  head -n "$AB" "$TRACE" | grep "^IN: " \
    | grep -avE "utoa|itoa|strcat|abort|printf|memcpy|memset|strlen|strlcpy|vsnprintf|__sf|strchr|strcmp|strncpy|strcpy" \
    | tail -16
fi
echo
echo "############ 4. abort/panic + gate confirmation ############"
grep -iE "REAL-SCHED|REAL-INIT|psram|spiram" /tmp/ri_err.txt 2>/dev/null | head -8
echo "trace lines: $(wc -l < "$TRACE" 2>/dev/null)"
echo
echo "############ 5. USB-Serial/JTAG console output (panic/log message) ############"
grep -aE "usb_serial_jtag] TX #" /tmp/ri_err.txt 2>/dev/null \
  | grep -oE "0x[0-9A-Fa-f][0-9A-Fa-f]" \
  | while read -r h; do printf "\\x${h#0x}"; done
echo
echo "--- (end console) ---"
