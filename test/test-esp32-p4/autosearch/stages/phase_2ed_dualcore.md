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

## Web + source research (the dual-core boot handshake)

Investigated the IDF app-cpu boot handshake (the precise mechanism core 1 must
complete) and prior-art emulators. Sources: ESP-IDF source (authoritative),
Espressif QEMU fork (local clone), Espressif docs, web search.

### The app-cpu start handshake = shared-memory spin flags (IDF cpu_start.c / startup.c)
This is the exact sequence that must work for core 1 to run tasks:
1. Core 0 `start_other_core()` releases core 1 (CLKRST), then **spins**:
   `while (!cpus_up) cpus_up &= s_cpu_up[i];` — waits for core 1.
2. Core 1 `call_start_cpu1()`: sets `s_cpu_up[1]=true` → HW init →
   `s_cpu_inited[1]=true` → **spins `while (!s_resume_cores)`**.
3. Core 0 (seeing s_cpu_up) continues init, eventually sets `s_resume_cores`.
4. Core 1 resumes → `esp_startup_start_app_other_cores()` → **spins
   `while (!s_system_full_inited)`** → then starts its scheduler.
5. Core 0 finishes system init → sets `s_system_full_inited`.
6. Core 1's scheduler runs → dispatches `ipc_task` etc.

**Key implication:** the whole handshake is **plain volatile globals in shared
L2MEM** polled in tight spin loops. For it to converge under our **single-thread
round-robin TCG**, each core must observe the other's writes across round-robin
slices. Core 0 reaching `initArduino` proves steps 1/3/5 work (core 0 saw
s_cpu_up, set the resume flags). So core 1 should be past its spins and into its
scheduler — yet `ipc_task` never runs. The likely remaining issue is therefore
**inside core 1's running scheduler** (idle runs but ipc_task isn't dispatched),
not the boot handshake — consistent with the Step-3 finding. A core-1-filtered
PC trace is the next diagnostic.

### Prior-art emulators (reference + "are we the only P4 emulator?")
- **Espressif QEMU fork (Xtensa ESP32) IS dual-core** — creates both CPUs upfront
  and holds APP_CPU via Xtensa **RUNSTALL** (`xtensa_runstall`, DPORT
  appcpu_stall/clkgate). RISC-V has no RUNSTALL; our `start_powered_off` +
  release-on-CLKRST is the correct RISC-V equivalent (confirmed the approach).
  The fork has **no RISC-V dual-core ESP machine** (its hw/riscv has only generic
  boards: virt, sifive, opentitan…), so there is no P4 reference to copy.
- **No ESP32-P4 software emulator exists anywhere** (web search June 2026): all
  ESP32 QEMU projects (Ebiroll, mluis, emb-team, official Espressif) target the
  Xtensa ESP32 or C3/S3. Confirms our qemu-lcgamboa P4 work is the only full-chip
  P4 emulator — already established earlier (official Espressif QEMU has no P4).
- **`Mister-Industries/tinyCore` (user-asked) is NOT a P4 emulator** — it's a
  physical 50×50 mm dev board with a real **ESP32-S3** (not P4) chip; no
  emulation/QEMU/simulation, and not even the P4 part. Unrelated to P4 software
  emulation.

### FreeRTOS-SMP fact (Espressif docs)
Each core runs its OWN periodic tick interrupt independently (CPU0 does full tick
duties; CPU1 only checks time-slicing + runs the app tick hook). Confirms core 1
needs its own tick — but the Step-3 experiment showed the tick alone doesn't
dispatch ipc_task, so the blocker is the scheduler-run state, not tick wiring.

## Core-1 scheduler trace (the diagnostic the user asked for) — KEY REFRAMING

Traced the per-function execution (`-d in_asm` `IN:` counts; 0 = never executed).
Findings reframe the blocker as UPSTREAM of the dual-core machinery:

| symbol | count | meaning |
|---|---|---|
| `esp_crosscore_isr` | 11 | core 1 takes the crosscore IRQ ✓ |
| `xTaskCreatePinnedToCore` | 10 | FreeRTOS task creation works ✓ |
| `vTaskSwitchContext` | 24 | context switches happen (core 0 init tasks) ✓ |
| `vPortSetupTimer` | **1** | only ONCE = core 0; **core 1 never runs its scheduler body** |
| `prvIdleTask` | **0** | **no core ever runs the idle task** |
| `esp_ipc_init` | **0** | **ipc_task is NEVER created** |
| `do_global_ctors` | **0** | **C++ global constructors never run** |
| `__libc_init_array` | **0** | (same) |

**Root reframing:** `esp_ipc_init` is a C++ `__attribute__((constructor))`
(`esp_ipc.c:110`) that creates `ipc_task` pinned to each core at MAX priority. It
is invoked by `do_global_ctors()` (`startup.c:201`, "Execute constructors",
iterating `__init_array_start..__init_array_end`). **Both show 0 executions** — so
the C++ constructor phase never runs in our REAL_INIT boot, therefore `ipc_task`
is never created, therefore the crosscore IPC can never complete **regardless of
core 1's scheduler or tick**. The dual-core wiring (Steps 1-2) is correct and
needed, but it was chasing a symptom; the real gap is **the global-constructor
phase not running**.

**Open contradiction to resolve next:** core 0 reaches `initArduino` (which is
*after* `do_global_ctors` in the startup order: `start_cpu0` → `do_global_ctors`
(201) → `start_app` → `main_task` → `app_main` → `initArduino`). If
`do_global_ctors` truly never ran, how is `initArduino` reached? Two hypotheses:
(a) the `-d in_asm` counts are misleading for very-early one-shot functions whose
TBs were translated before symbolised capture / flushed — need a PC-watch on
`__init_array` addresses to confirm; (b) the REAL_INIT flow genuinely skips/faults
`do_global_ctors` and limps on (Arduino C++ static ctors also skipped) — which
would be a real boot-fidelity gap affecting more than IPC.

**Concrete next step:** set a one-shot log when the guest executes the
`do_global_ctors` / `__init_array` address range (read from the ELF) to settle
(a) vs (b). If constructors genuinely don't run, fixing that (not the dual-core
tick) is what unblocks ipc_task — and likely several other latent issues. This is
the cleanest lead and supersedes the SYSTIMER-tick direction.

### 🔑 UNIFYING FINDING — the C++ global constructors don't run (one root, two symptoms)

The `.flash.init_array` (`0x4003DF30`, 8 entries, dumped from the blink ELF) holds
**valid** constructor pointers:
```
0x400006b4  _GLOBAL__sub_I_hardware_serial_end   <- constructs HardwareSerial Serial0/1/2
0x40000b44  _GLOBAL__sub_I__ZN6StringC2EPKc      <- Arduino String
0x40003ba8  _GLOBAL__sub_I__Zli4_kHzy
0x40007010  esp_ipc_init                          <- creates ipc_task (the IPC blocker)
0x40028180  ...
0x4ff03f12  ...
0x4001b768  _GLOBAL__sub_I__ZN9__gnu_cxx9__freeresEv
0x4001ba7e  _GLOBAL__sub_I__ZN17__eh_globals_init...
```
So the ELF's constructor table is correct. The trace shows `esp_ipc_init: 0` +
`do_global_ctors: 0` → **these constructors never execute**, which explains TWO
previously-separate symptoms with ONE root cause:
1. **`ipc_task` is never created** → the dual-core crosscore IPC can't complete →
   boot stalls before `setup()`/`loop()` (Phase 2.ED).
2. **`Serial` produces no output** → `HardwareSerial`'s global constructor
   (`_GLOBAL__sub_I_hardware_serial_end`, also in init_array) never runs, so the
   `Serial` objects are never constructed (Phase 2.EC periph-probe symptom).

**This reframes the remaining work:** the highest-value fix is NOT the dual-core
SYSTIMER tick but **getting `do_global_ctors` / the `__init_array` constructor
loop to actually run** in the REAL_INIT boot. That single fix would unblock the
IPC (ipc_task) AND Serial AND any other constructor-dependent init.

**Caveat / contradiction to resolve:** `soc_memory_regions` @`0x4003AD24` (same
`0x4003xxxx` flash-cache band) read CORRECTLY in Phase 2.EC (heap init worked), so
that band's content is generally right — arguing the init_array bytes at
`0x4003DF30` are probably also correct in memory, and the real issue is that
`do_global_ctors` isn't *reached/executed* (it's `static`, likely inlined into
`start_cpu0_default` @`0x400091E8`, so it wouldn't show as its own `IN:` symbol —
need a PC-watch on the `__init_array` iteration, not the symbol). The do_system_init
NOPs un-skipped under REAL_INIT are at `0x400091F2`/`0x4000923A`
(= `start_cpu0_default+0x0A`...), so the constructor loop's execution within that
function is exactly what to verify next.

