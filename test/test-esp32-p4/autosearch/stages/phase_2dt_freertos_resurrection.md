# Phase 2.DT — FreeRTOS resurrection (step 1): the real scheduler now STARTS

**Estado:** ✅ DONE (milestone + precise blocker + confirmed plan). With the
scheduler bypass dropped, the **genuine `vTaskStartScheduler` now runs and the
FreeRTOS scheduler starts cleanly — no crash** (vs Phase 2.DS, which crashed at
`vTaskDelete`). The first task does not yet launch; the single blocker is the
**FROM_CPU / crosscore software interrupt** that `vPortYield()` uses to trigger
the first context switch, which the model does not deliver. Root cause confirmed:
the **interrupt matrix (`0x500D6000`) is an unimplemented stub**.

Files:
- `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` — `VELXIO_REAL_SCHED` gate
  (extends the 2.DS gate; drops the two 2.M scheduler-bypass patches).
- `test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` — harness.

---

## SE INVESTIGÓ

Phase 2.DS proved the real Arduino flow reaches `setup()` but crashes at the
first real FreeRTOS primitive (`vTaskDelete`) because the **scheduler is
bypassed** (Phase 2.M `jal main_task` + `j setup()`). 2.DT drops that bypass so
the *genuine* `esp_startup_start_app → vTaskStartScheduler` path runs, and
measures how far the real scheduler gets. A 4-agent recon (port / startup / heap
+ synthesis) read the IDF FreeRTOS RISC-V port, the app-startup chain, and the
heap, in parallel with direct source reads.

Gate: `VELXIO_REAL_SCHED` implies `REAL_FLOW` (demo off) and additionally skips
the two bypass patches `0x40009256` (`jal main_task`) and `0x4000307C`
(`j setup()`), keeping all heap/idle/CPU1-wait/ESP_ERROR_CHECK plumbing. Default
+ `REAL_FLOW` modes unchanged.

---

## SÍ funcionó

- **The real FreeRTOS scheduler starts, no crash.** From the symbolized
  `-d in_asm` trace under `VELXIO_REAL_SCHED=1`:
  `esp_startup_start_app → vTaskStartScheduler (17) → xPortStartScheduler (9)
   → vPortSetupTimer → vPortYield (5)`; `esp_intr_alloc` runs 24× **without
  faulting**; `xTaskCreatePinnedToCore` runs (tasks being created). The
  cause-5 NULL+0x14 `vTaskDelete` crash of 2.DS is **gone** — it was a pure
  artifact of the bypass (with no scheduler, `pxCurrentTCBs[0]` stayed NULL;
  the real `vTaskStartScheduler` populates it).
- **Self-tests green (19 OK)** — the gate change is regression-free.

---

## NO funcionó / hallazgo (the precise blocker)

- **The first task never launches** → `setup()` / `loopTask` / `digitalWrite`
  not reached; GPIO2 0 toggles. **No reboot** — the trace just ends idle.
- **Why (exact mechanism):** this IDF dual-core RISC-V port launches the first
  task **not** by a hand-rolled context-restore but by `xPortStartScheduler →
  vPortYield()`, which triggers the **crosscore / FROM_CPU software interrupt**
  (`esp_crosscore_int_send(0, REASON_YIELD)` → writes
  `HP_SYSTEM_CPU_INT_FROM_CPU_0_REG = 0x500C5010`) and lets the normal ISR-exit
  path (`rtos_int_exit → vTaskSwitchContext`) `mret` into the first task. The
  trace tail confirms the loop: `vPortYield → esp_crosscore_int_send_yield →
  esp_crosscore_int_send (×7) → …`. At scheduler start `port_xSchedulerRunning[0]
  == 0`, so `vPortYield`'s busy-wait does not block and the stack unwinds back
  to `start_cpu0_default` — hence "starts but no task launches, no crash".
