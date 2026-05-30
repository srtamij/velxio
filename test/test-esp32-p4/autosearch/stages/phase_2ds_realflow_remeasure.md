# Phase 2.DS — Re-measure Track A (real Arduino flow) with the CLIC fix in place

**Estado:** ✅ DONE (measurement + root-cause) — **major milestone confirmed**:
the **real Arduino firmware now boots all the way into `setup()`** (executes
`pinMode`, enters `Serial.begin`), a large jump past Phase 2.P's pre-setup
`esp_log` stall. The single decisive remaining blocker is now **proven by
instrumentation** to be the **FreeRTOS scheduler bypass**, not Serial / a
peripheral / the INTMTX.

This phase does **not** add a peripheral. It re-measures how far the real
firmware path gets *today*, now that the trap-delivery fix (2.AK), the CLIC
mode CSRs (2.R/2.S), the cache/partition unblocks (2.T/2.T-fix) and the
`Print::write` vtable neutraliser (2.T-fix.next.next) are all in the tree —
none of which existed together when Phase 2.P last measured this path.

Files:
- `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` — new `VELXIO_REAL_FLOW`
  env-var gate in the runtime-patch apply loop.
- `test/test-esp32-p4/autosearch/scripts/run_realflow_measure.sh` — the
  committed measurement harness (gate + symbolized `-kernel` ELF + `-d
  in_asm,int` trace + milestone grep + exception capture).

---

## SE INVESTIGÓ (what was researched)

The whole project runs on **two tracks**:
- **Track A** = the *real* firmware path (ROM → bootloader → `start_cpu0`
  → `main_task` → `app_main` → `initArduino` → `setup()`/`loop()`).
- **Track B** = a hand-rolled demo (hello-world UART writer + running-light
  + multi-source ISR blob) injected by the runtime-patch table, plus the
  machine-init self-tests. Almost all of phases 2.W…2.DR validate peripherals
  on Track B, **not** by a booting sketch.

Track A last got a verdict in **Phase 2.P**: dropping the hello-world bypass
let `app_main` start but it stalled in `esp_log_cache_get_level` and **no trap
ever reached `mtvec`** — so the hello-world demo was re-enabled and the
peripheral work continued on Track B. The decisive question for "how far from
a real ESP32" is therefore: **with the 2.AK trap fix + 2.T-fix cache/partition
+ vtable patch all now present, how far does the real path get?**

To measure cleanly (without destroying the Track-B demo), a **`VELXIO_REAL_FLOW`
gate** was added: when set, the runtime-patch apply loop **skips only the
demo-only patches**, by guest-address range, keeping every essential HW
workaround and real-flow enabler. Demo patches occupy three fixed ranges:
`0x4000303E–0x40003063` (hello body + 2.O beqz + 2.V trampoline),
`0x40400000–0x404003FF` (running-light + ISR blob), `0x4FFA0000–0x4FFA001F`
(hello string; the fake-partition struct at `+0x30` is kept). Default build
(env unset) is byte-identical to before — the demo still runs.

Measurement harness: boot the **symbolized app ELF** (`-kernel blink.ino.elf`,
so `-d in_asm` `IN:` lines carry function names) with the flash backing drive,
`VELXIO_REAL_FLOW=1`, `-d in_asm,int` (captures both the reached-function set
and any CPU exception with cause/epc/tval), ~12 s under `timeout -s KILL`
(the IDF panic handler reboots in a loop, so QEMU never exits on its own).

The blink sketch toggles **GPIO2** (`pinMode(2,OUTPUT)`; `loop()` does
`digitalWrite(2,HIGH/LOW)` + `delay(500)`). `Serial.println` is neutralized
(the `Print::write` stub), so **GPIO2 transitions are the loop() signal**.

---

## SÍ funcionó (what worked)

- **The gate works, zero regression.** `REAL-FLOW mode: 98 demo patches
  skipped`; machine-init self-tests stay green (19 OK incl. AHB/AXI-DMA, DMA-
  SHA256, DMA-AES ECB/CBC/CTR) — dropping the demo patches breaks nothing.
- **The real Arduino flow now reaches `setup()`** — a large jump past
  Phase 2.P. From the symbolized `-d in_asm` trace, these functions execute:
  `main_task` → `app_main` → `initArduino` → `setCpuFrequencyMhz` →
  **`_Z5setupv` (setup())** → **`pinMode`** → `Serial` → `_ZN14HardwareSerial`.
  setup() genuinely runs: `pinMode(2,OUTPUT)` executed and the code entered
  `Serial.begin()`/`HardwareSerial`.
- **The 2.AK/2.R/2.S/2.T-fix bet paid off.** None of those existed together
  in Phase 2.P; with them in place the real path no longer stalls pre-setup —
  it executes real Arduino-core C++ code.

---

## NO funcionó / hallazgo (where it stops, and why)

- **It does NOT reach `loop()` / `digitalWrite` / `delay`.** `GPIO2`: 0
  transitions. The trace tail is a **reboot loop**: `…setup → Serial →`
  **CPU exception** → `xt_unhandled_exception` → `esp_panic_handler` (37
  entries) → `panic_print_registers`/`backtrace` → `esp_core_dump_write_elf`
  → `panic_restart` → `esp_restart_noos` → `esp_cpu_reset` → reboot → repeat.
- **Root cause pinned by `-d int`:**
  ```
  riscv_cpu_do_interrupt: hart:0, async:0, cause:00000005,
                          epc:0x4ff073a0, tval:0x00000014, desc=fault_load
  enclosing IN: vTaskDelete → uxListRemove
  ```
  `cause 5` = **load access fault**; `tval 0x14` = a **NULL+0x14
  dereference**; the faulting code is **`vTaskDelete` → `uxListRemove`** —
  a genuine **FreeRTOS task primitive**.