**Next-step plan (supersedes SYSTIMER tick):** instrument the machine to log when
the guest fetches from the constructor addresses (e.g. `0x40007010` esp_ipc_init,
`0x400006b4` HardwareSerial ctor) — confirm whether `do_global_ctors` calls them.
If not, find where `start_cpu0_default`'s constructor loop diverges (its bounds
read of `__init_array_start/end`, or an early return). Fixing it unblocks both
the IPC and Serial — a much higher-value target than the dual-core tick.

### ✅ PC-watch DONE — the ctor loop's branch falls through (root cause narrowed)

Disassembled `start_cpu0_default` (`0x400091E8`): `do_global_ctors` is **inlined**
as two `__init_array` loops. The descending loop's guard is
`bgeu s0,a5,0x40009264` @`0x40009230` (s0 = `__init_array_end-4` = `0x4003DF4C`,
a5 = `__init_array_start` = `0x4003DF30`), with the loop body
(`lw a5,0(s0); jalr a5`) at `0x40009264`. PC-watch counts (`-d in_asm`, raw PCs):
```
0x400091e8 start_cpu0 entry          : 1
0x400091f2 do_system_init(0) call     : 1
0x4000920e after __register_frame_info: 1
0x40009230 bgeu (ctor-range check)    : 1   <- the guard RAN
0x40009234 resume_other_cores         : 1   <- ...and FELL THROUGH (ctors skipped)
0x40009264 ctor-loop body / 0x40009260 ctor CALL : 0   <- ctor loop NEVER runs
0x40009256 esp_startup_start_app      : 1
0x40007010 esp_ipc_init / 0x400006b4 HardwareSerial ctor : 0
```
**The `bgeu` at `0x40009230` should be TAKEN** (`0x4003DF4C >= 0x4003DF30`,
deterministic register-immediate math) but it FALLS THROUGH — so either the
instruction bytes at `0x40009230` (or the s0/a5 setup at `0x40009212..0x4000922C`)
in the cache window **differ from the ELF**, or s0/a5 are corrupted at runtime.
No runtime patch touches `0x40009212..0x40009262` (the only nearby patch is the
`0x40009256` scheduler-bypass, which REAL_SCHED un-skips — confirmed by
`esp_startup_start_app:1`).

**Mechanism hypothesis:** the `.flash.text` code at `0x40009xxx` in the flash
cache window doesn't match the ELF — an ELF-load vs flash-blob-load order / cache-
MMU mapping conflict in the `.flash.text` band. (`.flash.rodata` @`0x4003AD24`
`soc_memory_regions` reads CORRECTLY — so .rodata is fine but .text around the
ctor loop may not be; different flash sections / offsets.)

**Decisive next step:** read back the bytes at `0x40009212..0x40009262`
(ctor-loop code) and `0x4003DF30..0x4003DF50` (init_array pointers) from emulator
memory at machine-init-end (a one-shot `address_space_read` log, REAL_INIT-gated)
and diff against the ELF disassembly/objdump. If the .text bytes are wrong, fix
the load order / cache-window mapping so `.flash.text` matches the ELF; that
restores the ctor loop → constructors run → ipc_task created + Serial constructed
→ unblocks BOTH the dual-core IPC and Serial in one fix.

### ✅✅ ROOT CAUSE FOUND + FIXED — demo NOPs were disabling the C++ ctor loop

The machine-init read-back nailed it:
```
*(0x40009230)=0x00000013  (expected 0x02f47a63 bgeu)   <- the ctor-loop branch is a NOP!
*(0x40009222)=0xf5040413  (correct)
*(0x4003df30)=0x400006b4  (correct — init_array data is fine)
```
The `bgeu` guarding the `__init_array` ctor loop was **patched to a NOP**. Found
the culprit: two **Phase 2.K demo runtime patches** that deliberately skip the C++
constructors (the demo blob didn't need them):
```c
{ "start_cpu0: skip __register_frame_info",   0x4000920A, 0x00000013, 4 },
{ "start_cpu0: skip init_array C++ ctor loop", 0x40009230, 0x00000013, 4 },
```
These were applied **even under REAL_INIT** — only the `do_system_init` NOPs
(`0x400091F2`/`0x4000923A`) had been added to the REAL_INIT un-skip list, not
these two. **Fix:** add `0x4000920A` and `0x40009230` to the REAL_INIT un-skip
condition so the real instructions stay and `do_global_ctors` runs the
`__init_array`.

**Verified after the fix:**
```
*(0x40009230)=0x02f47a63  (real bgeu restored)
esp_ipc_init        @0x40007010 : 1   <- the IPC-task constructor NOW RUNS -> ipc_task created
HardwareSerial ctor @0x400006b4 : 1   <- Serial objects NOW CONSTRUCTED
String ctor         @0x40000b44 : 1
```
**This is the unifying fix** — the C++ global constructors now execute, creating
`ipc_task` (the dual-core IPC dependency) AND constructing the `HardwareSerial`
`Serial` objects (the Serial-output dependency). REAL_SCHED blink unaffected
(GPIO2 toggles). The boot now advances past the constructor phase to
`spi_flash_disable_interrupts_caches_and_other_cpu` (a dual-core flash op that
stalls core 1 via the now-working IPC) — a new, deeper blocker, but the
constructor root cause is closed.

**Next blocker:** `spi_flash_disable_interrupts_caches_and_other_cpu` +
`esp_crosscore_isr` — the IPC is now exercised (ipc_task exists); core 1 must
acknowledge the stall. This is the genuine dual-core-coordination work the earlier
steps prepared for, now reachable because the constructors run.

### Dual-core flash-op blocker — chain verified, narrowed to core-1 first-task dispatch

`spi_flash_disable_interrupts_caches_and_other_cpu` (cache_utils.c): with the
scheduler running (initArduino time), it `esp_ipc_call_nonblocking(core1,
spi_flash_op_block_func)` → core 1's `ipc_task` must run that to stall core 1.
So it needs core 1's scheduler to actually dispatch `ipc_task`.

Verified the whole chain with PC-watches + a machine-init read-back:
- **`ipc_task` IS created** now (constructor fix) — but `ipc_task`/`prvIdleTask`
  still never execute (count 0 = TB never translated = never run by either core).
- **Core 1 passes the start handshake:** `startup_resume_other_cores` (core 0)
  runs → core 1 exits its `while(!s_resume_cores)` spin (call_start_cpu1 @0x4ff00c04)
  → reaches `esp_startup_start_app_other_cores` (0x400283bc) → reaches
  `xPortStartScheduler` (0x4ff06d2c). So core 1 DOES start its scheduler.
- **mhartid is correct** (machine-init read-back: `core0=0 core1=1`) — so
  `xPortGetCoreID()` returns 1 on core 1 and `vPortYield` →
  `esp_crosscore_int_send_yield(coreID=1)` → `FROM_CPU_1` → core 1's CLIC (Step 2
  wiring) → `esp_crosscore_isr` (runs 12×). The yield is routed to the right core.
- `vPortYield` (default FreeRTOS-Kernel, NOT the buggy hardcoded-`core_id=0`
  FreeRTOS-Kernel-SMP variant) is correct.

**So the precise remaining blocker:** core 1 reaches `xPortStartScheduler` →
`vPortYield` (fires FROM_CPU_1, ISR runs), but its **first task (`ipc_task`/idle)
is never dispatched** — the crosscore-yield → `vTaskSwitchContext` → first-task
context-RESTORE on core 1 doesn't complete. This is the **same class as Phase
2.DX** (the PC=0 / task-stack-frame context-restore that core 0 needed), now on
core 1's first context switch.

**Measurement limitation (important):** `-d in_asm` counts TB *translations*, not
executions, and can't distinguish core 0 vs core 1 for shared TBs (a TB core 0
already translated then run by core 1 shows count 1). To diagnose core 1's
context switch precisely, the next step needs **per-core execution logging** —
instrument `esp_cpu` to log `(hartid, PC)` (throttled, env-gated) so we can watch
core 1's crosscore-yield ISR → `vTaskSwitchContext` → why the first task's context
isn't restored. That is the concrete next step to finish dual-core.

### Session headline
The unifying constructor fix (un-skip the demo NOPs at `0x4000920A`/`0x40009230`
under REAL_INIT) is the major win: C++ global constructors now run → `ipc_task`
created + `HardwareSerial Serial` constructed. The dual-core boot now advances
through the full start handshake to core 1's `xPortStartScheduler`; the last gap
is core 1's first-task context restore (a 2.DX-class fix on the app cpu).

### ✅ Per-core logging built + PRECISE root cause located (core 1 aborts)

