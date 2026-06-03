# Phase 2.EC — Load the real ESP32-P4 mask ROM (the any-sketch threshold)

**Status:** ✅ Milestone landed (ROM loads, `ets_rom_layout_p` fixed, real ROM
executes) · ⏳ next blocker pinned (real ROM cache-sync HW poll) · **uncommitted**

## Goal

Make the REAL ESP-IDF `do_system_init` run so heap_caps / esp_timer / queues
initialise for real → the threshold to running ANY P4 sketch without
per-firmware bypass patches (and the proper fix for the 2.EA/2.EB determinism
Heisenbug, since with real init all queues/tasks exist).

## What was investigated

Earlier (2.EC iter-1, the un-skip experiment) I dropped only the
`do_system_init` NOPs (`0x400091F2` / `0x4000923A`) under a `VELXIO_REAL_INIT`
gate and measured where the real init blocks. The REAL heap init ran
(`__esp_system_init_fn_init_heap → heap_caps_init`) but **faulted**:

```
cause:5 (load fault) epc:0x4000a214 tval:0x0002806b  → panic → esp_restart_noos
```

### Root cause (objdump of the app ELF + `-d in_asm,int`)

The fault is in `soc_get_available_memory_regions` (app `.flash.text`), inside
`s_prepare_reserved_regions` (`esp-idf/components/heap/port/memory_layout_utils.c`),
which reads the ROM memory-layout table because `ESP_ROM_HAS_LAYOUT_TABLE==1`
for P4 (not config-disableable):

```
4000a206: lui  a5,0x4fc20
4000a20a: lw   a5,-4(a5)     # a5 = *(0x4FC1FFFC) = ets_rom_layout_p   ← GARBAGE
4000a214: lw   a5,4(a5)      # *(garbage+4) → load access fault
```

`0x4FC1FFFC` lives in the **ESP32-P4 mask ROM** (`0x4FC00000`). It is
`ets_rom_layout_p`, the pointer to the ROM layout struct. We never loaded a
real ROM (the HP-ROM region is RAM filled with `ret`=0x00008067), so
`*(0x4FC1FFFC)` returned the ret-fill → garbage pointer → fault. The app's own
flash `.rodata` (`soc_memory_regions @0x4003ad24`) reads fine — only the **ROM**
was missing. On real silicon `*(0x4FC1FFFC)==0x4FC1D780` and
`*(0x4FC1D780+4)==0x4FF3FBA4` (`_dram0_rtos_reserved_start`).

### The real ROM is now available

`third-party/esp-rom-elfs/esp32p4_rev0_rom.elf` — the official Espressif mask
ROM ELF. Loading it is the **faithful** fix and the foundation for any-sketch
(real ROM functions instead of per-firmware patches) — exactly how Espressif's
own QEMU boots C3/S3 (which have no P4).

## What was implemented (this iteration)

All gated on `VELXIO_REAL_INIT` so the working REAL_SCHED blink is byte-identical
(zero regression). In `hw/riscv/esp32p4.c`:

1. **`esp32p4_load_rom_elf()`** (new helper, called after the PSRAM region,
   before CPU realize). Resolves the ROM via `$ESP32P4_ROM_ELF` →
   `qemu_find_file`. Two passes:
   - **Pass 1** `load_elf_ram_sym` → PT_LOAD segments (`.fixed/.init/.text`
     @0x4FC00000, `.rodata` @0x4FC1CA80).
   - **Pass 2** SECTION pass over **every PROGBITS section with file data**,
     skipping only the flash window (0x40000000). The key fix: the ROM's
     critical data is **PROGBITS but NOT `SHF_ALLOC`** (cold-reset state real
     silicon sets up) — filtering on ALLOC (my first try) dropped exactly:
     - `.rodata.interface @0x4FC1FFE4` (size 0x1C) whose last word
       `@0x4FC1FFFC = 0x4FC1D780` is `ets_rom_layout_p`, and
     - the `.data.interface.* / .data_*` ROM function-table pointers
       `@0x4FF3xxxx` (e.g. `.data.interface.cache @0x4FF3FFD8 = 0x4FC1F984`).
2. **Trampoline relocation** (REAL_INIT only): the `-kernel` reset trampoline
   (`ESP32P4_KERNEL_TRAMP_ADDR`) + mret stub were at `0x4FC1FFE0`/`0x4FC1FFB0`,
   inside ROM `.rodata`/`.rodata.interface` — they'd clobber `0x4FC1FFFC` at
   reset (`rom_add_blob_fixed_as` runs after machine_init). Moved to HP_SPM
   scratch RAM (`0x30100000` / `0x30100040`). `reset_pc` follows the var.
