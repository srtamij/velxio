#!/usr/bin/env bash
# Phase 2.EL — N wall-clock (no icount) runs; summarize blink + abort signature.
set -u
cd "$(dirname "$0")"
N="${1:-3}"
TMO="${2:-20}"
for i in $(seq 1 "$N"); do
  bash run_realinit_fast.sh "$TMO" >/dev/null 2>&1
  H=$(grep -ac "HIGH" /tmp/rf_out.txt)
  L=$(grep -ac "LOW" /tmp/rf_out.txt)
  A=$(tr -d '\000' </tmp/rf_out.txt | grep -acE "should not return|Guru|abort")
  P=$(tr -d '\000' </tmp/rf_err.txt | grep -ac "pin 2 -> 1")
  echo "WRUN$i: serialHIGH=$H serialLOW=$L aborts=$A gpioHIGH=$P"
done
echo "ALLDONE"