Added two reusable diagnostics to `esp_cpu.c` / `esp32p4.c` (gated by
`VELXIO_CORELOG`): a **per-core interrupt log** (`[corelog] hart=N IRQ cause=..
mepc=.. -> pc=..`) and a **per-core PC sampler** (`[pcsample] core0 pc=.. core1
pc=..`). These overcome the `-d in_asm` "translation-not-execution" blind spot.

**What they showed:**
- Core 1 takes exactly ONE interrupt: `hart=1 IRQ cause=32 mepc=0x4ff00f36 ->
  pc=0x4ff00268`. cause=32 = the FROM_CPU_1 crosscore line (Step 2); mepc is
  inside `esp_crosscore_int_send` (core 1 sending its own yield from vPortYield);
  pc=`0x4ff00268` = `_interrupt_handler`. So the yield IRQ IS delivered to core 1.
- PC sampler (stable): **core0 pc=`0x4ff00268`** (`_interrupt_handler`), **core1
  pc=`0x4ff058b6`** = `esp_restart_noos+0xf6` (`jal esp_cpu_reset; j .`) — **core 1
  is REBOOTING.**
- UART0 stdout (the panic handler): **`abort() was called at PC 0x400283eb on
  core 1`** + "Core 1 register dump" + "Rebooting...".

**PRECISE root cause** — disasm of `esp_startup_start_app_other_cores`
(`0x400283bc`):
```
400283e2: jal xPortStartScheduler   ; must never return
400283e6: jal abort                 ; <-- core 1 lands here (PC 0x400283eb)
```
**Core 1's `xPortStartScheduler` RETURNS** → falls through to `abort()` → panic →
`esp_restart_noos` → reboot loop. `xPortStartScheduler` ends in `vPortYield()`,
which fires the yield IRQ and spin-waits for `_interrupt_handler` to switch to the
first task and **never return**. On core 1 the handler is entered (cause=32) but
**returns without context-switching** → `vPortYield` returns → `xPortStartScheduler`
returns → `abort`. So core 1's **first-task context switch via the yield ISR does
not fire** (`_interrupt_handler` → `rtos_int_exit` → `vTaskSwitchContext` doesn't
swap to ipc_task/idle on core 1's first yield). This is the genuine 2.DX-class
first-task launch, now precisely on core 1.

### 🎉 SIDE WIN — Serial output now works
The panic register-dump + "Rebooting..." text came out of **UART0 (Serial)** — so
the constructor fix (which constructs the `HardwareSerial` objects) **fixed Serial
output**, confirmed end-to-end. One of the original Phase-2.EC goals (Serial in
the real boot) is now met as a direct consequence of the ctor fix.

### Next step (core 1 first-task switch)
Diagnose why `_interrupt_handler` → `rtos_int_exit` doesn't switch context on
core 1's first yield: check `pxCurrentTCBs[1]` is set, that `esp_crosscore_isr`
runs for cause=32 on core 1 and sets the per-core yield flag, and that
`rtos_int_exit` acts on it for core 1. Candidate complication: the REAL_SCHED
bypass patches (heap_caps→bump, loopTask affinity 1→0, vTaskPlaceOnEventList
NULL-guard) were tuned for the single-core blink and may interfere with the real
dual-core scheduler — consider whether REAL_INIT should also un-skip some of them.

### 🔑🔑 DEEPEST ROOT CAUSE — the crosscore-yield context switch never completes (either core)

The PC sampler was extended to dump the SMP scheduler globals
(`pxCurrentTCBs`/`xPortSwitchFlag`/`port_xSchedulerRunning`, all in L2MEM .bss).
Stable result across the whole run:
```
TCB[0,1]=0x4ff61a08,0x4ff61f68   <- both cores HAVE a current task (not the issue)
swflag[0,1]=0,0                  <- xPortSwitchFlag never set, either core
schedrun[0,1]=0,0                <- port_xSchedulerRunning never set, either core
core1 pc=0x400283ce              <- core 1 spinning in `while(port_xSchedulerRunning[0]==0)`
```
**Key source fact:** `port_xSchedulerRunning[coreID]=1` AND `xPortSwitchFlag
[coreID]=1` are both set **inside `vPortYieldFromISR`** (port.c:675-676), which
runs in the yield ISR. They are **0 for both cores forever ⇒ `vPortYieldFromISR`
NEVER runs on either core** ⇒ the crosscore-yield → `vPortYieldFromISR` →
`rtos_int_exit` → `vTaskSwitchContext` first-task switch never completes.

**Why core 0 "works" anyway but core 1 can't:** core 0 reaches initArduino/runs
tasks via the **REAL_SCHED bypass patches** (which substitute for the real
crosscore-yield scheduler delivery). Core 1, in `esp_startup_start_app_other_cores`,
faithfully spins on `while(port_xSchedulerRunning[0]==0)` (disasm @0x400283ce-d4)
waiting for core 0's scheduler-running flag that the bypassed path never sets →
core 1 hangs there (or, with different timing, falls through to `xPortStartScheduler`
→ returns → `abort` → reboot, as seen earlier).

**This reframes the whole dual-core completion:** it is NOT a small core-1 patch.
The real fix is to make the **crosscore-yield → `vPortYieldFromISR` →
`rtos_int_exit` → `vTaskSwitchContext` context switch actually fire** in our model
(so `port_xSchedulerRunning`/`xPortSwitchFlag` get set and tasks dispatch on BOTH
cores **without** the REAL_SCHED bypasses). That means the yield crosscore IRQ
(`cause=32` → `_interrupt_handler` → `_global_interrupt_handler` → `esp_crosscore_isr`
REASON_YIELD → `vPortYieldFromISR`) must run end-to-end. Today `esp_crosscore_isr`
(`0x4ff00e4a`) evidently isn't reached / doesn't set the flags from the yield ISR
on either core — the next concrete step is to watch core 0's first yield ISR with
the per-core log and find where `_global_interrupt_handler`'s dispatch to
`esp_crosscore_isr` / `vPortYieldFromISR` diverges. Fixing that is what the
REAL_SCHED bypasses have been papering over since Phase 2.DV — and it's the real
prerequisite for genuine dual-core.

**Reference (Espressif QEMU S3, Xtensa):** the S3 models per-core interrupt
routing via a SINGLE `Esp32s3IntMatrixState` with `DEFINE_PROP_LINK("cpu0"/"cpu1")`
to both CPUs — the matrix delivers each source to the correct core. Our P4 uses
two matrix instances (intmtx/intmtx1); the equivalent must ensure the yield source
dispatches `esp_crosscore_isr` on the right core's handler table.

**Web:** the APP-CPU `xPortStartScheduler`-returns→`abort()` is a known IDF failure
mode; common causes are the first-task context switch not completing / stack
corruption on the secondary core — consistent with the above.

### ⚡ Attacked the yield-ISR delivery — it's a TIMING RACE (yield storm), not a wiring bug

Added a yield-ISR-chain counter (measure §1a6) + per-core IRQ cause distribution.
Findings:
- **Traced run:** the full chain runs — `_global_interrupt_handler:5`,
  `esp_crosscore_isr:11`, **`vPortYieldFromISR:2`**, `vTaskSwitchContext:29`,
  `rtos_int_exit:33`. So the mechanism is wired correctly and DOES fire when traced.
- **Untraced run (real timing):** per-core IRQ log shows **core 0 takes 105×
  `cause=33`** (its own FROM_CPU_0 crosscore-yield line, `mepc=0x4ff00f26` =
  `esp_crosscore_int_send` epilogue) + 5× `cause=17` (tick); **core 1 takes 1×
  `cause=32`** then hangs. So **core 0 is in a YIELD STORM** — it sends a yield,
  takes the IRQ into `_interrupt_handler`, the context switch does NOT complete,
  it returns, sends another yield → repeat. `schedrun=0` confirms
  `vPortYieldFromISR` never finishes the switch untraced.

**Conclusion — this is a timing-sensitive dual-core race, not a missing wire:**
- The yield→switch chain works **traced** and works in the **single-core
  REAL_SCHED blink** (GPIO2 toggles). It only storms/hangs **untraced + dual-core**.
- So **adding core 1 breaks core 0's previously-working scheduler start** through
  timing interaction (round-robin between the two cores + the immediate
  self-yield IRQ firing the instant FROM_CPU_0 is written). The REAL_SCHED bypass
  patches were tuned for single-core timing and don't hold under the dual-core
  round-robin.

**What this means for the fix (honest):** completing genuine dual-core is NOT a
small patch — it requires making the real scheduler robust under dual-core
round-robin timing. Concrete candidate directions for next session:
1. **Edge- vs level-trigger** of the FROM_CPU crosscore line: if the self-yield
   IRQ re-fires the instant it's written (before the ISR clears it / before the
   switch), it can storm. Verify our from_cpu device lowers the line exactly when
   the guest clears the FROM_CPU reg, and that the ISR's clear is ordered before
   the switch.