3. **16 MB PSRAM** region at `0x48000000` (CONFIG_SPIRAM=y) + the do_system_init
   un-skip (iter-1) retained.

## What worked ✅ (verified in running QEMU, `VELXIO_REAL_INIT=1`)

```
[esp32p4] REAL-INIT: loaded ROM ELF '...esp32p4_rev0_rom.elf' (255844 bytes)
[esp32p4] REAL-INIT: ROM section pass wrote 20 PROGBITS sections (incl. .rodata.interface @0x4FC1FFE4)
[esp32p4] REAL-INIT: *(0x4FC1FFFC) ets_rom_layout_p = 0x4fc1d780     ← was 0x00008067/0x28067 garbage
```

- The **original blocker is gone**: no more `0x4000a214` load fault, no reboot
  loop. `ets_rom_layout_p` resolves to the real `0x4FC1D780`.
- The **real ROM now executes** (`Cache_Invalidate_All`, `Cache_Sync_Items`,
  `call_start_cpu0`, `esp_rtc_init`, `pmu_init` run as real ROM code, not
  ret-stubs).

## What did NOT work / next blocker ⏳ (the strategic finding)

Loading the full real ROM makes the **entire real ROM early boot run** — and
each ROM HW-management routine polls a real-silicon status bit we only partially
model. The **first** one hangs:

```
0x4fc10508: lui  a4,0x3FF10        # a4 = 0x3FF10000  (HP_CPU_PERIPH / L1 cache)
0x4fc1050c: lw   a5,152(a4)        # read *(0x3FF10098)
0x4fc10510: andi a5,a5,16          # bit 4
0x4fc10512: beqz a5,0x4fc1050c     # wait bit4=1 (cache sync done) — never set → spin
```

This is `Cache_Sync_Items` waiting on the L1 cache "sync done" bit. There is an
EXISTING smart-override `{0x3FF10000, 0x098, 0x10, SMART_FIXED}` that should
force bit 4, and the cache stub is installed at priority 2 (wins over the
HP_CPU_PERIPH catch-all) with `s->base==0x3FF10000` — yet the poll spins (the PC
re-translates repeatedly). The override was **never exercised before** because
`Cache_Sync_Items` was a ret-stub pre-ROM; under real-ROM it surfaces. Exact
mechanism (override-not-applied vs TB-invalidation) still under investigation.

### The strategic fork (decision needed)

Running the full real ROM boot is a **large surface**: this cache-sync poll is
the *first* of many real-ROM HW status polls (cache, PMU, PLL/clock, regi2c,
MSPI…), most managing silicon details that are **no-ops under emulation** (the
cache is transparent — we model RAM directly).

Two paths:
- **(A) Full real ROM boot** — model each HW status bit the real ROM polls until
  its boot completes. Maximally faithful; multi-iteration, possibly large.
- **(B) Hybrid (recommended)** — keep the real ROM **data + computational
  functions** (this fixed `ets_rom_layout_p` + the function tables — the actual
  goal for `soc_get_available_memory_regions`), but **ret-stub the handful of
  ROM HW-management routines** (cache sync/invalidate, PMU/clock polls) that
  spin on unmodeled silicon. Safe in emulation (cache/PLL are transparent),
  bounded, and consistent with the project's incremental-patch philosophy. Gets
  "any sketch boots" sooner; full-ROM-boot fidelity can come later.

## Files touched

- `hw/riscv/esp32p4.c`: `esp32p4_load_rom_elf()` + REAL_INIT trampoline
  relocation + PSRAM region + do_system_init un-skip. **Uncommitted.**
- `autosearch/scripts/run_realinit_measure.sh`: sets `ESP32P4_ROM_ELF`, ROM-load
  confirmation + hang-loop dump. **New, uncommitted.**

## Verification

`bash autosearch/scripts/run_realinit_measure.sh` →
section 0 must print `ets_rom_layout_p = 0x4fc1d780` and `wrote 20 PROGBITS
sections`; section 2 (sync exception) must be empty (no `0x4000a214` fault).
Working REAL_SCHED blink (no `VELXIO_REAL_INIT`) unchanged — gate is off by
default.

## Next steps

1. Resolve the cache-sync poll — path (B): ret-stub `Cache_Sync_Items` /
   `Cache_Invalidate_All` (+ siblings) at their ROM entry addresses under
   REAL_INIT, OR path (A): fix/extend the `0x3FF10098` bit-4 override so the
   real read returns ready.
2. Iterate the next real-ROM blockers (PMU/clock/regi2c) the same way until the
   real `do_system_init` reaches `soc_get_available_memory_regions` (now
   unblocked) → real heap → real scheduler → loop() with NO per-firmware stubs.