- **The blocker is the FreeRTOS scheduler bypass.** The real Arduino code,
  during the `Serial.begin()` path, performs a real FreeRTOS operation
  (`vTaskDelete`). But the scheduler is *faked*: Phase 2.M jumps straight to
  `main_task` (skips `vTaskStartScheduler`), and Phase 2.L provides a bump-
  allocator + static idle-task buffers instead of a real heap/scheduler. So
  the FreeRTOS task lists / current-TCB are never validly initialised →
  `uxListRemove` walks a NULL list item → load fault → unhandled exception →
  panic → reboot.
- **This reproduces + sharpens the Phase 2.T-fix.next.next finding.** That
  phase already noted "`uxListRemove` called with garbage pointer (FreeRTOS
  state corruption from skipped scheduler init)" while chasing single-patch
  fixes. Phase 2.DS reproduces it via a **clean, reversible gate** and nails
  the exact instruction (`vTaskDelete`, epc `0x4ff073a0`, tval `0x14`).
- **Observability gap:** the IDF panic banner never appears on stdout
  (`panic_print_char` runs 18× but writes via `esp_rom_printf` to a ROM-UART
  path not muxed to `-nographic` stdout). The crash is only visible through
  the `-d int` trace, not the guest's own panic dump.

---

## Lessons learned

1. **Track A is much closer than the tracker implied.** The honest pre-2.DS
   read was "boots the bootloader; real setup()/loop() deferred." The
   measured reality: **real `setup()` runs**; only the FreeRTOS task layer
   blocks `loop()`. The accumulated 2.AK/2.T-fix/vtable work moved the
   frontier from "pre-setup esp_log stall" to "first real FreeRTOS task op."
2. **The remaining blocker is now unambiguous: the real scheduler.** Not
   Serial, not a missing peripheral, not directly the INTMTX. Every bypass
   hack gets the flow into `setup()`, but the first authentic FreeRTOS
   primitive (`vTaskDelete`) dies because the task state is fake. The
   "FreeRTOS resurrection" is the make-or-break for end-to-end sketches.
3. **An address-range env-gate is the right tool to A/B real-vs-demo** without
   destroying the user-visible demo or doing destructive patch surgery — and
   it's reproducible/committed, unlike the comment-in/comment-out of 2.P.
4. **`-d in_asm,int` over a symbolized `-kernel` ELF is the cheap, precise
   probe**: `IN:` symbols give the reached-function set + the stall function,
   and `int` gives the exact `cause/epc/tval`. (Monitor `info registers` PC
   sampling failed on a regex mismatch — superseded by `-d int`.)

---

## Implementación final (the gate)

In `esp32p4.c`, the runtime-patch apply loop now reads `VELXIO_REAL_FLOW`
and skips the three demo address ranges when set, logging
`REAL-FLOW mode … N demo patches skipped` (98 skipped). Everything else —
flash ret-0 stubs, `system_early_init` skips, FreeRTOS heap/idle/bump-alloc
plumbing, `app_main: j setup()`, the `esp_ota` stub + fake partition, the
`Print::write` vtable neutraliser — is applied unchanged. Default build is
untouched.

**Reproduce:** `bash test/test-esp32-p4/autosearch/scripts/run_realflow_measure.sh`
(WSL; dos2unix first). The default Track-B demo is still
`bash …/run_i2s_selftest.sh` etc.

---

## Estado consolidado (Track A, measured 2.DS)

| Milestone | Status |
|---|---|
| ROM banner + bootloader (6.4 s) | ✅ |
| `start_cpu0` → `main_task` → `app_main` (real body) | ✅ |
| `initArduino` → `setCpuFrequencyMhz` | ✅ |
| **`setup()` entered + `pinMode(2)` runs** | ✅ **(2.DS — new)** |
| `Serial.begin()` / `HardwareSerial` entered | ✅ |
| **`loop()` / `digitalWrite` / `delay`** | ❌ crash before |
| Crash: `vTaskDelete→uxListRemove` NULL+0x14 load fault | ⛔ scheduler bypass |
| Real FreeRTOS scheduler (context switch on CLIC tick) | ❌ **the blocker** |

## Próximas direcciones (next)

1. **FreeRTOS resurrection (the make-or-break).** Drop the scheduler bypass
   entirely (Phase 2.M `jal main_task` + `j setup()`), run the **real
   `vTaskStartScheduler`** with a **real heap** (replace the 2.L bump-allocator
   with working `heap_caps`) and let the **context switch fire on the now-
   working CLIC SYSTIMER tick** (2.S dispatch + 2.AK trap fix). If the tick
   preempts and `loopTask` dispatches, `setup()`→`loop()`→`digitalWrite(GPIO2)`
   runs end-to-end — the first *real* blink. Sub-steps: real heap init, real
   idle/timer-task creation, verify the first context-switch trap via the
   2.AK CLIC path, then re-run `run_realflow_measure.sh` and watch GPIO2.
2. **Make the panic banner visible** — mux the ROM-UART `panic_print_char`
   path to `-nographic` stdout so the guest's own `Guru Meditation` dump is
   captured (better diagnostics for the resurrection work).
3. (Rejected as a *primary* direction) Neutralising `vTaskDelete` the way
   `Print::write` was neutralised would push to the *next* fault but is the
   "illusion" path — it doesn't make the scheduler real. Use only as a
   throwaway probe for what blocks *after* the scheduler, if needed.