2. **rtos_int_enter/exit schedrun gating** (portasm.S:493 / :624): both early-exit
   when `port_xSchedulerRunning[coreID]==0`; the first yield must bootstrap
   `vPortYieldFromISR`→schedrun=1 within one ISR. Check the bootstrap ordering
   holds under our trap timing.
3. **TCG round-robin quantum**: a longer/shorter `-accel tcg,thread=single`
   round-robin slice (or `-icount`) may change whether the race manifests — worth
   an experiment to confirm it's purely timing.

This is the real prerequisite the REAL_SCHED bypasses have masked since 2.DV;
landing it is a substantial, open-ended phase of its own.

**Candidate #1 (FROM_CPU clear) — RULED OUT.** Checked
`hal/esp32p4/crosscore_int_ll.h`: trigger = `WRITE_PERI_REG(FROM_CPU_n, bit)`,
clear = `WRITE_PERI_REG(FROM_CPU_n, 0)`, get_state = `REG_READ(FROM_CPU_n)`. Our
`esp32p4_from_cpu` device matches exactly (write bit→raise line, write 0→lower
line, read→stored value). So the storm is NOT a missing/!modelled clear — the
crosscore line lowers correctly when the ISR clears it. The storm is the
*symptom* of the context switch not completing (the timing race), not a wiring
gap.

### ✅ Lead #2 (schedrun bootstrap ordering) — RULED OUT as a firmware bug

Read `portasm.S` `rtos_int_enter` (:493) and `rtos_int_exit` (:624). Both early-
exit when `port_xSchedulerRunning[coreID]==0`. BUT the bootstrap is correct by
design: on the first yield, `_interrupt_handler` calls `rtos_int_enter` (early-
exits, schedrun==0) → then `_global_interrupt_handler` → `esp_crosscore_isr` →
`vPortYieldFromISR` (which **sets** `port_xSchedulerRunning[coreID]=1` +
`xPortSwitchFlag[coreID]=1`) → THEN `rtos_int_exit` reads schedrun (now 1) and
switches. So the firmware ordering bootstraps correctly within one ISR — not the
bug. The real problem is upstream: `vPortYieldFromISR` doesn't run untraced.

### ✅✅ Lead #3 (-icount) — CONFIRMS timing AND FIXES core 0's scheduler

Ran with `-icount shift=2` (deterministic instruction-counted timing,
`run_realinit_icount.sh`). Result vs the default real-time run:
| | default (RT) | `-icount shift=2` |
|---|---|---|
| core0 IRQs | 105× cause=33 (yield STORM) | 178× cause=17 (TICK), 1× yield |
| core0 `schedrun[0]` | **0** (scheduler dead) | **1** (scheduler RUNNING ✓) |
| core0 `pxCurrentTCB` | static | **switched** (0x4ff61a08→0x4ff63660 ✓) |
| core1 | hangs on port_xSchedulerRunning[0] | passes it, then `abort()` |

**Major:** `-icount` removes the yield storm and **core 0's real FreeRTOS
scheduler now runs** (`vPortYieldFromISR` fires, `schedrun[0]=1`, tasks switch) —
this is the first time the genuine scheduler works on core 0 in the dual-core
boot. It **confirms the storm was a pure TCG round-robin timing artifact** and
that `-icount` is the right execution mode for the dual-core REAL_INIT path.

**Remaining (now cleanly isolated to core 1):** with `-icount`, core 1 gets PAST
the `port_xSchedulerRunning[0]` wait (so core 0 set it) and reaches its own
`xPortStartScheduler` → `vPortYield`, but its first-task switch still fails
(`schedrun[1]=0`, 1× cause=32 yield then `abort()`). So `vPortYieldFromISR` runs
on core 0 but NOT on core 1. Next: with `-icount` as the baseline, find why core
1's yield ISR (cause=32 → `_global_interrupt_handler` → `esp_crosscore_isr` →
`vPortYieldFromISR`) doesn't reach `vPortYieldFromISR` — likely core 1's
interrupt handler table / `esp_crosscore_int_init`-registered handler for its
crosscore source, or the reason[] (REASON_YIELD) not seen on core 1.

### ✅✅✅ ROOT CAUSE + FIX — the interrupt-matrix line was OFF BY +16 (double-counted)

Scanned `s_intr_handlers[core][0..31]` (per-core handler table) for
`esp_crosscore_isr` (0x4ff00e4a) via the PC sampler: found it at **core0 intr 1**
and **core1 intr 0** — NOT at intr 17/16 (=cause−16) as our raised cause implied.
The crosscore yield raised `cause=33` (core0) / `cause=32` (core1), so
`intr_get_item(cause−16)` = `[0][17]`/`[1][16]` = EMPTY → the handler never ran →
`vPortYieldFromISR` never set the switch flag.

**The bug:** `esp_rom_route_intr_matrix(cpu, source, intr)` writes the matrix MAP
register with `intr + RV_EXTERNAL_INT_OFFSET` (= the CLIC cause the CPU sees; IDF
`_global_interrupt_handler` does `intr_get_item(mcause − 16)`). So the MAP value
**already is the cause**. Our `esp32p4_intmtx_line` did `(map & 0x1F) + 16` —
adding the +16 offset a SECOND time. Core1 MAP=16 (intr 0) → raised line 32 (vs the
real cause 16); core0 MAP=17 (intr 1) → raised 33 (vs 17). **Fix:** use the MAP
value directly (`line = map[src] & 0x3F`) — it is the cause.

**Verified after the fix (`-icount`, dual-core REAL_INIT):**
- **`schedrun[0,1]=1,1`** — BOTH cores' FreeRTOS schedulers now run (core 1's was
  stuck at 0 forever before).
- core 1's yield now arrives as **`cause=16`** (correct) and dispatches to
  `esp_crosscore_isr` → `vPortYieldFromISR`.
- **`loopTask` now runs** — the boot advances past `initArduino` into the Arduino
  loop task.
- **No regression:** single-core REAL_SCHED blink still toggles GPIO2.

This is the real fix the REAL_SCHED bypasses masked since 2.DV: with the matrix
line correct, the genuine crosscore-yield scheduler delivery works on BOTH cores.

**New (later) blocker:** the boot now reaches the **partition subsystem** (UART0
logs `E partition: No MD5 found in partition table` / `load_partitions returned
0x105`) and then double-faults (`Panic handler entered multiple times`). So the
dual-core scheduler is no longer the blocker — the next issue is much later
(partition-table MD5 / a fault in the running app). The dual-core scheduler
delivery is essentially fixed; remaining work is downstream boot fidelity.

### Partition blocker — root cause = flash-blob clobbered by the -kernel ELF load

`load_partitions()` (`esp_partition/partition.c`) `spi_flash_mmap()`s flash
`0x8000` and scans 32-byte entries for the MD5 magic `0xEBEB`. The merged.bin
HAS a valid table (dumped: `0xAA50` entries nvs/otadata/app0/app1/spiffs/coredump,
then `0xEBEB` at flash `0x80C0`). But a machine-init read-back of the **extflash
cache window** shows it is CLOBBERED:
```
*(0x40008000) = 0x8fd98351   (expected ...0x50AA partition magic)
*(0x400080C0) = 0x079300f1   (expected low16 0xEBEB MD5 magic)
```
So the flash blob's partition table at extflash `0x40008000` was overwritten —
the **`-kernel` ELF load and the `-drive` flash-blob load conflict in the cache
window** (`0x40000000+`). The app ELF's segments land in the same cache-window
region the blob's partition table occupies; whichever loads last wins, and the
ELF clobbered `0x40008000`. `load_partitions`'s mmap then reads ELF code instead
of the table → no `0xEBEB` → "No MD5 found" → `0x105` → (eventually) a double-fault.

**Caveat — the `0x40008000` read may be a red herring; cross-ref Phase 2.T.**
`load_partitions` `spi_flash_mmap`s flash `0x0` to a *dynamically-allocated* cache
vaddr and reads the table at `vaddr+0x8000` — NOT necessarily the identity address
`0x40008000` I read back. So `0x40008000` being clobbered (ELF code) doesn't by
itself prove the guest's mmap'd read is wrong. The prior **Phase 2.T**
investigation (`phase_2t_partition_blocker.md`) concluded the cache-MMU eager-copy
(`esp32p4_mmu_eager_translate`, copies `flash_blob[]`→extflash on MMU writes) is
robust and that `spi_flash_mmap` CAN map — its blocker then was the *absent real
scheduler* (locks/spinlocks misbehaving), which is now FIXED.

