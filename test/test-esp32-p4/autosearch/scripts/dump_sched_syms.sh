#!/usr/bin/env bash
# Phase 2.EC — addresses of the FreeRTOS scheduler state needed to dump why
# prvSelectHighestPriorityTaskSMP finds no runnable task for core 0.
set -u
ELF=/mnt/c/Desarrollo/velxio/test/test-esp32-p4/sketches/blink/build/esp32.esp32.esp32p4/blink.ino.elf
readelf -sW "$ELF" 2>/dev/null | awk '
$8=="pxReadyTasksLists" || $8=="uxTopReadyPriority" || $8=="pxCurrentTCBs" ||
$8=="xSchedulerRunning" || $8=="uxSchedulerSuspended" || $8=="pxDelayedTaskList" ||
$8=="xIdleTaskHandle" || $8=="uxCurrentNumberOfTasks" || $8=="xYieldPending" \
{ printf "%-24s 0x%s size=%s\n", $8, $2, $3 }'
