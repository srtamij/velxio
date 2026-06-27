# Phase 2.ED — Model the HP core 1 (the dual-core gap, blocker #7)

**Goal:** make the ESP32-P4 emulation dual-core, like the physical chip, so the
real Arduino/IDF firmware's inter-processor calls (`esp_ipc_call_and_wait` →
crosscore IRQ → core 1's `ipc_task`) complete and the boot reaches
`setup()`/`loop()` on the genuine flow (no scheduler bypass).

**Why:** Phase 2.EC got the real boot all the way to `initArduino`, where it spins
on `esp_crosscore_int_send(core 1)` (13628 FROM_CPU writes in an untraced run)
waiting for an HP core 1 our machine doesn't model. The P4 **is** a dual-core
chip (2× HP RISC-V + 1 LP RISC-V), so the faithful fix is a real 2nd core.

## What was investigated (sources: ESP-IDF = authoritative register defs; TRM)

### The two HP cores (TRM Ch 1, Ch 12)
- 2× HP RISC-V (RV32IMAFC + Zb/Zc), each with its **own CLIC** (core-local).
- TRM **Ch 12.5.1/12.6.1 = HP CPU0 Interrupt Matrix**, **12.5.2/12.6.2 = HP CPU1
  Interrupt Matrix** — i.e. each core has a SEPARATE interrupt matrix instance.
  CORE0 matrix @ `DR_REG_INTERRUPT_CORE0_BASE = 0x500D6000` (what we model today);
  CORE1 matrix is a distinct base (CPU1 register summary, Ch 12.5.2).
- CLIC is mapped core-local at `0x20800000` (each core sees its own).

### Core-1 startup mechanism (IDF `start_other_core`, cpu_start.c:274)
For ESP32-P4 the sequence is:
1. `ets_set_appcpu_boot_addr((uint32_t)call_start_cpu1)` — ROM fn @`0x4FC000A8`,
   stores core 1's entry point.
2. `HP_SYS_CLKRST_SOC_CLK_CTRL0_REG` (`0x500E6014`) bit4 `CORE1_CPU_CLK_EN` = 1
   — ungate core 1's CPU clock.
3. `HP_SYS_CLKRST_HP_RST_EN0_REG` (`0x500E60C0`) bit8 `RST_EN_CORE1_GLOBAL` = 0
   — **release core 1 from reset** (this is the "go" edge).
4. Core 0 then waits on `cpus_up` (set by core 1 once it boots).
- (`CLKRST` base = `HPPERIPH1 0x500C0000 + 0x26000 = 0x500E6000`, which is our
  existing `reset_clock` smart-stub region — good, the writes already land there.)

### The crosscore / IPC path
- `FROM_CPU_0` (`0x500E5010`) and `FROM_CPU_1` (`0x500E5014`) are the two crosscore
  software-interrupt registers. `esp_crosscore_int_send(core_id)` writes
  `FROM_CPU_<core_id>` → raises a crosscore IRQ **on that core**.
- Today we wire FROM_CPU_0 → core 0's CLIC line (self-yield works single-core).
  For IPC, core 0 writes FROM_CPU_1 → must raise an IRQ on **core 1**, whose
  `ipc_task` (pinned to core 1) runs the requested callback and signals back via
  a semaphore that core 0 is blocked on.
- The blink is built dual-core (`ARDUINO_RUNNING_CORE=1`): `loopTask` is pinned to
  core 1, which is why the bypass-patch path had to rewrite its affinity to 0.

### QEMU CPU model (target/riscv/esp_cpu.c, esp_cpu.h)
- `EspRISCVCPU` extends `RISCVCPU`; `hartid_base` → `env.mhartid` at realize (so
  core 1 = `hartid_base = 1`).
- Custom IRQ handler `esp_cpu_irq_handler` sets per-instance `irq_pending` +
  `irq_cause`; CLIC delivery (2.S/2.DV) is **per-CPU** already. IRQ lines are the
  per-device gpio `espressif-cpu-irq-lines` — so wiring FROM_CPU_1 to core1's
  lines is the natural mechanism.
- TCG round-robins all created, non-halted CPUs automatically. A 2nd CPU created
  `halted` won't execute until released — exactly the reset-hold we need.

## Design (incremental, gated on VELXIO_REAL_INIT for zero regression)

The demo + REAL_SCHED paths must stay byte-identical (single-core), so the 2nd
core is only created under `VELXIO_REAL_INIT` (the real-flow gate).

- **Step 1 (foundation):** add `EspRISCVCPU soc1`, `hartid_base=1`, realize, hold
  it **halted** at boot; intercept the `HP_RST_EN0` core-1-release write
  (`0x500E60C0` bit8 → 0) to un-halt it. Start core 1 at the ROM reset vector
  `0x4FC00000` so the real ROM's mhartid-based app-cpu path brings it up
  (faithful — same as silicon). Measure: does core 1 fetch / does the IPC spin
  stop?
- **Step 2:** wire `FROM_CPU_1` (`0x500E5014`) → core 1's CLIC line so crosscore
  IRQs reach core 1; give core 1 its own INTMTX instance (CORE1 matrix base).