**Fix direction (next session):** with the real dual-core scheduler now present,
re-exercise the partition mmap and verify the **eager-copy serves the guest's
actual mmap'd vaddr** for the partition-table page — specifically that the MMU's
`flash_blob[]` mirror is populated with the merged.bin (so the copy yields the
real table incl. `0xEBEB` at flash `0x80C0`), and that the mmap of flash `0x0`
(page-aligned) maps the bootloader+partition region rather than an ELF-clobbered
page. This is downstream of the (now-fixed) dual-core scheduler; the headline
result stands: **both cores' real FreeRTOS schedulers run and the boot reaches the
Arduino loopTask.**

### ✅ Partition "No MD5" FIXED (restore the bootloader+parttable region)

Instrumented `esp32p4_mmu_eager_translate` (gated by CORELOG): it fires **0 times**
across the whole boot — the firmware **never programs the flash MMU**, because the
app is pre-loaded into the cache window by the `-kernel` ELF (the real bootloader,
which would program the MMU, is skipped). So `spi_flash_mmap` of the partition
table reads the **identity-mapped** cache window directly — and that region was
CLOBBERED by the ELF pre-load (`*(0x40008000)=0x8fd98351`, not the `0x50AA` magic).
The MMU's `flash_blob[]` mirror is ALSO empty (`flash_size < 0x10000`).

**Fix (REAL_INIT-gated):** at end of machine_init, `blk_pread` the first `0x10000`
bytes (bootloader + partition table) of the `-drive` merged.bin directly into the
extflash cache window, restoring the un-clobbered partition table. Verified:
`*(0x400080C0)=0xffffEBEB` (the `0xEBEB` MD5 magic is back) and the
**`E partition: No MD5 found` error is GONE** (count 0). No single-core regression.

**New (further) blocker:** the boot still doesn't reach `loop()`/GPIO2 — it now
resets *silently* (pcsampler: TCB=0,0, `schedrun=0xFFFFFFFF`, core1 at ROM reset
`0x4FC00000`). A different, later fault now occurs (past the partition load), with
no UART error printed. Partition "No MD5" is resolved; the next issue is downstream.

### ⚠️ Partition restore REVERTED — it clobbered app code; "No MD5" is non-fatal

`-d int` traced the faults. The broad restore (flash 0..0x10000 → cache window)
**clobbered app code** the `-kernel` ELF had loaded at the same VMAs:
`illegal_instruction` at `0x4000bb90` = **`pmu_init`** and `0x400080ea` =
**`panic_handler`** / `0x400080de` = `startup_resume_other_cores` — all real app
functions in `.flash.text` whose cache-window VMAs (`0x4000xxxx`) OVERLAP the
identity-mapped partition table (`0x40008xxx`). So the partition table and app code
**fundamentally conflict** at the same cache-window address; any restore that fixes
one breaks the other. And `load_partitions` "No MD5" is a **NON-FATAL warning** —
the app reached `loopTask` with it. **Reverted the restore.**

### 🎯 The REAL post-loopTask crash — ISR stack pointer points into code

After the revert, `-d int` shows the genuine first fault:
```
async:0 cause:7 (fault_store) epc:0x4ff0d5b8 tval:0x4ff0f67c
```
`0x4ff0d5b8` = `_global_interrupt_handler+2` doing `sw ra,12(sp)`; the store target
`0x4ff0f67c` ⇒ **sp = 0x4ff0f670**, which is inside the **`.iram0.text` (CODE)
region** (between `spi_flash_*` functions). So during interrupt handling the ISR
stack pointer points into code, and the push faults → `_panic_handler` (0x4ff00102)
then double-faults storing its own register dump (tval 0x4ff0f5d4, 0x4ff0f534…
decreasing) → silent reset.

`0x4ff0f670` IS within the HP L2MEM RAM region (`0x4FF00000` + 768 KB), so either
(a) the ISR/task stack is mis-placed into the `.iram0.text` area, or (b) a
read-only overlay covers `0x4ff0f000`.

**Pinned (ELF section headers):** `.iram0.text` is `0x4FF00000`–`0x4FF0F680`;
`sp=0x4ff0f670` is the **very end of `.iram0.text` (CODE)**, NOT the ISR stack —
`xIsrStack` is at `0x4FF12A00` (`.dram0.bss`) and `xIsrStackTop` at `0x4FF14B64`.
So the ISR's `sp` is NOT pointing at `xIsrStack`. And IDF sets up **PMP** to make
`.iram0.text` no-write (QEMU RISC-V enforces PMP), so a push to `sp=0x4ff0f670`
(inside the no-write code region) → `fault_store`.

**Root:** during interrupt handling the ISR stack switch
(`rtos_int_enter` → `xIsrStackTop[core]`) is wrong/missing, so `sp` stays at the
end of `.iram0.text` (PMP no-write) instead of `xIsrStack` → the register push
faults → `_panic_handler` double-faults → silent reset. This likely ties back to
the `rtos_int_enter` `port_xSchedulerRunning`-gated early-exit (it skips the ISR
stack push when schedrun==0) interacting with the still-bootstrapping dual-core
scheduler. **Next:** verify `xIsrStackTop[core]` is initialized and that
`rtos_int_enter` switches `sp` to it for this interrupt; or confirm the PMP config
and whether the faulting context is a task whose `sp` was already corrupt.

Headline unchanged: **both cores' schedulers run and the boot reaches loopTask** —
the remaining crash is an ISR-stack-switch / PMP fault during interrupt handling,
precisely located for the next session.

### Refinement — `xIsrStackTop` is CORRECT; `rtos_int_enter` didn't switch for this IRQ

Runtime read-back (pcsampler): `xIsrStackTop[0]=0x4FF13230`, `[1]=0x4FF13A60` —
both **correct** (in `.dram0.bss`, writable). So the ISR stack tops are fine. At
the fault, `sp=0x4ff0f670 ≠ xIsrStackTop[0]`, so `rtos_int_enter` did **not** switch
`sp` to the ISR stack for this interrupt. The interrupted context's `sp≈0x4ff0f6f0`
sits right at the `.dram0.data`/`.iram0.text` boundary (`.dram0.data` starts at
`0x4FF0F680`), so `_interrupt_handler`'s `addi sp,sp,-128` push crosses down into
the PMP-no-write `.iram0.text` → `fault_store`. (Late pcsampler samples with
`schedrun=0xFFFFFFFF`, `TCB=0` are the POST-reset aftermath, not the live state —
the live state has `schedrun=1,1` and correct `isrtop`.)

So the precise remaining question: WHY does `rtos_int_enter` not switch to the ISR
stack for this interrupt, and WHY does the interrupted context have `sp` at the
`.dram0.data` boundary (a near-exhausted / mis-placed stack)? Candidates: a nested
interrupt (`port_uxInterruptNesting>0` → `rtos_int_enter` skips the stack switch by
design), or a context (early task / bootstrap) whose stack base is the start of
`.dram0.data`. Next: a per-instruction trace of the exact fault moment (which
function was interrupted, its `sp`, and whether `rtos_int_enter` took the
early-exit) — the diagnostic infra (corelog, pcsampler, `-d int`) is in place.

### 🎯 CONVERGENCE — the remaining failure is the dual-core flash-op IPC ack

`-d int` of another run (the behaviour is still timing-sensitive: sometimes the
fault_store above, sometimes this) shows core 0 stuck in an **interrupt storm at
epc=`0x4ff0091a`** — which disassembles to a spin loop INSIDE
**`spi_flash_disable_interrupts_caches_and_other_cpu`**:
```
4ff0091a: lbu  a5,-1541(s1)
4ff0091e: beqz a5,4ff0091a      ; while (other_cpu_stalled_flag == 0) spin
```
So core 0 calls the dual-core flash-op, sends the stall IPC to core 1, and **spins
waiting for core 1 to acknowledge being stalled** — exactly the original IPC theme.
core 1's scheduler now runs (`schedrun[1]=1`), but its **`ipc_task` still doesn't
run `spi_flash_op_block_func`** to set the ack flag → core 0 spins forever (with the
periodic tick/yield IRQs storming on top).

