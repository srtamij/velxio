# Phase 2.DU — INTMTX + FROM_CPU device (resurrection step 2, iteration 1)

**Estado:** ✅ DONE w/ findings — implemented the **interrupt-matrix model**
(`0x500D6000`, MAP_REG capture) + the **FROM_CPU crosscore software-interrupt
device** (`0x500E5010`), replacing the `create_unimplemented_device` stubs.
Builds, runs, regression-clean (self-tests 19 OK). The device correctly
**captures the guest's MAP_REG writes and raises the mapped CLIC line on the
yield**, but the first task still does not launch — the iteration pins **two
new, precise blockers** (below). This is the hard structural core (the
"top structural gap"); reaching `loop()` is now a multi-iteration debug of
IDF's interrupt allocation + the CLIC CPU-model delivery.

Files:
- `third-party/qemu-lcgamboa/hw/riscv/esp32p4.c` — `esp32p4_install_intmtx()`
  (INTMTX MAP_REG store + FROM_CPU device + dynamic CLIC-line raise).

---

## SE INVESTIGÓ (TRM/datasheet-grounded)

Phase 2.DT proved the real scheduler starts but the first task never launches
because `vPortYield()` → `esp_crosscore_int_send()` writes the FROM_CPU reg,
which the model swallowed. The recon roadmap: model the INTMTX (so the model
learns which CLIC line `esp_intr_alloc` assigned each source) + a FROM_CPU
device that raises that line.

**Addresses verified against the IDF SOC headers (TRM-aligned) — and this
caught a recon error:**
- `DR_REG_INTR_BASE = DR_REG_HPPERIPH1_BASE + 0x16000 = 0x500C0000 + 0x16000
  = 0x500D6000` → **INTMTX base confirmed** (TRM Ch 12 "Interrupt Matrix").
  MAP_REG[source] = base + source*4. `SYSTIMER_TARGET0` = src **53** (0xd4),
  `CPU_INT_FROM_CPU_0` = src **79** (0x13c, MAP field [5:0]).
- `DR_REG_HP_SYS_BASE = DR_REG_HPPERIPH1_BASE + 0x25000 = 0x500E5000` (NOT
  `0x500C5000` as the recon claimed). `HP_SYSTEM_CPU_INT_FROM_CPU_0_REG =
  0x500E5010` (bit0 = yield trigger), inside the HP_SYSREG smart-stub region.
- CPU delivery (`esp_cpu.c`): raising CLIC line **N** sets `mcause = N`; in
  CLIC mode `PC = *(mtvt + N*4)`; IDF dispatches `intr_get_item(mcause-16)`.
  So **line to raise = `MAP[source] + 16`** (RV_EXTERNAL_INT_OFFSET; `intr` is
  the 0..31 number, confirmed by `1<<intr` in `intr_alloc.c:637`).
- `INT_MUX_DISABLED_INTNO = 6` (`intr_alloc.c:848`) — so a MAP value of 0 is
  **not** "disabled".

---

## Implementación

`esp32p4_install_intmtx(sys_mem, DEVICE(&ms->soc))`:
- **INTMTX** MMIO at `0x500D6000` (0x1000): `map[source]` store on write;
  logs MAP writes for src 53/79.