- **Step 3:** per-core CLIC/INTMTX correctness; verify `ipc_task` runs on core 1
  and the IPC completes → `setup()`/`loop()` on the genuine flow.

## Status

### Step 1 (foundation) — ✅ DONE (core 1 instantiated + released; IPC spin broken)

Implemented in `esp32p4.c`:
- `EspRISCVCPU soc1` added to the machine, created under `VELXIO_REAL_INIT`,
  `hartid_base=1`, `start_powered_off=true` (held in reset), resetvec
  `0x4FC00000`.
- `esp32p4_release_core1()` un-halts + kicks core 1; hooked in
  `esp32p4_smart_stub_write` on the `HP_RST_EN0` (`0x500E60C0`) bit8
  `RST_EN_CORE1_GLOBAL` clear — IDF `start_other_core`'s "go" edge.

**What did NOT work first (documented):**
1. **`tcg_register_thread: assertion (n < tcg_max_ctxs)`** — a 2nd CPU needs TCG
   to allocate 2 vCPU contexts. `mc->max_cpus=2` alone is NOT enough:
   `tcg_max_ctxs` derives from `ms->smp.max_cpus`, which stays 1 unless `-smp 2`
   is passed. **Fix:** run REAL_INIT with `-accel tcg,thread=single -smp 2`.
   Single-thread round-robin is also the *correct* choice for our model (shared
   `irq_pending` state + non-thread-safe device callbacks would race under
   MTTCG); round-robin is deterministic and safe. Scripts updated.

**What worked (verified):**
- `[esp32p4] HP core 1 instantiated (hartid=1), held in reset` then
  `HP core 1 RELEASED from reset (RST_EN_CORE1_GLOBAL cleared) -> PC=0x4fc00000`.
- **The IPC spin is broken:** untraced `from_cpu` writes dropped from **13628 →
  147** — core 0 no longer hammers the crosscore register forever; it now does
  normal IPC traffic and proceeds. `esp_startup_start_app` + `vTaskStartScheduler`
  still reached.
- **Zero regression:** REAL_SCHED blink toggles GPIO2 (2/2); core 1 is REAL_INIT-
  gated so demo/REAL_SCHED stay single-core.

**Better than expected — core 1 boots through the REAL ROM to its IDF entry.**
A focused trace diagnostic (measure script §1a) shows core 1 after release runs
the ROM app-cpu path (PCs `0x4fc00040..0x4fc000a8`, incl. the
`ets_set_appcpu_boot_addr` area) and **reaches `call_start_cpu1` (`0x4ff00b66`)** —
i.e. the faithful "core 1 resets to ROM, ROM reads the boot addr and jumps to
the IDF app-cpu entry" path WORKS, exactly like silicon. Core 0 still reaches
`initArduino` (the earlier apparent regression to `vTaskStartScheduler` was a
2-core trace-interleave measurement fluke). Both cores progress; no regression.

**What's still needed (Steps 2-3):** the boot does not yet reach `loop()` (0 GPIO2
toggles). Core 1 reached `call_start_cpu1` but then needs to run its own FreeRTOS
and service the crosscore IPC: `FROM_CPU_1` (`0x500E5014`) must raise an IRQ on
**core 1**'s CLIC line so `ipc_task` (pinned to core 1) runs core 0's requested
callback and signals back. Today the from_cpu device only wires FROM_CPU_0 →
core 0.
- **Step 2:** ensure core 1 reaches `call_start_cpu1` — either the real ROM
  app-cpu path (mhartid==1 branch) runs core 1 to the stored appcpu boot addr, or
  intercept `ets_set_appcpu_boot_addr` and jump core 1 there directly. Wire
  `FROM_CPU_1` (`0x500E5014`) → core 1's CLIC line for the crosscore IRQ.
- **Step 3:** core 1's own INTMTX (CORE1 matrix base) + per-core CLIC; verify
  `ipc_task` runs on core 1 and the IPC completes → `setup()`/`loop()`.

### Step 2 — ✅ DONE (crosscore matrix + FROM_CPU_1 → core 1 wiring)

Implemented in `esp32p4.c`:
- **HP CPU1 Interrupt Matrix @ `0x500D6800`** (`DR_REG_INTERRUPT_CORE1_BASE` =
  CORE0 + 0x800, TRM Ch 12.5.2): a 2nd `Esp32P4Intmtx` whose `cpu` is core 1,
  created in `esp32p4_install_intmtx` when core 1 is present.
- **FROM_CPU_1** (`0x500E5014`) write → raises core 1's CLIC line via core 1's
  matrix mapping of source **80** (`ETS_FROM_CPU_INTR1`; core 0 uses source 79).

**Verified (REAL_INIT trace):**
```
[esp32p4] HP CPU1 interrupt matrix @0x500d6800 installed
[esp32p4.intmtx1] MAP src 80 -> intr 16 (cpu line 32)   <- core1 maps its crosscore src
[esp32p4.from_cpu] FROM_CPU_1=1 -> core1 line 32 RAISE   <- core0's IPC reaches core1's CLIC
```
- **Untraced `from_cpu` writes: 147 → 19** (was 13628 pre-core-1). The IPC
  handshake is nearly complete — the crosscore IRQ now reaches core 1.
