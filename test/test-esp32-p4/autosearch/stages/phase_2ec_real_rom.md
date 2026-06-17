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

## Continuation — full-fidelity real-ROM boot (user chose path A)

User picked **full fidelity** (model each real-ROM HW poll) + committed the
milestone (parent `974e335`, submodule `90cac88`). Then, continuing:

### Correction: the cache-sync poll was a RED HERRING
A `VELXIO_DBG_CACHE` probe in the smart-stub read proved the existing override
`{0x3FF10000,0x098,0x10,SMART_FIXED}` **IS applied** — `cache 0x098 read ->
override 0x10`. The `Cache_Sync_Items` poll exits fine; `-d in_asm` just stops
emitting NEW translations there, so the tail *looked* like the hang. Execution
actually proceeded into app code.

### Real blocker #2 (self-inflicted): trampoline clobbered `PMU_instance`
The real hang was `pmu_init` (app `0x4000bb90`), which calls `PMU_instance` —
linked at **`0x30100000`** (the app's `.tcm.text` in HP_SPM). My REAL_INIT
trampoline relocation put the trampoline AT `0x30100000`, overwriting it. The
workflow plan's "HP_SPM, nothing else uses it" was wrong: the app links
`.tcm.text`(0x30100000, PMU_instance) + `.tcm.data`(0x3010000c) there.
**Fix:** relocate the trampoline into the FREE ROM gap between `.rodata` (ends
`0x4FC1FC18`) and `.rodata.interface` (starts `0x4FC1FFE4`) →
`tramp 0x4FC1FD00 / mret 0x4FC1FD40` — ROM space no sketch uses. Verified:
`pmu_init` now passes, `esp_mmu_map`(×27) + `spi_flash_init_chip_state` run.

### Real blocker #3 (RESOLVED): RTC slow-clock calibration spin
Hung in `select_rtc_slow_clk` → `while (cal_val == 0)` (clk.c): `rtc_clk_cal`
returned 0 because the **TIMG0 RTC calibration value read 0**. Per the P4 IDF
`rtc_time.c`, `rtc_clk_cal_internal` writes `RTC_CALI_MAX` (RTCCALICFG@0x68
bits[30:16]) + START, polls `RTC_CALI_RDY` (0x68 bit15), reads the XTAL-cycle
count from `RTCCALICFG1`@0x6c bits[31:7]. The old `0x080` override (smart-stub
**and** `esp32p4_timg_read` `case 0x80: return 0x1`) forced `RTC_CALI_TIMEOUT`
(0x80 bit0) = "calibration timed out" → cal_val=0.
**Wrinkle:** the real TIMG device (`esp32p4_timg.c`) overlays the smart stub at
**priority 3**, so the model must live in `esp32p4_timg_read()`, not the stub.
**Fix (`esp32p4_timg.c`):** `case 0x68` → OR-in `RTC_CALI_RDY`, preserve MAX;
`case 0x6c` → `RTC_CALI_VALUE = MAX*294` (RC_SLOW ~136 kHz vs 40 MHz XTAL),
placed in bits[31:7]; `case 0x80` → return 0 (no timeout). Removed the dead
smart-stub override/special-case. (294 is the RC_SLOW default; 32K_XTAL/RC32K
need a CLK_SEL-aware ratio — documented follow-up.)
**Result — a big leap:** real `do_system_init` now runs `init_heap` →
**`heap_caps_init` (45 BBs)** → **`esp_timer_init`** → **`init_newlib`** →
`esp_mmu_map`×27 → `spi_flash_init_chip_state`. Trace 778 → **43k+ lines**.
`soc_get_available_memory_regions` (the original 2.EC blocker) is **passed** —
the real heap, esp_timer, and newlib all initialise.

### Real blocker #4 (current): flash-HAL clock-divider assert
`abort()` from `get_flash_clock_divider` (app `0x4000948C`). Exact assert
(recovered from the app ELF rodata `0x40033EEC`, tag `flash_hal`):

> `E (%lu) %s: Target frequency %dMHz higher than src %dMHz.`

The function reads `cfg->src_mhz` (off +52) and `cfg->target_mhz` (off +48); if
`src < target` it logs + `abort()` (a flash divider must be ≥ 1). `src` comes
from `spimem_flash_ll_get_source_freq_mhz()` which on P4 IDF is a **hardcoded
`return 80`**, so the configured flash target is being read as **> 80 MHz**
(either a 120 MHz flash config, or `cfg->target_mhz` is garbage because an
earlier MSPI clock-tree init step we don't model didn't populate it). The
USB-Serial/JTAG console echo (`[esp32p4.usb_serial_jtag] TX …`) produced no
bytes — IDF's `usb_serial_jtag_write` drops output when `is_connected()` reads
false (our device reports not-connected), so the panic banner never reaches the
FIFO; recovered the assert statically instead.
**This is a real-silicon flash-timing check that is meaningless under emulation**
(we back flash as RAM via the eager MMU). **Next:** instrument the actual
`target`/`src` values (register/PC-level), then either model the MSPI clock
source so `src ≥ target`, or recognise the check as a no-op for emulation.

## Next steps (full-fidelity grind, in order)

1. Capture the blocker-#4 panic message (mux USB-Serial/JTAG TX → stderr) and
   fix the flash-clock-divider assert.
2. Iterate the next real-init blockers the same way until real `do_system_init`
   completes → `vTaskStartScheduler` → loop() with NO per-firmware stubs.

**Uncommitted since `974e335`:** trampoline-gap relocation (`0x4FC1FD00`),
cache-debug removal, TIMG RTC-calibration model (`esp32p4_timg.c`), smart-stub
override cleanup. Commit when asked.