- **FROM_CPU** MMIO overlay at `0x500E5010` (priority 3 over the HP_SYSREG
  smart-stub): on write of bit0 → `raise line = map[79]+16`; on 0 → lower;
  read returns the pending bit (so `vPortYield`'s busy-wait can terminate).
- Dynamic line raise via `qemu_set_irq(qdev_get_gpio_in_named(cpu,
  "espressif-cpu-irq-lines", line), level)` (the line is data-dependent, so
  the cpu handle is stored and looked up lazily at raise time).

---

## NO funcionó / hallazgos (the two precise new blockers)

Running `VELXIO_REAL_SCHED=1`, the device logs:
```
[esp32p4.intmtx] MAP src 53 -> intr 0 (cpu line 16)     (SYSTIMER)
[esp32p4.intmtx] MAP src 79 -> intr 0 (cpu line 16)     (FROM_CPU)
[esp32p4.from_cpu] FROM_CPU_0=1 -> cpu line 16 RAISE
```
…and **no `do_interrupt` / trap fires** (`-d int` empty); first task still
not launched.

- **BLOCKER-A — the real `esp_intr_alloc` never routes SYSTIMER/FROM_CPU to a
  distinct line.** Both MAP[53] and MAP[79] are written **once, with value 0**
  (→ line 16), never a real distinct intr number. 0 ≠ disabled (=6), so this
  is the matrix's initial-clear, and the *real* allocation write never lands.
  Most likely cause: the Phase 2.L/2.K **bypass patches that swallow the
  `ESP_ERROR_CHECK` on `esp_crosscore_int_init` (`0x40009104`) and
  `vSystimerSetup` (`0x4FF070EC`)** let `esp_intr_alloc` *fail* without
  routing — the bypasses that unblocked earlier phases now **block the real
  interrupt allocation**. The recon flagged exactly this ("the alloc path must
  *succeed*, not merely have its error swallowed").
- **BLOCKER-B — raising the line produces no CPU trap.** Even the (wrong,
  line-16) raise yields no `do_interrupt`. Hypotheses: (1) CLIC-mode firmware
  enables interrupts via `mstatus.MIE` + per-line `clicintie` + `mintthresh`,
  **not** `mie.MEIE` — but the model's `esp_cpu` delivery (2.AK) gates on
  `mip.MEIP`/`mie.MEIE` (a CLINT concept the real firmware may never set);
  (2) `mstatus.MIE`/threshold not in the accepting state at that instant.
  Needs `esp_cpu.c` instrumentation of `mstatus`/`mie`/`mintthresh` at the
  raise.

---

## Lessons learned

1. **Datasheet/header cross-check caught two address errors** (the recon's
   HP_SYS base, and confirmed the INTMTX base) — verifying against the
   TRM-aligned SOC headers before coding saved wrong-address build cycles.
   (User's reminder to use the `specs/` TRM is exactly right for this work.)
2. **The bypass patches are now double-edged.** The same `ESP_ERROR_CHECK`
   swallows that got us to `app_main` now prevent the real `esp_intr_alloc`
   from routing the scheduler's own tick + yield. The resurrection requires
   *removing* those bypasses and making the alloc path genuinely succeed.
3. **The device infra is correct and reusable** — MAP capture + dynamic
   line-raise is the foundation; the remaining work is making the guest feed
   it real mappings (BLOCKER-A) and making the CPU accept the trap (BLOCKER-B).

## Próximas direcciones (2.DV)

1. **BLOCKER-A:** add an all-sources MAP-write log to confirm whether *other*
   sources route to real non-zero lines (isolating that 53/79 specifically
   fail). Then drop the `esp_crosscore_int_init` + `vSystimerSetup`
   `ESP_ERROR_CHECK` bypasses and make `esp_intr_alloc` succeed (model the
   registers/CLIC state it checks) so it writes real MAP lines.
2. **BLOCKER-B:** instrument `esp_cpu.c` accept-gate (`mstatus.MIE`, `mie`,
   `mintthresh`) at the FROM_CPU raise; make CLIC delivery honor
   `mstatus.MIE` + per-line `clicintie` instead of requiring `mie.MEIE`
   (TRM CLIC chapter + `interrupt_clic.h`).
3. Then heap → `heap_caps_malloc_default` + loopTask core-affinity patch →
   `setup()`/`loop()`/GPIO2.

## Reproduce
`bash test/test-esp32-p4/autosearch/scripts/run_realsched_measure.sh` then
`grep -iE "intmtx|from_cpu" /tmp/dt_stderr.txt` (WSL).