- **Zero regression:** REAL_SCHED blink toggles GPIO2.

**Step 2+ diagnostic (precise blocker found):** a focused trace count shows:
```
esp_crosscore_isr: 12      <- core 1 TAKES the crosscore IRQ and runs the ISR ✓
xPortStartScheduler: 9     <- both cores start their schedulers ✓
call_start_cpu1: 23        <- core 1 runs its IDF entry ✓
ipc_task: 0                <- but ipc_task NEVER runs ✗  <-- THE blocker
```
So the crosscore IRQ delivery to core 1 works end-to-end (the ISR runs), but
`ipc_task` (the FreeRTOS task that executes the IPC callback, pinned to core 1)
is never dispatched. The ISR runs in interrupt context and should wake ipc_task
+ yield, but core 1's scheduler doesn't context-switch to it.

**Step 3 (remaining):** core 1's scheduler needs its own **SYSTIMER tick**
(`SYSTIMER_TARGET1` → core 1's CLIC, mirroring TARGET0→core 0) so it preempts the
idle task and dispatches `ipc_task`. Today the systimer device raises only
`irq_target0` (wired to core 0). Add a 2nd target IRQ → core 1's matrix
(SYSTIMER_TARGET1 source) → core 1's CLIC. Also confirm `ipc_task` is created on
core 1 (`esp_ipc_init`). Then ipc_task runs the callback, signals core 0, and the
boot proceeds to `setup()`/`loop()`.

### Progress summary (FROM_CPU writes, untraced)
`13628` (no core 1) → core-1 runs vary widely run-to-run (`19`–`244`). **The
FROM_CPU count is NOT a reliable progress metric** — with 2 cores under
round-robin TCG the IPC traffic is highly timing-sensitive. The stable signal is
the deterministic milestone counts (esp_crosscore_isr runs, ipc_task does not).

### Step 3 — ❌ tried, did NOT work, reverted (honest finding)

Hypothesis: core 1's scheduler needs its own SYSTIMER tick to preempt idle and
dispatch `ipc_task`. Implemented a 2nd systimer IRQ output (`irq_target1`) fired
each tick and wired to core 1 — first as a **fixed CLIC line 17** (mirroring
core 0), then, when that didn't work, **routed through core 1's interrupt matrix**
(source 54 = `ETS_SYSTIMER_TARGET1`, the faithful per-core delivery).

**Result: neither helped.** `ipc_task` stayed at **0** in all variants (no tick /
fixed-line / matrix-routed). The fixed line (17) doesn't match core 1's
firmware-assigned line (core 0 maps `SYSTIMER_TARGET0`→line 16 via its matrix, not
17 — so the systimer's hardcoded line-17 wiring is itself questionable for the
real flow). The matrix-routed variant delivers to the right line but core 1 still
doesn't run ipc_task. **Reverted** the Step 3 systimer changes to keep the tree at
the clean Step-2 state (the 2nd-IRQ infra was correct but ineffective, and added
noise).

**Why it didn't work — the real blocker is deeper than the tick.**
`esp_crosscore_isr` runs on core 1 (interrupt delivery works), and the crosscore
ISR's ISR-context `portYIELD_FROM_ISR` should dispatch `ipc_task` *without needing
a periodic tick* if the scheduler is running tasks. `ipc_task: 0` means core 1's
FreeRTOS scheduler isn't dispatching tasks at all — likely core 1 is stuck before
running its idle/first task (a FreeRTOS-SMP sync point: `xPortStartScheduler` on
core 1 waits on a cross-core flag / spinlock that our round-robin model doesn't
satisfy), OR `ipc_task` isn't created for core 1. This is genuine dual-core
FreeRTOS-SMP territory, not an interrupt-wiring gap.

**Next (deeper diagnosis required):** trace core 1 specifically (filter by PC
ranges / mhartid) to find where core 1 sits after `call_start_cpu1` — is it
running its idle task, spinning on a sync flag, or stuck pre-scheduler? Confirm
`ipc_task` is created for core 1 (`esp_ipc_init`). Check the FreeRTOS-SMP
cross-core start handshake (`port_xSchedulerRunning[1]`, the `xPortStartScheduler`
core-1 path). This is the substantive remaining work to complete dual-core.

## Risks / notes

- SMP + a custom CPU subclass in TCG is the highest-risk change in this project;
  guarding it behind REAL_INIT protects the working single-core blink.
- The CLIC mmio region is shared across cores in one address space; real silicon
  is core-local. For a first cut, delivery via the per-device gpio lines is what
  matters; full per-core mmio views (per-CPU AddressSpace) are a later fidelity
  step if needed.
- Core 1 booting through the real ROM is the most faithful; fallback is to set
  core 1's PC directly to the stored appcpu boot addr if the ROM app-cpu path
  doesn't run cleanly.
