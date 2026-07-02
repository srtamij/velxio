#!/usr/bin/env bash
# Phase 2.ED diagnostic — resolve WHERE the delivered systimer tick IRQ (cause=17)
# vectors to. All 33 delivered hart=0 IRQs had cause=17 -> pc=0x4ff00268, yet
# INT_ST(0x70) was read 0 times, so SysTickIsrHandler never ran.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
ELF=$BASE/blink.ino.elf

# Locate the arduino-esp32 riscv toolchain.
for d in ~/.arduino15 /root/.arduino15 ~/Arduino /mnt/c/Users/*/AppData/Local/Arduino15 /mnt/c/Users/*/.arduino15; do
  f=$(find "$d" -name 'riscv32-esp-elf-objdump' 2>/dev/null | head -1)
  [ -n "$f" ] && { TC=$(dirname "$f"); break; }
done
OBJD=${TC:+$TC/riscv32-esp-elf-objdump}
NM=${TC:+$TC/riscv32-esp-elf-nm}
A2L=${TC:+$TC/riscv32-esp-elf-addr2line}
echo "toolchain dir: ${TC:-<none, using generic binutils>}"
: "${OBJD:=objdump}"; : "${NM:=nm}"; : "${A2L:=addr2line}"

echo "=== generic readelf: symbol count + vector-region symbols ==="
readelf -sW "$ELF" 2>/dev/null | awk 'NR>3{n++} END{print "sym lines:", n}'
echo "--- symbols with value 4ff002xx / 4ff003xx ---"
readelf -sW "$ELF" 2>/dev/null | awk '$2 ~ /^4ff00[23]/{print $2, $4, $8}' | head -40

echo "=== addr2line 0x4ff00268 ==="
"$A2L" -f -e "$ELF" 0x4ff00268 0x4ff00c40 2>/dev/null

echo "=== nm: SysTick / vector / dispatch ==="
"$NM" -n "$ELF" 2>/dev/null | grep -iE 'SysTickIsrHandler|_vector_table|_mtvt|_interrupt_handler|rtos_int_enter|_global_interrupt|xPortSysTick|_panic|handle_intr' | head -30

echo "=== objdump -d around 0x4ff00268 ==="
"$OBJD" -d --start-address=0x4ff00240 --stop-address=0x4ff002d0 "$ELF" 2>/dev/null | tail -40
