#!/usr/bin/env bash
# Rebuild qemu-system-riscv32 after editing esp32p4.c / esp32p4_systimer.c.
set -e
BUILD=$HOME/qemu-p4-build
cd "$BUILD"
# Ninja build dir uses the configured source tree; just rebuild the target.
ninja qemu-system-riscv32 2>&1 | tail -25
echo "=== built ==="
ls -la --time-style=+%H:%M:%S "$BUILD/qemu-system-riscv32"
