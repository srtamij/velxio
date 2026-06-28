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
