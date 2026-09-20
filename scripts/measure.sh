#!/bin/bash
# Measure one benchmark variant three ways: timing, counters, profile.
#
#   scripts/measure.sh <benchmark-dir> <N>
#     benchmark-dir : a bm_* directory containing run_benchmark.py
#     N             : the -n value (100 for nbody variants, 20 for pyflate)
#
# N MUST match the baseline for that benchmark, or the instruction counts
# describe a different amount of work and the comparison is meaningless.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/env.sh"

DIR=$1
N=$2

# A bare name works as well as a path: "bm_nbody" resolves under $BM and
# "bm_nbody_opt1" under benchmarks/. $BM is set by env.sh INSIDE this script,
# so writing "$BM/bm_nbody" on the command line expands to "/bm_nbody" unless
# the caller happens to have exported it -- which is a trap, not a feature.
if [ ! -f "$DIR/run_benchmark.py" ]; then
  for c in "$BM/$DIR" "$ROOT/benchmarks/$DIR" "$ROOT/$DIR"; do
    if [ -f "$c/run_benchmark.py" ]; then DIR=$c; break; fi
  done
fi

NAME=$(basename "$DIR")
OUT="$ROOT/results/$NAME"

BENCH="$DIR/run_benchmark.py"
if [ ! -f "$BENCH" ]; then
  echo "no run_benchmark.py for '$1'"
  echo "  tried: $1"
  echo "         $BM/$1"
  echo "         $ROOT/benchmarks/$1"
  echo "  available: $(ls "$ROOT/benchmarks" 2>/dev/null | tr '\n' ' ')"
  exit 1
fi
mkdir -p "$OUT"

echo "=============================================="
echo "[*] $NAME   (-l 1 -w 1 -n $N)"
echo "=============================================="

# Everything below is piped through tee, and a pipeline's status is the LAST
# command's -- tee always succeeds. Without pipefail a failed pyperf run writes
# an error message into timing.txt, exits 0, and the caller carries on as if it
# had data. pyperf also refuses to overwrite an existing JSON, so a re-run of a
# variant fails on its second line unless the old one is cleared first.
set -o pipefail
rm -f "$OUT/${NAME}.json"

echo "[1/3] timing (pyperf manager, 20 processes, own calibration)..."
$PY -u "$BENCH" -o "$OUT/${NAME}.json" 2>&1 | tee "$OUT/timing.txt" \
    || { echo "[!] timing run failed -- see $OUT/timing.txt"; exit 1; }
grep -q "Mean +- std dev" "$OUT/timing.txt" \
    || { echo "[!] timing produced no mean -- $OUT/timing.txt"; exit 1; }

echo "[2/3] counters (fixed work; 1 vCPU cannot multiplex more than one group)..."
: > "$OUT/stat.txt"
for G in "task-clock,context-switches,page-faults,cycles,instructions" \
         "cache-references,cache-misses" \
         "branches,branch-misses"; do
  echo "=== $G ===" | tee -a "$OUT/stat.txt"
  perf stat -r 3 -e "$G" -- \
      $PY -u "$BENCH" --worker -l 1 -w 1 -n "$N" 2>&1 | tee -a "$OUT/stat.txt" \
      || { echo "[!] perf stat failed on '$G'"; exit 1; }
done
grep -qE "^ *[0-9][0-9,]* *instructions" "$OUT/stat.txt" \
    || { echo "[!] no instruction count in $OUT/stat.txt"; exit 1; }

echo "[3/3] profile (cpu-clock named explicitly, or zero samples are captured)..."
perf record -e cpu-clock -F 199 -g -o "$OUT/${NAME}.perf.data" -- \
    $PY -u "$BENCH" --worker -l 1 -w 1 -n "$N" \
    || { echo "[!] perf record failed"; exit 1; }

# The zero-samples trap is silent: perf record exits 0 having captured nothing.
SAMPLES=$(perf script -i "$OUT/${NAME}.perf.data" 2>/dev/null | grep -c . || true)
if [ "${SAMPLES:-0}" -eq 0 ]; then
    echo "[!] the profile contains ZERO samples."
    echo "    echo 100000 > /proc/sys/kernel/perf_event_max_sample_rate"
    echo "    echo 1 > /proc/sys/kernel/perf_event_paranoid"
    exit 1
fi
perf report -i "$OUT/${NAME}.perf.data" --stdio --no-children > "$OUT/report.txt"

echo "[+] done -> results/$NAME/   ($SAMPLES profile samples)"
grep -E "Mean \+- std dev" "$OUT/timing.txt" | tail -1
grep -E "^ *[0-9].*instructions" "$OUT/stat.txt" | head -1
