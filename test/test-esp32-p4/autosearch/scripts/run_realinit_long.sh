#!/usr/bin/env bash
# Phase 2.ED — long-window dual-core real boot. After the CLIC threshold gate broke
# the spinlock deadlock, the boot reaches initArduino; give it a big time window to
# see whether initArduino -> setup()/loop()/GPIO2 is just slow or blocked.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
export VELXIO_REAL_SCHED=1 VELXIO_REAL_INIT=1 VELXIO_CORELOG=1
export ESP32P4_ROM_ELF=/mnt/c/Desarrollo/velxio/third-party/esp-rom-elfs/esp32p4_rev0_rom.elf
TMO="${1:-60}"
SHIFT="${2:-2}"
# Pass shift="off" to run WITHOUT -icount (wall-clock VIRTUAL_RT pacing) — needed to
# see the real-time 1 s blink cadence; -icount slows virtual time vs wall clock.
ICOUNT="-icount shift=${SHIFT}"
[ "$SHIFT" = "off" ] && ICOUNT=""
rm -f /tmp/rl_err.txt /tmp/rl_out.txt
timeout -s KILL "$TMO" "$QEMU" -accel tcg,thread=single -smp 2 $ICOUNT \
  -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  >/tmp/rl_out.txt 2>/tmp/rl_err.txt
echo "exit=$? (timeout=${TMO}s icount shift=${SHIFT})"
echo "=== abort/reboot? ==="
cat /tmp/rl_out.txt 2>/dev/null | tr -d '\000' | grep -aiE "abort|Rebooting|Guru" | head -2
echo "=== GPIO pin 2 toggles (loop reached if >0) ==="
grep -ac "pin 2" /tmp/rl_err.txt
echo "=== setup/loop/initArduino milestones ==="
grep -aoE "initArduino|_Z5setupv|_Z4loopv|loopTask" /tmp/rl_err.txt | sort | uniq -c
echo "=== tick IRQs ==="
grep -ac "hart=0 IRQ" /tmp/rl_err.txt
echo "=== last console (USB-serial/UART) lines ==="
cat /tmp/rl_out.txt 2>/dev/null | tr -d '\000' | grep -avE '^[0-9a-f]{8}:|esp32p4\.|corelog|ipc\]|mmu\]|thresh\]|klock|assertcaller|pcsample' | tail -12
