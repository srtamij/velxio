# Phase 2.DX — the real FreeRTOS scheduler RUNS (main_task, app_main, loopTask created)

**Estado:** ✅ DONE w/ findings — two small `.text` patches got the real
scheduler **fully running**: `vTaskSwitchContext` executes **31×**, **`main_task`
runs**, **`app_main` → `initArduino` → `xTaskCreateUniversal(loopTask)`** all
execute, and the SYSTIMER/crosscore interrupts (`m_external`) fire repeatedly —
the scheduler is **live**. New blocker: a `vListInsert` NULL deref (dual-core
ready-list management / loopTask core-1 affinity).

Files: `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` (REAL_SCHED `.text` patches).

---

## SE INVESTIGÓ — two crashes, peeled in order

2.DW left the context switch running but faulting. The `-d in_asm` asm trace
(harness section 5b) pinned each:

1. **`esp_timer_get_time` PC=0.** `vTaskSwitchContext → esp_timer_get_time`
   (`0x4FF01DF2`, == `esp_timer_impl_get_time`) **tail-calls a systimer get-time
   fn pointer** (data `@0x4FF13B40`) that is **NULL** because
   `esp_timer_impl_init` was skipped → `jr` to 0 → fetch fault. Patching the
   data pointer would be wiped by `.bss` init, so the **function** (IRAM/.text)
   is patched to return 0: `c.li a0,0; c.li a1,0; c.ret`.
2. **Stack-overflow false abort.** The first switch trips FreeRTOS'
   `taskCHECK_FOR_STACK_OVERFLOW` on a task that hasn't run yet
   (`vApplicationStackOverflowHook → esp_system_abort → panic_abort` — the
   "illegal instruction" was the panic trap, not a decode failure). Bump-
   allocated stack canary / initial-context false positive. Patched
   `vApplicationStackOverflowHook` (`0x4FF06DBE`) → `c.ret`.

Addresses from `blink.ino.map`.

---

## SÍ funcionó — the scheduler is alive

After both patches, REAL_SCHED reaches (IN: symbols, functions 2233→**2743**):
```
vTaskStartScheduler → xPortStartScheduler → vPortYield → [crosscore trap]
  → esp_crosscore_isr → rtos_int_exit → vTaskSwitchContext (×31)
  → main_task (×10) → app_main → initArduino → xTaskCreateUniversal(loopTask) (×2)
```
plus **repeated `m_external` interrupts** (the periodic tick + yields are being
delivered and serviced). **This is the real ESP-IDF FreeRTOS scheduler running
the real Arduino startup** — main_task executes under the scheduler, runs
app_main, and creates the Arduino loopTask. Regression-clean (19 OK), REAL_SCHED-
gated.

This is the milestone the whole resurrection was for: **the scheduler dispatches
real tasks.**

---

## NO funcionó / hallazgo — the dual-core list blocker

After `loopTask` is created, a **`vListInsert` (`0x4FF07370`) NULL deref**:
`cause:5 (load fault), epc:0x4FF07396, tval:0xC` (NULL+12) → panic → reboot.
`vListInsert` adds a task to a list. The most likely cause is the **dual-core**
config (`CONFIG_FREERTOS_NUMBER_OF_CORES=2`, `ARDUINO_RUNNING_CORE=1`):
`loopTask` is pinned to **core 1**, so creating it inserts into **core 1's
ready list**, whose per-core state isn't validly initialised under our 1-core
model (the same class of dual-core hazard the recon flagged). main_task (core 0)
ran fine; the core-1 path is where it breaks.

---

## Lessons learned

1. **Tiny `.text` return-stubs peel deep init-skipped NULLs.** esp_timer's
   get-time fn-pointer and the stack-overflow hook were both NULL/false-trip
   artifacts of skipped init; 6 bytes each unblocked the entire context switch.
2. **Patch the function, not the `.bss` data** — machine-init writes to `.bss`
   globals (like the esp_timer fn-pointer) get wiped by the runtime bss-clear;
   `.text`/IRAM patches stick.
3. **The frontier is now the dual-core scheduler.** Single-core paths (main_task
   core 0) work end-to-end; the break is core-1 (`loopTask` affinity) list
   management — exactly what the recon said UNICORE would eliminate.

## Próximas direcciones (2.DY)

**Make `loopTask` run on core 0** so `setup()`/`loop()` dispatch:
1. **loopTask core-affinity patch:** find the `xTaskCreateUniversal(loopTask,
   …, ARDUINO_RUNNING_CORE=1)` call in `initArduino` (disassemble for the core
   immediate) and patch the core arg `1 → 0` (or `tskNO_AFFINITY`). Then the
   insert goes to core 0's (valid) ready list, and the scheduler dispatches
   loopTask → `setup()` → `loop()` → `digitalWrite(GPIO2)`.
2. If more core-1 list NULLs appear, fake core-1's per-core list state, or
   pursue the **UNICORE rebuild** (the recon's preferred long-term path).
3. Then esp_timer_get_time→0 may need upgrading to a real SYSTIMER read if any
   timing/timeout logic depends on it.

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` — milestones
show main_task/xTaskCreateUniversal; section 5 shows the vListInsert fault.
