# Phase 2.DW — heap_caps fix → allocator works → the context switch now runs

**Estado:** ✅ DONE w/ findings — redirecting `heap_caps_malloc`/`heap_caps_free`
to the bump allocator **fixed the IDF interrupt allocator** (the 2.DV storm is
gone). The real scheduler now **handles the FROM_CPU yield and executes
`vTaskSwitchContext`** — the actual FreeRTOS context switch. New blocker: the
selected task's context restores with **PC=0** (a task stack-frame init issue),
faulting on the first instruction fetch.

Files: `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` (REAL_SCHED heap redirects).

---

## SE INVESTIGÓ

Phase 2.DV left an interrupt storm: `intr_get_item(0)` didn't return
`esp_crosscore_isr`. Root cause found in `intr_alloc.c`: `get_desc_for_int`
(:161) allocates the `vector_desc` table with **`heap_caps_malloc`** (+ its own
`memset`), and `esp_intr_alloc` uses `heap_caps_malloc` for every struct
(intr_handle, shared_vector_desc, non_shared_isr_arg). The 2.L bump redirect
only covered `pvPortMalloc`, so under skipped heap init these returned NULL →
the allocator's bookkeeping was garbage. Symbol addresses from `blink.ino.map`:
`heap_caps_malloc=0x4FF01024`, `heap_caps_free=0x4FF011E4`.

---

## SÍ funcionó

- **`heap_caps_malloc (0x4FF01024) → bump allocator (0x4FF07008)`** via a far
  `jal x0` (offset 0x5FE4, encoded `0x7E50506F`, computed + verified in Python).
  `get_desc_for_int` memsets its own struct, so the non-zeroing bump alloc is
  fine. **Effect:** `esp_intr_alloc` runs 24×→**69×**, distinct functions
  ~1500→**2222** — the allocator now actually allocates.
- **`heap_caps_free (0x4FF011E4) → ret` (no-op):** the first malloc fix exposed
  a `heap_caps_free` crash (`load fault tval 0x1c` — the bump alloc has no block
  headers). A never-free boot leaks into the 125 KB pool, which is fine.
- **The 2.DV interrupt storm is GONE.** With a valid `vector_desc`,
  `intr_get_item` returns the right handler: the FROM_CPU `m_external` trap now
  fires **once**, `esp_crosscore_isr` handles the yield, and the trace shows
  **`rtos_int_exit → rtos_current_tcb → vTaskSwitchContext`** — the **real
  FreeRTOS context switch executes**. `vTaskStartScheduler`/`xPortStartScheduler`
  /`vPortSetupTimer`/`vPortYield` all run; regression-clean (19 OK), REAL_SCHED-
  gated (default + REAL_FLOW unchanged).

This is a major step: we are now **inside the scheduler's context switch**, not
just at interrupt delivery.

---

## NO funcionó / hallazgo — the new blocker (PC=0 on restore)

After `vTaskSwitchContext` picks the next task, the context restore faults:
```
riscv_cpu_do_interrupt: async:0, cause:1 (fault_fetch), epc:0x00000000, tval:0
context: rtos_int_exit -> rtos_current_tcb -> vTaskSwitchContext
         -> esp_timer_get_time -> [mret to PC=0 -> fetch fault]
```
The selected task's saved PC is **0** → `mret` jumps to 0 → instruction-fetch
fault → panic → reboot. The context switch *machinery* works; the **task's
initial stack frame is wrong** (`pxPortInitialiseStack` set a 0 entry PC, or the
restored `sp`/frame is off, or a half-created / wrong-affinity task was picked).

---

## Lessons learned

1. **The bump allocator had to cover `heap_caps_*`, not just `pvPortMalloc`.**
   The IDF interrupt allocator (and most of IDF) routes through `heap_caps_*`;
   the single `pvPortMalloc` redirect was never enough. Two 4-byte patches
   (malloc→bump, free→noop) unblocked the whole allocator + the storm.
2. **Each layer peeled cleanly:** storm (2.DV) → allocator (heap_caps) → context
   switch runs → task-frame PC=0. The frontier marches into the scheduler core.
3. **`heap_caps_free→noop` is safe under a never-free bump pool** — a standard
   emulation simplification for a bounded boot.

## Próximas direcciones (2.DX)

**The PC=0 context-restore.** Determine which task `vTaskSwitchContext` selects
and why its frame has PC=0: (1) is it the static idle task (2.L
`vApplicationGetIdleTaskMemory` buffers) — verify `pxPortInitialiseStack` writes
the entry PC into the frame slot the `rtos_int_exit` asm restores; (2) is it a
wrong-affinity task (loopTask core 1) picked on core 0 — needs the affinity
patch; (3) check `sp`/frame alignment from the bump-allocated task stack. Likely
needs the **loopTask core-affinity patch** + verifying the port's initial frame
layout. Then `setup()` runs in task context → `loop()` → **GPIO2**.

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` (WSL) —
section 5b shows the PC=0 fetch-fault context.
