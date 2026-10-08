#!/bin/bash
# Consolidated final benchmark for the 60 FPS feasibility study.
# All runs are SEQUENTIAL. Depth-1/depth-2 pairs are interleaved so that
# thermal/clock drift affects both arms equally.
cd "$(dirname "$0")/../probes" || exit 1

echo "==================================================================="
echo " 60 FPS output benchmark  --  $(date '+%Y-%m-%d %H:%M:%S')"
echo " host: $(sysctl -n machdep.cpu.brand_string)  |  $(sw_vers -productVersion)"
echo " NOTE: other work on this machine perturbs results. Absolute values"
echo "       shift a few percent run to run; ratios are stable."
echo "==================================================================="

echo ""
echo "### A. SOURCE RATE SWEEP @ 1920x1080 (depth 1 = lock-step, depth 2 = pipelined)"
for round in 1 2; do
  echo "  -- round $round --"
  for fps in 23.976 24 25 29.97 50 59.94; do
    for d in 1 2; do
      printf "  %-7s d%d  " "$fps" "$d"
      ./vtofq 1920 1080 "$fps" 240 "$d" 2>&1 | grep -E "^ *[0-9]+ out frames|^RESULT" | tr '\n' ' ' | sed 's/  */ /g'
      echo ""
    done
  done
done

echo ""
echo "### B. RESOLUTION SWEEP, 24 -> 60 (depth 1 vs 2)"
for res in "1280 720 240" "1920 1080 240" "3840 2160 120"; do
  set -- $res
  for d in 1 2; do
    printf "  %sx%s d%d  " "$1" "$2" "$d"
    ./vtofq "$1" "$2" 24 "$3" "$d" 2>&1 | grep -E "^ *[0-9]+ out frames|^RESULT" | tr '\n' ' ' | sed 's/  */ /g'
    echo ""
  done
done

echo ""
echo "### C. LOW-LATENCY PATH (30 -> 60, exact 2x)  [hard-capped at 1080p]"
for res in "1280 720" "1920 1080"; do
  set -- $res
  printf "  %sx%s  " "$1" "$2"
  ./vtll "$1" "$2" 120 2>&1 | grep -E "^RESULT|^FAIL" | sed 's/  */ /g'
done

echo ""
echo "### D. CONCURRENCY SCALING (separate processes, 1080p 24->60)"
for n in 1 2 3 4; do
  echo "  -- $n concurrent process(es), depth 2 --"
  for i in $(seq 1 $n); do
    ( ./vtofq 1920 1080 24 240 2 2>&1 | grep "^RESULT" | sed 's/^RESULT/RESULT/' ) &
  done
  wait
done

echo ""
echo "==================================================================="
echo " done $(date '+%H:%M:%S')"
echo "==================================================================="
