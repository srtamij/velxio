#!/usr/bin/env bash
# Phase 2.EI — N trial runs of the real dual-core boot after the deferred-cause
# bitmap fix; summarizes ticks delivered / GPIO toggles / panics per run.
set -u
cd "$(dirname "$0")"
N="${1:-3}"
TMO="${2:-20}"
for i in $(seq 1 "$N"); do
  bash run_realinit_long.sh "$TMO" 2 >/dev/null 2>&1
  T=$(tr -d '\000' </tmp/rl_err.txt | grep -ac "cause=18")
  C=$(tr -d '\000' </tmp/rl_err.txt | grep -ac "cause=17")
  H=$(tr -d '\000' </tmp/rl_err.txt | grep -ac "pin 2 -> 1")
  L=$(tr -d '\000' </tmp/rl_err.txt | grep -ac "pin 2 -> 0")
  P=$(tr -d '\000' </tmp/rl_out.txt | grep -aicE "Guru|panic")
  echo "RUN$i: tick18=$T xc17=$C HIGH=$H LOW=$L panics=$P"
done
echo "ALLDONE"
