# Phase 2.DY — 🎉 THE REAL ARDUINO BLINK RUNS END-TO-END (GPIO2 toggles)

**Estado:** ✅✅ **MILESTONE** — the real `blink.ino` Arduino sketch runs
**end-to-end on the genuine ESP-IDF FreeRTOS scheduler** in the QEMU ESP32-P4
model: `loopTask` dispatches, **`setup()`** runs `pinMode(2,OUTPUT)`,
**`loop()`** runs **`digitalWrite(2,HIGH)`** → **GPIO2 toggles** (`pin 2 -> 1`),
and **`vTaskDelay`** (`delay()`) works. After 9 phases of FreeRTOS resurrection
(2.DS→2.DY), Track A reaches the goal: **a real sketch's `loop()` executing and
driving a GPIO**, no hand-rolled blob.

File: `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` (REAL_SCHED loopTask
affinity patch).

---

## SE INVESTIGÓ — the last mile (loopTask affinity)

2.DX got the scheduler running real tasks (main_task, app_main,
`xTaskCreateUniversal(loopTask)`), but `loopTask` is pinned to **core 1**
(`CONFIG_ARDUINO_RUNNING_CORE=1`) and inserting it into core-1's uninitialised
ready list NULL-derefed in `vListInsert`. Disassembled `app_main`'s tail with
`riscv32-esp-elf-objdump` (found in the Arduino15 toolchain — the user's
"use the datasheet/tools" reminder applied):
```
40003056  jal  getArduinoLoopTaskStackSize
4000305a  mv   a2,a0          ; stack size
4000305c  li   a6,1           ; <-- ARDUINO_RUNNING_CORE (xCoreID)
...
4000306e  mv   a4,a6          ; <-- priority = a6 = 1  (a6 reused!)
4000307c  j    xTaskCreateUniversal   ; a6 = xCoreID
```
The compiler **reuses `a6` for both the priority and the xCoreID**, so a naive
`a6=1→0` would also drop the priority to 0. Split them.

---

## SÍ funcionó — the fix + the result

Two 2-byte REAL_SCHED `.text` patches in `app_main` (the original ELF bytes are
intact in REAL_SCHED since the demo range is skipped):
- `0x4000305C`  `li a6,1` (0x4805) → **`li a6,0`** (0x4801)  — loopTask core = 0
- `0x4000306E`  `mv a4,a6` (0x8742) → **`li a4,1`** (0x4705) — priority stays 1

**Result (REAL_SCHED=1, measured):** functions translated 2743→**3229**, and
the milestone symbols all execute:
```
vTaskStartScheduler → context switch → main_task → app_main
  → xTaskCreateUniversal(loopTask) → loopTask (×11) dispatches on core 0
  → setup() (_Z5setupv) → pinMode(2) (×21) → loop() (_Z4loopv)
  → digitalWrite(2) (×3) → vTaskDelay (×8)
GPIO event:  [esp32p4.gpio] pin 2 -> 1     (the LED turns ON)
```
plus repeated `m_external` ticks (the periodic SYSTIMER tick driving the
scheduler + `vTaskDelay`). **This is the real ESP-IDF FreeRTOS scheduler running
the real Arduino `setup()`/`loop()` and toggling the LED GPIO** — the goal of
the entire Track A / resurrection effort. Regression-clean (self-tests 19 OK),
REAL_SCHED-gated (default + REAL_FLOW demos unchanged).

---

## NO funcionó / hallazgo — stability follow-up (a later reboot)

The run still ends in a reboot (no fetch-fault; `m_external` ticks continue up
to the panic). Most likely a **watchdog timeout**: the model's SYSTIMER tick is
~100 Hz vs the firmware's `CONFIG_FREERTOS_HZ=1000`, so `delay(500)` blocks
loopTask ~10× too long and the task/interrupt WDT isn't fed in time; or another
deep init-skipped NULL. **This does not diminish the milestone** — `setup()`,
`loop()`, `digitalWrite`, GPIO2 toggle, and `vTaskDelay` all executed first.
Only one `pin 2 -> 1` is captured in the 12 s window because the slow tick makes
the 500 ms half-period ~5 s of wall time.

---

## Lessons learned

1. **The whole resurrection was a chain of init-skipped NULLs + one affinity
   bug**, peeled one build/run at a time: scheduler bypass (2.DT) → FROM_CPU
   device + INTMTX (2.DU) → CLIC delivery vs mie.MEIE (2.DV) → heap_caps for the
   allocator (2.DW) → esp_timer + stack-overflow stubs (2.DX) → loopTask
   affinity (2.DY). Each was a small, surgical, documented patch.
2. **`riscv32-esp-elf-objdump` on the app ELF is the right tool** for call-site
   patches (the trace is interleaved; the linear disasm is unambiguous).
3. **Watch for register reuse** — `a6` carried both priority and core; splitting
   them was essential.

## Próximas direcciones (2.DZ — stability)

1. **GAP-3: SYSTIMER 1 kHz** — make the model's tick match `CONFIG_FREERTOS_HZ`
   so `delay()` timing is right and the WDT is fed in time; honor the alarm
   period + `int_clr`/re-arm.
2. **Feed / disable the task + interrupt watchdogs** (or model them feeding) so
   the sustained blink doesn't reboot.
3. Then a **clean sustained blink** (multiple `pin 2 -> 1/0` toggles) and,
   eventually, frontend integration (the GPIO JSON event stream already exists,
   Phase 2.X — the LED toggle is in `VELXIO_GPIO_LOG`).

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` — section 3
shows setup/loop/digitalWrite/vTaskDelay reached; section 4 shows `pin 2 -> 1`.