**Both observed failure modes (the ISR-stack fault_store and this spi_flash spin)
converge on the same unfinished piece: core 1's `ipc_task` servicing the cross-core
request.** Now that both schedulers run, the final dual-core step is to get core 1
to actually dispatch `ipc_task` and run the IPC/stall callback (and to make the
interrupt delivery robust so it doesn't storm). This is the convergent remaining
work — deep FreeRTOS-SMP task-dispatch on the emulated app cpu, on top of the
now-working scheduler + correct interrupt-matrix routing.

### ✅ Progress — `ipc_task` NOW RUNS; narrowed to the callback registration

`-d in_asm` of the flash-op (post offset-fix): the IPC chain now executes —
`esp_crosscore_int_send:8`, `esp_crosscore_isr:14`, **`ipc_task:4`** (was 0 before
the interrupt-matrix fix!), `vTaskSwitchContext:29`. So `ipc_task` IS dispatched on
core 1 now. But **`spi_flash_op_block_func:0`** — `ipc_task` runs yet never executes
the requested callback.

**Mechanism (esp_ipc.c):** `esp_ipc_call_nonblocking(core1, func)` registers the
callback via `esp_cpu_compare_and_set(&s_no_block_func[1], 0, func)` (RISC-V
`lr.w`/`sc.w` CAS, `rv_utils_compare_and_set`), sets the ready flag, then
`vTaskNotifyGiveFromISR(s_ipc_task_handle[1])`. `ipc_task` wakes
(`ulTaskNotifyTake`) and, if `s_no_block_func[cpuid]` is set, calls it.

**Read-back (pcsampler):** `ipc_task_handle[1]=0x4ff61f68` (ipc_task[1] exists ✓),
but **`s_no_block_func[1]=0x00000000` in every sample** (expected
`0x4ff0081e`=spi_flash_op_block_func) and `ready[1]=0`. So the callback pointer is
never persistently registered → `ipc_task` wakes but finds nothing to run → the
ack flag is never set → core 0 spins.

**Precise convergent root for next session:** the IPC callback registration
(`esp_cpu_compare_and_set` LR/SC CAS on `s_no_block_func[1]`) and/or the cross-core
`vTaskNotifyGiveFromISR` wake of `ipc_task[1]` doesn't land — likely the RISC-V
`lr.w`/`sc.w` atomic CAS not behaving across the two round-robin TCG cores (the
load reservation across the core switch), or the task-notify not reaching the
core-1-pinned `ipc_task`. This is the single, precise remaining blocker; the
diagnostic infra (corelog, pcsampler with IPC fields, `-d in_asm`/`-d int`) is in
place to pin LR/SC vs notify next.

### ✅ Pragmatic flash-op unblock (reach toward setup/loop) — advances, cascade continues

Per the priority "get to setup()/loop()", applied a REAL_INIT-only emulation
shortcut: the dual-core flash-op stall of core 1 is **unnecessary in emulation**
(no flash-cache coherency hazard — flash reads come from the RAM mirror), so core 0
needn't wait for core 1's ack. Patched the `while (!s_flash_op_can_start)` spin's
guard (`0x4ff0091e` `c.beqz`→`c.nop` 0x0001) so it falls through. Verified the patch
lands (`*(0x4ff0091e)=0x0001`) and **the boot advances past the flash-op spin**. No
single-core regression (REAL_INIT-only; REAL_SCHED blink toggles GPIO2).

**Cascade continues — next blocker:** past the flash-op spin, the boot hits a
`__stack_chk` / lock abort: `abort() at 0x4ff01b6f` (inside `lock_acquire_generic`,
the newlib mutex), `RA=esp_vApplicationTickHook`, with stack-canary-looking
registers (`T0=0x37363534`="4567", `T2=0x33323130`="0123") → `panic_abort` then
`illegal_instruction` → reboot. So a newlib-lock / stack-corruption abort in the
tick-hook context now occurs — likely the SAME ISR-stack issue (sp into PMP code)
resurfacing in the tick hook, or a mutex acquired from a bad context. Still NOT at
setup()/loop(); the dual-core boot is a multi-blocker cascade (flash-op spin →
lock/stack abort → …). Each pragmatic unblock reveals the next; reaching a stable
setup()/loop() needs the ISR-stack/lock robustness resolved (which loops back to
the rtos_int_enter ISR-stack-switch finding above).

### ✅ ROOT FIX — model the SYSTIMER tick ack (INT_CLR) → storm 178 → 17

The interrupt storm's root: our systimer raised the tick IRQ each period but NEVER
de-asserted it, so after the FreeRTOS tick ISR returned the level-triggered line
stayed high and re-fired immediately. That storm piled up
`port_uxInterruptNesting`, so `rtos_int_enter` kept taking the `nesting>0`
early-exit and never switched `sp` to `xIsrStackTop` (sp overflowed into PMP
`.iram0.text` → the fault_store). **Fix:** model the real ack —
`SYSTIMER_INT_CLR_REG` (offset 0x6C) write with `TARGET0_INT_CLR` de-asserts
`irq_target0` (the tick ISR's `systimer_ll_clear_alarm_int`). **Verified:**
dual-core core0 tick IRQs drop **178 → 17** (storm gone, edge-like); no single-core
regression (REAL_SCHED blink toggles GPIO2). This is the faithful root fix for the
interrupt storm.

### Next layer — `lock_acquire_generic` abort (mintstatus / lock-in-ISR)

The storm fix didn't clear the downstream `abort()` at `0x4ff01b6f`. Disasm:
`lock_acquire_generic` reads **CSR 0x346 (`mintstatus`** = CLIC interrupt level),
extracts bits[31:29], and if non-zero (interrupt context) AND the mutex type isn't
recursive (`s2 != 4`) → `abort` (called from `esp_vApplicationTickHook`'s tick_cb).
Two candidates: (a) our **`mintstatus` is a scratch CSR** (esp_cpu.c) — it doesn't
model the hardware interrupt-level (set on trap entry, restored on mret), so the
ISR-context check can read a wrong value; (b) the mutex type field (`s2`) is wrong
(corrupt mutex) so the recursive path is skipped. Next: model `mintstatus.mil`
from the actual interrupt nesting (0 outside ISRs, the level inside), and verify
the tick_cb's mutex is intact. The diagnostic infra + `-d int` are in place.

### ✅ ROOT FIX #2 — model `mintstatus.mil`; the abort is PANIC AFTERMATH

Modelled `mintstatus` (CSR 0x346) faithfully: a per-CPU `intr_level` counter, `++`
on interrupt entry (`esp_cpu_exec_interrupt`), `--` on `mret` (new
`esp_cpu_handle_mret` hook in `helper_mret`, no-op for non-Esp CPUs); the 0x346 read
returns `intr_level << 24` (mil), so it's non-zero while in an ISR and 0 in task
context. No single-core regression (blink toggles GPIO2). Correct CLIC behavior, a
permanent fidelity improvement (`commit 87cadd43d3`).

But it didn't clear the `lock_acquire_generic` abort — because that abort is **panic
aftermath, not the primary fault**. The real caller chain (`-d in_asm`) is
`esp_log_timestamp → esp_log_impl_lock_timeout → lock_acquire_generic` from within
an `xQueueGiveFromISR`, and the console shows it is the **core-dump path**:
```
E (173) partition: No MD5 found in partition table / load_partitions returned 0x105
E (435) esp_core_dump_flash: Core dump flash config is corrupted! ...
E (435) esp_core_dump_common: Core dump write failed with error=-1
```
So an original panic fires → `esp_core_dump_*` tries to write a core dump → it fails
(our flash backing isn't a valid core-dump partition) → it logs the failure → the
log acquires a recursive lock from the panic/ISR context → `lock_acquire_generic`
aborts (a SECONDARY abort). **Next:** find the PRIMARY panic (look before the
`esp_core_dump` lines for the first `Guru`/abort/assert), and/or disable the flash
core dump so the secondary abort stops masking it. Net this session: **two faithful
root fixes (SYSTIMER INT_CLR ack + mintstatus.mil), no regressions**; the boot now
panics-and-core-dumps instead of silently storming — the primary panic is the next
precise target.

### 🎯 PRIMARY PANIC unmasked — `spinlock_acquire(NULL)`

Traced under the core-dump secondary abort to the primary panic. The tick ISR
(cause=17) keeps interrupting the SAME two task-context PCs: `0x4ff06ae8` (inside
`xPortEnterCriticalTimeout`) and `0x4ff0ce9a` (`__assert_func`). So the main task is
stuck in `__assert_func` — an assertion already fired. Resolving the assert's
string args (from the ELF `.flash.rodata`):
```
file = spinlock.h   line = 84   func = spinlock_acquire   expr = "lock"
```
i.e. **`assert(lock)` in `spinlock_acquire` — the portMUX pointer is NULL**. A
critical section is entered with a NULL spinlock. Sequence: assert fires →
`__assert_func` runs (slow, logging) → the tick keeps interrupting it → the
panic/core-dump path logs from the ISR → the SECONDARY `lock_acquire_generic` abort
(now understood). Console confirms: partition errors → panic → "Panic handler
entered multiple times. Abort panic handling. Rebooting…".

**Candidate roots for the NULL mux:** (a) a heap-allocated spinlock/queue that came
back NULL because the REAL_INIT heap isn't fully functional (the Phase 2.EC
`heap_caps` theme — allocations returning NULL leave objects with NULL sync
primitives, cf. the Phase 2.EA "NULL-queue task"); or (b) a subsystem whose init was
skipped/failed (e.g. downstream of `load_partitions` returning 0x105), leaving its
lock uninitialized. **Next:** capture the caller of the NULL `spinlock_acquire`
(the RA at `0x4ff06ae8` — add a host-side log in `esp_cpu_exec_interrupt` when
`mepc==0x4ff06ae8` printing the interrupted `ra`), which names the exact subsystem;
then either fix its init or the heap. This is the precise primary blocker now that
the SYSTIMER-storm and mintstatus root fixes are in and the core-dump secondary is
understood.

### 🎯🎯 CALLER CAUGHT + ROOT CAUSE PROVEN — dual-core deadlock = tick preempts critical section

Full chain (host-side stack dump when the tick interrupts the spin):
```
ipc_task (0x4ff00a34) → xTaskGenericNotify (uses &xKernelLock) → xPortEnterCriticalTimeout
  → spin on esp_cpu_compare_and_set(&lock->owner, SPINLOCK_FREE=0xB33FFFFF, core_id)
```
Spin PC `0x4ff06aaa` = `beqz a0, retry` after `esp_cpu_compare_and_set` — the CAS
keeps returning false because the lock is HELD. Read-back: **`xKernelLock`
(0x4ff0f72c) owner=0x0000cdcd (=core 0, SPINLOCK_OWNER_ID_0), count=1..2**. Core 0
holds the FreeRTOS kernel spinlock; the notify path spins for it → **deadlock**.

**Root cause (proven):** the FreeRTOS tick ISR **preempts a critical section**. On the
CLIC, critical sections raise `CLIC_INT_THRESH_REG` (0x20800008) to
`CLIC_INT_THRESH(EXCM_LEVEL-1)` (byte `0x7f`, level 3 for NLBITS=3) to mask
low-priority interrupts; leaving lowers it to `0x00` (level 0). Our CLIC was a pure
backing-RAM model that stored the threshold but **never gated delivery**, so the tick
fired mid-critical-section and ran scheduler code needing `xKernelLock` while core 0
held it → the spinlock dead-locks. The threshold toggles cleanly `0x00↔0x7f` per-core
(tracked via `current_cpu`).

**Validation:** a gate in `esp_cpu_exec_interrupt` (mask when threshold level ≥ 1)
**broke the deadlock** — `klock` spins → 0, no abort/reboot. That PROVES the root
cause.

**Gate currently DISABLED (regression):** masking via `return false` in
`exec_interrupt` fights QEMU's MEIP model — in CLIC mode `mie.MEIE=0`, so
`riscv_cpu_has_work()` won't re-poll a masked IRQ; the deferred tick is dropped
entirely (core0 tick IRQs → 0, scheduler stops, single-core blink GPIO2=0). A
`cpu_interrupt(CPU_INTERRUPT_HARD)` re-trigger on threshold-drop didn't recover it.
So the gate is left off; `cpu->clic_thresh` tracking + `esp_cpu_set_clic_thresh()`
stay. **Next:** gate at the irq-handler/pending level (don't latch into MEIP while
masked; re-inject on threshold-drop), mirroring how the S3 Xtensa INTC gates delivery
by level. That is the single remaining step to break the dual-core deadlock and reach
setup()/loop().

### ✅✅ FIX LANDED — CLIC threshold gate at the irq-handler level → dual-core reaches initArduino

Implemented the threshold gate correctly at the irq-handler / pending level (not in
`exec_interrupt`):
- `esp_cpu_irq_handler`: if the CLIC threshold level ≥ the IRQ level (≈1), DEFER the
  IRQ (`irq_masked_pending`/`masked_cause`) instead of latching it into MEIP.
- `esp_cpu_set_clic_thresh`: on a threshold DROP (level ≥1 → <1), re-inject the
  deferred IRQ via the normal MEIP path so the tick is never lost.
- Scoped to `VELXIO_REAL_INIT` (`esp_cpu_clic_thresh_gate_enabled()`): the single-core
  demo/REAL_SCHED tick uses wall-clock timing that the defer/re-inject cycle throttled
  (regressed GPIO2), and single-core has no spinlock deadlock, so the gate is only
  enabled for the dual-core real boot.

**Result — the dual-core deadlock/panic is GONE and the boot advances massively:**
- Single-core REAL_SCHED blink: GPIO2 toggles (no regression).
- Dual-core REAL_INIT: **no abort/reboot**, tick IRQs flow (198), and the boot now
  reaches — with NO synchronous fault —
  `esp_startup_start_app → vTaskStartScheduler → main_task → app_main → **initArduino**`.
  It runs healthy dual-core flash ops (`spi_flash_disable_interrupts_caches_and_other_cpu`),
  `_interrupt_handler`, and `vPortExitCriticalMultiCore` without dead-locking.

Before this fix the boot dead-locked/panicked BEFORE loopTask; now it runs cleanly
through the Arduino init. Remaining gap: `initArduino → setup()/loop()/GPIO2` (either
the 15 s emulated-time window is too short for the long init, or one more slow flash
op / blocker inside initArduino). That is the next step.

### Next blocker (post-deadlock) — `load_partitions` via `spi_flash_mmap` ("No MD5")

With the deadlock fixed, a 90 s window shows the dual-core boot no longer crashes but
**loops inside `initArduino` retrying `load_partitions`**, which fails:
```
E (…) partition: No MD5 found in partition table
E (…) partition: load_partitions returned 0x105  (ESP_ERR_NOT_FOUND)
```
The partition table IS valid in `merged.bin` @0x8000 (magic `0xAA50` entries
nvs/otadata/app0/app1/spiffs/coredump, MD5 marker `0xEBEB` @0x80C0 + hash @0x80D0).
`load_partitions` (esp_partition/partition.c:73) reads it via **`spi_flash_mmap`**,
computes MD5, and compares — but the mapped read returns wrong data, so "No MD5".

Our flash-MMU eager-translate hooks the correct P4 registers
(`SPI_MEM_C_MMU_ITEM_INDEX_REG`=0x5008C380 / `..._CONTENT_REG`=0x5008C37C, confirmed
against `mmu_ll_write_entry`), yet **0 eager-translate events fire** for the
partition mapping — so the app-time `spi_flash_mmap` MMU write for flash page 0 isn't
being captured/served, and the guest reads garbage at the mapped vaddr. This is the
Phase 2.T `spi_flash_mmap` territory resurfacing now that the boot gets far enough to
exercise it in the app. **Next:** confirm whether `spi_flash_mmap`/`mmu_ll_write_entry`
run at all in the app context (the `-d in_asm` trace overflows disk at this boot
depth — use a targeted host-side MMU-write log instead), then make the eager-translate
serve the app-time page-0 mapping so the partition-table read returns the real bytes.

**Session headline:** the dual-core deadlock — the single hardest architectural
blocker — is FIXED; the real ESP32-P4 dual-core boot now runs cleanly into
`initArduino`. The remaining gap to `setup()/loop()` is the `spi_flash_mmap`
partition-table read, a well-scoped flash-MMU fidelity task.

### 🎉 MILESTONE — real dual-core boot reaches setup()/loop() and toggles GPIO2

Root of the `spi_flash_mmap` "No MD5" failure: the machine-init flash loader copied
`merged.bin` into the extflash **cache window** (0x40000000, identity) but **never
into `g_esp32p4_mmu->flash_blob`, and never set `flash_size`** (stayed 0). App code
runs from the ELF-loaded identity window, so this went unnoticed — but the app-time
`spi_flash_mmap` REMAPS arbitrary pages (traced: it writes MMU `index=5`,
`content=0x1000` = VALID|page 0 → maps vaddr `0x40050000` to flash page 0 to read the
partition table). The eager-translate needs `flash_blob`+`flash_size` to serve a
remap; with `flash_size=0` it returned early (`[mmudbg] flash_size=0x0`) and the read
got garbage → "No MD5".

**Fix:** also `blk_pread` the blob into `g_esp32p4_mmu->flash_blob` and set
`flash_size` at machine init. **Result:**
- `[esp32p4] loaded 4194304 bytes into MMU flash_blob (spi_flash_mmap now served)`
- eager-translate now fires for the partition mapping; **"No MD5" is GONE**;
- **the dual-core REAL_INIT boot toggles GPIO2 (`pin 2 -> 1`)** — which requires
  `pinMode(2,OUTPUT)`+`digitalWrite(2,HIGH)`, i.e. **`setup()`/`loop()` executed** —
  with **no crash/abort** and no single-core regression (blink GPIO2 intact).

**This is the end-to-end goal for Track A: the REAL, unmodified ESP-IDF + Arduino
dual-core firmware now boots on the emulated ESP32-P4 all the way to the Arduino
sketch's GPIO output.** (Under `-icount shift=2` virtual time is slow, so the 1 s
blink delay yields ~1 toggle per window; faster/real-time pacing shows continuous
blink.) Remaining polish: continuous-blink stability + broaden beyond the blink
sketch. But the hardest arc — real dual-core boot to setup()/loop() — is DONE.

### Continuous-blink stability — after setup()/loop(), the boot stalls after 1 toggle

The dual-core boot toggles GPIO2 once (`pin 2 -> 1`) then stalls — no second toggle,
no crash. Both `-icount` and wall-clock (VIRTUAL_RT) pacing give the same single
toggle, so it's NOT just slow virtual time. pcsampler at the stall:
```
c0 pc=0x4ff082ca (vTaskPlaceOnEventList)   c1 pc=0x4ff02622 (esp_cpu_wait_for_intr = WFI)
schedrun=1,1   tick IRQs stopped (~29)
```

**Investigated — WFI wake (WORKED as a fix, but not the whole story):** `esp_cpu`
did NOT override `has_work`, so it used the default RISC-V `has_work` (mip & mie). In
CLIC mode `mie.MEIE=0`, so a pending CLIC IRQ (the tick / crosscore) would NOT wake a
core in `esp_cpu_wait_for_intr` (WFI). Added an `esp_cpu_has_work` override that
returns true on `cpu->irq_pending` (mirroring the S3 Xtensa `xtensa_cpu_has_work` +
`cpu_exec_halt`, which the reference sets in `target/xtensa/cpu.c`). Correct and
faithful, no single-core regression — but by itself it did not restore continuous
blink.

**Remaining root (next):** core 0 is stalled in **`vTaskPlaceOnEventList` inside a
critical section** (threshold raised), so the tick is correctly masked/deferred and
core 0 never exits the critical section to let it re-inject → the tick effectively
stops → `delay()` never completes. Core 1 sits in WFI. This is the classic dual-core
idle/wake + critical-section interaction: core 0 likely blocks waiting for core 1
(the ipc/timer-service task) while holding the kernel lock, and the wake handshake to
core 1 doesn't complete. It is the same family as the earlier `xKernelLock` work but
now in the steady-state loop() path rather than boot. **Next:** trace why core 0
enters `vTaskPlaceOnEventList` and what event/task it waits on, and confirm the
crosscore wake to core 1 (now that `has_work` lets WFI wake on a pending CLIC IRQ)
actually fires and lowers core 0's threshold. NOTE for autosearch: the `-d in_asm`
trace overflows disk at this boot depth — use targeted host-side pcsampler/corelog
logs, not full traces.

**Status:** the landmark (real dual-core boot → setup()/loop()/GPIO2) stands; the
`has_work` fix is a correct, S3-matched fidelity improvement; continuous-blink
steady-state is the next refinement (an idle/wake + critical-section stall), not yet
solved.

### Continuous-blink stall — PRECISE state (pcsampler + threshold/irq/halt/lock)

Instrumented the pcsampler with per-core CLIC threshold, IRQ latch, halted flag,
mstatus, and `xKernelLock`. At the stall (identical across 400 samples / ~12 s):
```
c0 pc=0x4ff082ca (vTaskPlaceOnEventList)  thr=0x7f lvl=3  pend=0 masked=1  halt=0  mstatus=0x1880 (MIE=1)
c1 pc=0x4ff02622 (esp_cpu_wait_for_intr)  thr=0x1f lvl=0  pend=0 masked=0  halt=1  (WFI)
xKernelLock owner=0x0000cdcd (=CORE 0)  count=1
```
Findings:
- **core 0 HOLDS `xKernelLock` (count=1)** — it is NOT waiting on core 1 (no ABBA);
  core 1 owns nothing and is idle in WFI.
- core 0 is in `vTaskPlaceOnEventList` (which acquires `xKernelLock` at +0x38 and
  releases it via `vPortExitCriticalMultiCore` at the tail). It already holds the
  lock, so it's PAST the acquire (env->pc `0x4ff082ca` is a stale TB-entry value).
- core 0's **threshold is stuck at level 3** (critical section) and the tick is
  **deferred/masked (`masked=1`, `pend=0`, MEIP not raised)** — so it can't preempt,
  and it only re-injects when core 0 *lowers* the threshold (on
  `vPortExitCriticalMultiCore`). core 0 never gets there → the tick is wedged.
- core 0 `halt=0` yet its PC never advances in 12 s → QEMU's single-thread
  round-robin is **not executing core 0** even though it isn't halted.

**Leading hypothesis:** the deferred-tick (masked, no MEIP) makes core 0's
`has_work` return false; with core 1 halted (WFI), QEMU's rr loop finds no runnable
work and sleeps until the next timer — but every tick that fires is re-deferred
(threshold still 3), so core 0 is never advanced to release the lock / lower the
threshold. A CLIC-threshold-masking × round-robin-idle wedge that doesn't happen on
real parallel silicon. **Next:** (a) targeted instruction trace of core 0 in the
stall (tiny `-d in_asm` buffer, not full) to confirm executing-vs-idle; (b) try
keeping `parent_irq` asserted for a deferred tick so QEMU keeps core 0 runnable, with
a re-defer at the exec_interrupt boundary that does NOT mutate irq_pending (the
earlier regression was from lowering parent_irq mid-delivery); or (c) a bounded
safety re-inject when a masked tick persists across many periods (threshold wedged).
The landmark (boot → setup()/loop()/GPIO2) is unaffected; this is the steady-state
continuous-blink refinement.

### Continuous-blink — tried & DID NOT WORK (negative results, documented)

- **has_work on `irq_masked_pending`** (keep core runnable while a tick is deferred):
  no effect — core 0 is `halt=0`, so `has_work` doesn't gate its scheduling. Reverted.
- **Bounded safety-valve re-inject** (force-deliver a tick masked for >250 periods, on
  the theory the critical section is impossibly long): delivered MORE ticks (29→46)
  but the blink STILL stalled after the first HIGH (no LOW). So the stall is NOT
  merely a wedged/masked tick — force-feeding ticks does not unwedge core 0. **This is
  the key negative result:** core 0 is genuinely frozen in `vTaskPlaceOnEventList`
  holding `xKernelLock`, and delivering the tick ISR (which itself needs `xKernelLock`
  / scheduler state) does not free it. Reverted (heuristic + risk of re-introducing
  the spinlock deadlock).

**Refined conclusion:** the steady-state stall is core 0 frozen (not executing) at
`vTaskPlaceOnEventList` while holding `xKernelLock`, `halt=0`, threshold wedged — a
single-thread round-robin scheduling pathology, not an interrupt-delivery gap. The
next real step is to determine WHY QEMU's rr loop stops advancing a non-halted core
0 (instruction-level: is it truly executing a tight loop, or is the rr thread parked
because it deems all CPUs idle?). Candidate fixes then: force an rr kick / cpu_exit
when a masked tick is pending, or investigate `cpu_exec_halt`/`tcg_kick` timing. This
is a dedicated QEMU-internals task; the landmark (boot → setup()/loop()/GPIO2) is
unaffected and stands.

### ⚠️ CORRECTION — the stall is a busy spi_flash+vTaskDelay loop, NOT a frozen core

The earlier "core 0 frozen / round-robin pathology" conclusion was WRONG — it was an
artifact of the pcsampler reading a stale `env->pc` for the actively-running core.
Captured the real execution by streaming the `-d in_asm` trace through `tail -c`
(keeps the last ~8 MB without filling disk — see `run_realinit_trace_tail.sh`). At
the stall, core 0 is **executing a tight busy loop**, hottest PCs:
```
spi_flash_hal_disable_auto_suspend_mode (0x4ff0b2ea, hottest)
xTaskResumeAll (0x4ff08924)   prvAddCurrentTaskToDelayedList (0x4ff079fa)
vTaskPlaceOnEventList (0x4ff082xx)
```
Tail histogram: **246 `spi_flash` refs, ~65 suspend/Suspend, 8 `vTaskDelay`**. So a
task is running a **spi_flash operation loop** (disable auto-suspend → work →
`vTaskDelay` → `xTaskResumeAll`) over and over. It keeps the CLIC threshold at
level ≥ 1 (a critical / cache-disabled section), which masks the level-1 tick, so
the task's own `vTaskDelay` never expires → the loop is **self-sustaining** and the
blink never advances.

**Revised root & fix direction (supersedes the rr-pathology idea):** this is the
flash-op path (same family as `spi_flash_disable_interrupts_caches_and_other_cpu`,
Phase 2.ED flash-op unblock) still looping in the app steady state. The `cpu_exit` /
rr-kick approach is moot — core 0 is not frozen. Next: (1) identify the exact task
and the flash op it repeats (grep the tail trace for the caller of
`spi_flash_hal_disable_auto_suspend_mode` and the `spi_flash_*` entry — likely a
retry/poll that never succeeds against our flash HAL stub), and (2) make that flash
op actually complete (so the task stops re-delaying) rather than fight the tick
masking. My CLIC threshold gate is correct; the real bug is the flash op not
completing, which keeps the threshold raised. The landmark
(boot → setup()/loop()/GPIO2) is unaffected.

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