- **Root cause:** `0x500C5010` falls inside the **`esp32p4.i2c1` unimplemented
  stub** (`0x500C5000`), so the FROM_CPU write is swallowed — **no IRQ raised**
  → `esp_crosscore_isr` never runs → no context switch. Underlying this, the
  **interrupt matrix `0x500D6000` is a `create_unimplemented_device` stub**: it
  swallows the `MAP_REG` writes `esp_intr_alloc` makes, so the model never
  learns which CLIC line each source (FROM_CPU = src 100, SYSTIMER = src 72) was
  assigned. The CPU dispatch uses the **hardwired** `sysbus_connect_irq` line
  (SYSTIMER→17), not the guest-allocated one.

---

## Lessons learned

1. **Dropping the bypass moved the frontier from "crash" to "missing interrupt".**
   2.DS crashed; 2.DT runs the real scheduler and stalls on one undelivered
   software interrupt. That is qualitatively closer to working.
2. **The blocker is the long-flagged INTMTX**, now proven to be on the critical
   path for *both* the first-task yield (FROM_CPU, src 100) and the periodic
   tick (SYSTIMER, src 72). The "top structural gap" is the thing standing
   between us and `loop()`.
3. **Firmware is dual-core** (`NUMBER_OF_CORES=2`, `ARDUINO_RUNNING_CORE=1`):
   `loopTask` is pinned to the **absent core 1**. The honest fix for a 1-core
   QEMU is a **UNICORE rebuild** of the sketch (eliminates core-1 waits +
   `pxCurrentTCBs[2]` aliasing + the affinity problem).

---

## Plan confirmado (recon synthesis) — remaining work to reach loop()

None of it is in the patch table (that part is done by `VELXIO_REAL_SCHED`).

| # | Item | Blocks | Where |
|---|------|--------|-------|
| **GAP-1** | **FROM_CPU crosscore device** @ `0x500C5010` (DR_REG_HP_SYS_BASE+0x10): write→raise mapped CLIC line→`esp_crosscore_isr`; clear→deassert; read→pending bit (so `vPortYield` busy-wait ends). Currently swallowed by the i2c1 stub. | first-task launch | `esp32p4.c` (new device, overlap @ `0x500C5000`) |
| **GAP-2** | **Interrupt-matrix model** @ `0x500D6000`: capture `INTERRUPT_CORE0_*_MAP_REG` writes (source→CLIC line); route SYSTIMER (72) + FROM_CPU (100) to the guest-allocated line instead of hardwired 17/18. (= pending task #47.) | tick + yield dispatch | `esp32p4.c` intmtx stub `:967`; SYSTIMER hardwire `:1142` |
| **Heap** | Extend the bump allocator to **`heap_caps_malloc_default`** (Arduino `new`/`String`/`Serial.begin` route there, not `pvPortMalloc`). Symbol addr from `blink.ino.map`. | Arduino `new` after Serial.begin | runtime patch (mirror `pvPortMalloc`) |
| **UNICORE** | Rebuild blink with `CONFIG_FREERTOS_UNICORE=y` / `NUMBER_OF_CORES=1` → removes core-1 waits, idle-buffer aliasing, loopTask-on-core-1. | dual-core hazards | sketch sdkconfig |
| GAP-3 | SYSTIMER 1 kHz alarm period + `int_clr`/re-arm fidelity. | correct `delay()` timing | SYSTIMER device |

**Staging:** (a) GAP-1 + heap redirect (+ minimal GAP-2 source→line capture so
FROM_CPU's mapped line is known) → first task launches, `main_task` runs,
`vTaskDelete(NULL)` self-deletes cleanly, `loopTask → setup()` runs in task
context. (b) Full GAP-2 + GAP-3 → 1 kHz tick reaches `xPortSysTickHandler` →
`delay()` advances → `loop()` → **GPIO2 toggles** = done.

**Success criteria for the next phase (2.DU):** `pxCurrentTCBs[0]` becomes
non-NULL, the crosscore ISR fires from `vPortYield`, `main_task` runs under the
scheduler, and `setup()` runs inside `loopTask`.

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` (WSL;
dos2unix first). Needs the REAL_SCHED build of `qemu-system-riscv32`.
