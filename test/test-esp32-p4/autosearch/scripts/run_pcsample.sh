#!/usr/bin/env bash
# Phase 2.EB — PC-sample a DIRECT (untraced) REAL_SCHED run to find the
# busy-looping task that starves loopTask. No -d (so timing matches the
# representative run); sample the live PC via the QEMU monitor.
set -u
BASE=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4
QEMU="$HOME/qemu-p4-build/qemu-system-riscv32"
SOCK=/tmp/eb_mon.sock
export VELXIO_REAL_SCHED=1
rm -f "$SOCK" /tmp/eb_pc.txt

timeout -s KILL 14 "$QEMU" -M esp32p4 -kernel "$BASE/blink.ino.elf" \
  -drive file="$BASE/blink.ino.merged.bin",if=mtd,format=raw -nographic \
  -monitor unix:"$SOCK",server,nowait >/tmp/eb_out.txt 2>/tmp/eb_err.txt &
QPID=$!

sleep 5    # let it get past boot into steady-state (the starvation)
for i in 1 2 3 4 5 6 7 8; do
  echo "info registers" | socat - UNIX-CONNECT:"$SOCK" 2>/dev/null \
    | grep -ioE "pc[ ]+0x[0-9a-f]+" >> /tmp/eb_pc.txt
  sleep 0.7
done
kill -9 $QPID 2>/dev/null; wait 2>/dev/null

echo "=== live PC samples (the hot/busy-loop PC) ==="
cat /tmp/eb_pc.txt 2>/dev/null
echo "=== unique PCs + counts ==="
grep -oiE "0x[0-9a-f]+" /tmp/eb_pc.txt 2>/dev/null | sort | uniq -c | sort -rn
echo "=== GPIO pin 2 toggles this run (should be >0 if not starved) ==="
grep -cE "pin 2 ->" /tmp/eb_err.txt
