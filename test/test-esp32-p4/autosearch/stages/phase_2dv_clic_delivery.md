# Phase 2.DV — CLIC interrupt delivery for real firmware (the trap now fires)

**Estado:** ✅ DONE w/ findings — fixed the **CLIC interrupt-delivery gate**
(`target/riscv/esp_cpu.c`): the real scheduler's yield/tick interrupt **now
actually traps into the guest** (previously it never did). This exposes the
last blocker as **BLOCKER-A** (the IDF interrupt allocator routes SYSTIMER +
FROM_CPU to the *same* line, causing an interrupt storm because the wrong ISR
runs and never clears the source).

Files: `third-party/qemu-lcgamboa/target/riscv/esp_cpu.c` (CLIC delivery bridge).

---

## SE INVESTIGÓ — the decisive diagnostic

Phase 2.DU's FROM_CPU device raised the mapped CLIC line but produced no trap.
Enabling `ESP_CPU_IRQ_DEBUG` showed exactly why:
```
[esp_cpu.irq_handler] line=16 level=1 accept=1 mstatus=00000008 (MIE=1) mie=00000000 irq_pending=0
[esp_cpu.exec_interrupt] #1 request=00000002 accepted=0 irq_cause=16 mtvec=4ff00003
```
- `esp_cpu_irq_handler` **accepts** (it only gates on `mstatus.MIE`, which is
  set) → latches `irq_pending`, raises the parent `IRQ_M_EXT`.
- But `esp_cpu_exec_interrupt` → `parent_exec_interrupt(...)` returns
  **`accepted=0`**: the base RISC-V CPU gates the `MEIP` delivery on
  **`mie.MEIE` (bit 11) = 0**. **CLIC-mode firmware enables interrupts via
  `mstatus.MIE` + per-line `clicintie`, NOT `mie.MEIE`** (a CLINT concept).
  The 2.AK guest-ISR demos set `mie.MEIE` by hand; the *real* firmware never
  does → every scheduler yield/tick was silently dropped by the parent gate.

---

## SÍ funcionó — the fix

In `esp_cpu_exec_interrupt`, while a pending IRQ is latched and `mstatus.MIE`
is set in CLIC mode (`mtvec[1:0]==3`), **temporarily assert `mie.MEIE`** around
the `parent_exec_interrupt` call so the parent performs the full trap entry
(saves `mepc`, updates `mstatus` MPIE/MIE/MPP); the CLIC `mcause`+`pc` are then
overridden by the existing 2.S dispatch (`pc = *(mtvt + cause*4)`). `mie` is
restored immediately so the guest never observes the transient. ~17 LOC.

**Result (measured):** the trap now fires for the real firmware —
```
riscv_cpu_do_interrupt: hart:0, async:1, cause:0x0b (m_external), epc:0x4ff00f26
```
(repeating). Regression-clean: self-tests 19 OK, and the Track-B demos are
unaffected (they already set `mie.MEIE`, so the bridge is a redundant no-op
for them). This is a **general, correct CPU-model fix** — CLIC delivery should
not require `mie.MEIE` — that benefits every future real-firmware interrupt.

---

## NO funcionó / hallazgo — BLOCKER-A (the live blocker now)

With delivery fixed, REAL_SCHED now shows an **interrupt storm**: the same
`m_external` trap re-fires forever at `epc:0x4000925a` (`start_cpu0` /
`esp_crosscore_int_send` region). The interrupt is delivered but **never
cleared** → the ISR that runs is **not** `esp_crosscore_isr`.

Root cause = **BLOCKER-A from 2.DU, now acute:** the IDF `esp_intr_alloc`
routes **both** SYSTIMER (src 53) **and** FROM_CPU (src 79) to **`intr 0`**
(→ line 16). So `intr_get_item(0)` dispatches a single (wrong) handler for both
— the FROM_CPU yield lands on (likely) `SysTickIsrHandler`, which never writes
`HP_SYSTEM_CPU_INT_FROM_CPU_0_REG = 0`, so the level stays asserted → storm.
The allocator gives degenerate `intr 0` for everything because its free-line
tracking / per-core state isn't valid under the bump-allocator + skipped heap
init + the `ESP_ERROR_CHECK` bypasses that mask its failures.

---

## Lessons learned

1. **`ESP_CPU_IRQ_DEBUG` is the right lens** for delivery bugs — it separated
   "handler accepts (mstatus.MIE)" from "parent rejects (mie.MEIE)", pinning
   BLOCKER-B precisely in one run.
2. **CLIC ≠ CLINT for the enable gate.** The model's MEIP/MEIE delivery path is
   CLINT semantics; real CLIC firmware uses `mstatus.MIE` + `clicintie`. The
   bridge reconciles them without a full CLIC-delivery rewrite.
3. **Fixing B exposed A.** Order matters: until the trap could fire, the
   allocator bug was invisible (idle); now it's a visible storm — which is
   strictly more debuggable.

## Próximas direcciones (2.DW)

**BLOCKER-A — make `esp_intr_alloc` assign distinct lines + register the right
handlers.** Options, cheapest first:
1. Confirm which handler `intr_get_item(0)` returns (instrument / read the
   vector_desc table) — verify the storm is a SysTick/crosscore collision.
2. Make the allocator's state valid: the real fix is to stop bypassing
   `esp_crosscore_int_init`/`vSystimerSetup` *and* give `esp_intr_alloc` a
   working environment (heap + the regs it probes) so it picks distinct free
   lines. Likely needs the `heap_caps` redirect + possibly UNICORE (the
   2-core allocator state aliases under our 1-core model).
3. If the guest allocator stays intractable, a model-side shim: have the
   INTMTX assign a distinct fallback line per source when the guest writes a
   colliding/zero map (documented divergence) so FROM_CPU + SYSTIMER reach
   their own handlers. Then GPIO2 / loop().
