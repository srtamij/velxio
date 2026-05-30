#!/usr/bin/env bash
# Phase 2.DS — re-measure Track A (the REAL Arduino flow) with the new
# VELXIO_REAL_FLOW gate that drops the Track-B demo-only patches.
#
# Boots the symbolized app ELF (so the -d in_asm trace shows function
# names) with the flash backing drive, runs ~12s, and reports how far the
# real flow gets: app_main -> initArduino -> setup() -> loop().
#
# QEMU is wrapped in `timeout -s KILL` so it self-terminates (the IDF panic
# handler reboots in a loop, so QEMU never exits on its own). All analysis
# runs in THIS process because WSL /tmp is wiped between wsl.exe calls.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
FW="$BASE/blink.ino.merged.bin"
ELF="$BASE/blink.ino.elf"
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
GPIOLOG=/tmp/ds_gpio.jsonl
TRACE=/tmp/ds_trace.log
SOCK=/tmp/ds_mon.sock
SAMPLES=/tmp/ds_pc.txt
OUT=/tmp/ds_stdout.txt
ERR=/tmp/ds_stderr.txt

rm -f "$GPIOLOG" "$TRACE" "$OUT" "$ERR" "$SAMPLES" "$SOCK"

export VELXIO_REAL_FLOW=1
export VELXIO_GPIO_LOG="$GPIOLOG"

timeout -s KILL 12 "$QEMU" -M esp32p4 -kernel "$ELF" \
  -drive file="$FW",if=mtd,format=raw -nographic \
  -d in_asm,int -D "$TRACE" \
  -monitor unix:"$SOCK",server,nowait \
  >"$OUT" 2>"$ERR" &
QPID=$!

have_socat=0; command -v socat >/dev/null 2>&1 && have_socat=1
for i in 1 2 3 4 5 6; do
  sleep 1
  if [ "$have_socat" = 1 ] && [ -S "$SOCK" ]; then
    echo "===== t=${i}s =====" >> "$SAMPLES"
    echo "info registers" | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null \
      | grep -ioE "(^| )pc[ =:]*0x[0-9a-fA-F]+" >> "$SAMPLES" 2>/dev/null
  fi
done
wait "$QPID" 2>/dev/null

echo "############ 1. REAL-FLOW gate confirmation ############"
grep -iE "REAL-FLOW|demo patches skipped" "$ERR" | head
echo
echo "############ 2. machine-init self-tests (regression check) ############"
echo "OK-count: $(grep -icE 'self-test.*OK|=OK' "$ERR")"
echo
echo "############ 3. GPIO pin2 (LED) toggles = loop() ran ############"
echo "stderr pin2 ->: $(grep -cE 'pin 2 ->' "$ERR")    gpio-log pin2: $(grep -cE '\"pin\"[: ]*2[,}]' "$GPIOLOG" 2>/dev/null)"
echo
echo "############ 4. function milestones REACHED (IN: symbols) ############"
echo "distinct functions translated: $(grep -c '^IN: ' "$TRACE" 2>/dev/null)"
for sym in main_task app_main initArduino setCpuFrequency _Z5setupv _Z4loopv loopTask digitalWrite pinMode delay vTaskDelay Serial _ZN14HardwareSerial uartBegin uart_driver; do
  n=$(grep -cE "^IN: .*${sym}" "$TRACE" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && echo "  REACHED  ${sym}  (${n})"
done
echo "--- NOT reached ---"
for sym in _Z4loopv digitalWrite delay; do
  n=$(grep -cE "^IN: .*${sym}" "$TRACE" 2>/dev/null)
  [ "${n:-0}" -eq 0 ] && echo "  missing  ${sym}"
done
echo
echo "############ 5. CRASH PATH — 70 IN: functions before first esp_restart_noos ############"
N=$(grep -n "^IN: esp_restart_noos" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${N:-}" ]; then
  echo "(first esp_restart_noos at trace line $N)"
  head -n "$N" "$TRACE" | grep "^IN: " | tail -70
else
  echo "(no esp_restart_noos — did NOT reboot; last 40 IN: below)"
  grep "^IN: " "$TRACE" | tail -40
fi
echo
echo "############ 6. panic / wdt / exception / error-check handler symbols in trace ############"
grep -oE "^IN: (esp_panic[a-z_]*|panic[a-z_]*|_esp_error_check_failed[a-z_]*|abort|esp_task_wdt[a-z_]*|esp_int_wdt[a-z_]*|[a-z_]*wdt[a-z_]*isr|xt_[a-z_]*|[a-z_]*exception[a-z_]*|vApplication[A-Za-z]*|esp_system_abort|esp_cpu_reset|esp_restart[a-z_]*)" "$TRACE" 2>/dev/null | sort | uniq -c | sort -rn | head -25
echo
echo "############ 7. UART stdout (IDF panic handler uses esp_rom_printf -> ROM UART, bypasses C++ Print) ############"
echo "--- stdout bytes: $(wc -c < "$OUT" 2>/dev/null) ---"
head -40 "$OUT" 2>/dev/null
echo
echo "############ 8. live PC samples ############"
cat "$SAMPLES" 2>/dev/null; echo "socat=$have_socat"
echo
echo "############ 9b. FIRST CPU exception (-d int: cause/epc/tval = root cause) ############"
grep -nE "do_interrupt|cause:|tval:|desc=|exception" "$TRACE" 2>/dev/null | head -12
EXLINE=$(grep -nE "do_interrupt|desc=" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${EXLINE:-}" ]; then
  echo "--- enclosing IN: function at the first exception (line $EXLINE) ---"
  head -n "$EXLINE" "$TRACE" | grep "^IN: " | tail -3
fi
echo
echo "############ 9. trace size ############"
wc -l "$TRACE" 2>/dev/null
