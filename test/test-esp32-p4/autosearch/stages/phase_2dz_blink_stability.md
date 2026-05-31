# Phase 2.DZ — sustained-blink stability: crash eliminated (NULL-queue guard)

**Estado:** ✅ done w/ findings — the post-blink **reboot is eliminated**. In the
traced measurement the real blink now runs **stably**: no reboot, GPIO2 toggles
(`pin 2 -> 1`), and the system sits in **`vTaskDelay`** (the correct blink-idle
state, not a crash/spin). Two honest caveats remain for a *clean, fast,
deterministic* sustained blink: a NULL-queue task can busy-loop (starvation in
some timings), and the tick is ~10× slow.

File: `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` (REAL_SCHED NULL-guard).

---

## SE INVESTIGÓ

2.DY ran the blink but rebooted afterward. The harness (new sections 5b/6b)
showed it is **not a watchdog** — the trigger is `vTaskPlaceOnEventList` called
with `pxEventList == NULL`: a background task (an IDF subsystem whose init was
skipped, e.g. esp_timer's task after we stubbed `esp_timer_get_time`) blocks on
a **never-created queue**. FreeRTOS' `configASSERT(pxEventList)` fires, but
`__assert_func` is a silent ret (2.K), so it falls through to `vListInsert(NULL)`
→ load fault → panic/reboot. `objdump` of `vTaskPlaceOnEventList` (0x4FF082CA)
showed the structure: `bnez a0, body` at +0x0A, then the NULL path runs the
assert and falls into the body.

---

## SÍ funcionó

**Class guard:** overwrite the NULL path (0x4FF082D6, after `bnez a0,body`) with
the function's own epilogue so it **returns on NULL** instead of crashing:
`lw ra,12; lw s0,8; lw s1,4; lw s2,0; addi sp,16; ret` (copied from the body's
epilogue). Any caller passing a NULL event list now gets a clean return.

**Result (traced `run_realsched_measure.sh`):** the 2.DV/DW/DX/DY chain still
reaches `setup()`/`loop()`/`digitalWrite(2)` → `pin 2 -> 1`, and now **section 6
= "no reboot", last `IN:` = `vTaskDelay`** — the real Arduino blink runs and the
system idles in `delay()` between toggles, **no crash**. Regression-clean
(19 OK), REAL_SCHED-gated.

---

## NO funcionó / hallazgos (honest caveats)

1. **The NULL-guard is a band-aid, not the root fix.** It stops the crash, but
   the task that wanted a never-created queue now gets a non-blocking return and
   may **busy-loop** (re-poll the empty NULL queue), starving `loopTask` in some
   timings. Symptom: an **untraced** 50 s direct run produced **0 GPIO toggles**
   (the busy-loop task won), while the traced script run (different scheduling)
   reaches the toggle and idles in `vTaskDelay`. So the sustained blink is
   **non-deterministic** under this guard. The proper fix is to identify the
   NULL-queue task and either create its queue or stop it from running (or the
   UNICORE rebuild, which removes a class of these).
2. **Tick ~10× slow.** ~100 Hz model tick vs `CONFIG_FREERTOS_HZ=1000`, so
   `delay(500)` ≈ 5 s wall — only ~1 `pin 2` transition per ~5 s.

---

## Lessons learned

1. **The post-milestone tail is more init-skipped NULLs** (queues this time),
   same pattern as the whole resurrection — but masking them (NULL-guard) trades
   a crash for a livelock; the clean fix is real init or stopping the offending
   task.
2. **Traced vs untraced runs schedule differently** — `-d in_asm,int` changes
   timing enough to flip a borderline livelock. Measure both before claiming
   "stable".

## Próximas direcciones (2.EA — clean sustained blink)

1. **Identify the NULL-queue task** (instrument `xQueueGenericCreate` returns /
   the caller of `vTaskPlaceOnEventList`) and give it a real queue, or prevent
   that task from being created — for a deterministic blink without the guard's
   starvation.
2. **SYSTIMER 1 kHz** (GAP-3): honor the guest's alarm period so `delay()` is
   real-speed and toggles are visible at 2 Hz.
3. Then **frontend integration**: the `pin 2` toggles are already in the
   `VELXIO_GPIO_LOG` JSON stream (Phase 2.X) — wire the QEMU-P4 run into the
   Velxio UI.

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` — section 3
shows setup/loop/digitalWrite/vTaskDelay; section 6 = "no reboot".
