#!/usr/bin/env bash
# Phase 2.DT — FreeRTOS resurrection experiment: run with VELXIO_REAL_SCHED so
# the GENUINE vTaskStartScheduler + loopTask path runs (2.M scheduler bypass
# dropped), and measure how far the real scheduler gets.
#
# Symbolized -kernel ELF + -d in_asm,int; ~12s under timeout -s KILL (the IDF
# panic handler reboots in a loop). LED = GPIO2.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
FW="$BASE/blink.ino.merged.bin"
ELF="$BASE/blink.ino.elf"
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
GPIOLOG=/tmp/dt_gpio.jsonl
TRACE=/tmp/dt_trace.log
OUT=/tmp/dt_stdout.txt
ERR=/tmp/dt_stderr.txt

rm -f "$GPIOLOG" "$TRACE" "$OUT" "$ERR"
export VELXIO_REAL_SCHED=1
export VELXIO_GPIO_LOG="$GPIOLOG"

timeout -s KILL 12 "$QEMU" -M esp32p4 -kernel "$ELF" \
  -drive file="$FW",if=mtd,format=raw -nographic \
  -d in_asm,int -D "$TRACE" \
  >"$OUT" 2>"$ERR" &
QPID=$!
wait "$QPID" 2>/dev/null

echo "############ 1. REAL-SCHED gate confirmation ############"
grep -iE "REAL-SCHED|patches skipped" "$ERR" | head
echo
echo "############ 2. self-tests (regression) ############"
echo "OK-count: $(grep -icE 'self-test.*OK|=OK' "$ERR")"
echo
echo "############ 3. scheduler milestones REACHED (IN: symbols) ############"
echo "distinct functions translated: $(grep -c '^IN: ' "$TRACE" 2>/dev/null)"
for sym in esp_startup_start_app vTaskStartScheduler xPortStartScheduler vPortSetupTimer vPortYield xPortStartFirstTask _frxt_dispatch prvIdleTask xTaskCreatePinnedToCore xTaskCreateUniversal main_task _Z5setupv _Z4loopv loopTask pinMode digitalWrite vTaskDelay vPortSetupTimer esp_intr_alloc; do
  n=$(grep -cE "^IN: .*${sym}" "$TRACE" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && echo "  REACHED  ${sym}  (${n})"
done
echo "--- key NOT reached ---"
for sym in vTaskStartScheduler xPortStartScheduler vPortYield _Z5setupv _Z4loopv loopTask digitalWrite; do
  n=$(grep -cE "^IN: .*${sym}" "$TRACE" 2>/dev/null)
  [ "${n:-0}" -eq 0 ] && echo "  missing  ${sym}"
done
echo
echo "############ 4. GPIO2 (LED) toggles = loop() ran ############"
echo "stderr pin2: $(grep -cE 'pin 2 ->' "$ERR")   gpio-log pin2: $(grep -cE '\"pin\"[: ]*2[,}]' "$GPIOLOG" 2>/dev/null)"
echo "ALL pin transitions:"; grep -iE "esp32p4.gpio\] pin" "$ERR" | head -15
echo
echo "############ 5. CPU exceptions (-d int: cause/epc/tval) ############"
grep -nE "do_interrupt|cause:|desc=" "$TRACE" 2>/dev/null | head -8
EXLINE=$(grep -nE "do_interrupt|desc=" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${EXLINE:-}" ]; then
  echo "--- enclosing IN: at first exception (line $EXLINE) ---"
  head -n "$EXLINE" "$TRACE" | grep "^IN: " | tail -4
fi
echo
echo "############ 5b. context before first fetch-fault / illegal-instr / abort ############"
FF=$(grep -nE "fault_fetch|illegal_instruction" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${FF:-}" ]; then
  echo "(first fault_fetch at trace line $FF)"
  echo "--- IN: functions before fault ---"
  head -n "$FF" "$TRACE" | grep "^IN: " | tail -12
  echo "--- raw asm of last TB before fault (the restore) ---"
  head -n "$FF" "$TRACE" | tail -40
else
  echo "(no fetch fault)"
fi
echo
echo "############ 6. crash/panic path (last 25 IN: before first esp_restart_noos, else last 25) ############"
N=$(grep -n "^IN: esp_restart_noos" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "${N:-}" ]; then echo "(reboot at line $N)"; head -n "$N" "$TRACE" | grep "^IN: " | tail -25; else echo "(no reboot — last 25 IN:)"; grep "^IN: " "$TRACE" | tail -25; fi
echo
echo "############ 7. panic/wdt/sched handler symbols ############"
grep -oE "^IN: (esp_panic[a-z_]*|panic[a-z_]*|abort|xt_[a-z_]*|[a-z_]*exception[a-z_]*|vApplication[A-Za-z]*|prvCheckTasksWaiting[A-Za-z]*|vTaskSwitchContext|esp_restart[a-z_]*)" "$TRACE" 2>/dev/null | sort | uniq -c | sort -rn | head -20
echo
echo "############ 8. trace size ############"
wc -l "$TRACE" 2>/dev/null
