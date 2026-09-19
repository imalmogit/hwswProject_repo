#!/bin/bash
# Separate process startup from per-call cost for the Cython variant.
#
#   scripts/nbody_opt3_regression.sh
#
# WHY THIS EXISTS
#
# For the baseline and opt1/opt2, one benchmark call costs hundreds of
# milliseconds, so process startup is a rounding error and per-call figures can
# be read straight off `total / (N+1)`.
#
# opt3 runs in ~3.8 ms per call. Startup -- interpreter init, imports, loading
# the compiled extension -- is then a LARGER share of the fixed-work run than
# the benchmark itself, and total/(N+1) over-states the per-call cost by tens of
# percent. Dividing would not measure the optimization, it would measure Python
# starting up.
#
# THE MODEL
#
#   instructions(N) = startup + calls * per_call        where calls = N + 1
#
# Two points determine the line; the third is held out and used to check it.
# The slope is the per-call cost with startup removed. The same fit is done on
# task-clock, and its slope should land near the independent pyperf mean from
# the 20-process timing run -- two measurements that share no machinery.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/env.sh"

BENCH="$ROOT/benchmarks/bm_nbody_opt3_cython/run_benchmark.py"
OUT="$ROOT/results/bm_nbody_opt3_cython"
RAW="$OUT/regression_raw.txt"
mkdir -p "$OUT"

[ -f "$BENCH" ] || { echo "no run_benchmark.py at $BENCH"; exit 1; }

echo "=============================================="
echo "[*] bm_nbody_opt3_cython startup/per-call fit"
echo "=============================================="

: > "$RAW"
for N in 20 60 100; do
  echo "[*] N = $N  (calls = $((N+1)))"
  echo "=== N=$N ===" >> "$RAW"
  perf stat -r 3 -e instructions,task-clock -- \
      $PY -u "$BENCH" --worker -l 1 -w 1 -n "$N" 2>&1 | tee -a "$RAW"
done

$PY - "$RAW" > "$OUT/regression.txt" <<'PYEOF'
import re, sys

text = open(sys.argv[1]).read()
rows = []
for block in text.split("=== N=")[1:]:
    n = int(block.split("===")[0])
    ins = re.search(r"^\s*([\d,.]+)\s+instructions", block, re.M)
    clk = re.search(r"^\s*([\d,.]+)\s+(?:msec\s+)?task-clock", block, re.M)
    if not (ins and clk):
        continue
    rows.append((n + 1,
                 float(ins.group(1).replace(",", "")),
                 float(clk.group(1).replace(",", ""))))
rows.sort()

if len(rows) < 3:
    print("could not parse three points; check regression_raw.txt")
    sys.exit(1)

(c1, i1, t1), (c2, i2, t2), (c3, i3, t3) = rows

def fit(ca, ya, cb, yb):
    slope = (yb - ya) / (cb - ca)
    return slope, ya - slope * ca

print("bm_nbody_opt3_cython -- startup separated from per-call cost")
print()
print("Measured (perf stat -r 3, fixed work):")
print(f"{'calls':>8}  {'instructions':>16}  {'task-clock (ms)':>16}")
for c, i, t in rows:
    print(f"{c:>8}  {i:>16,.0f}  {t:>16,.2f}")
print()

for label, ya, yb, yc, unit, scale in (
        ("instructions", i1, i2, i3, "M", 1e6),
        ("time",         t1, t2, t3, "ms", 1.0)):
    slope, icept = fit(c1, ya, c2, yb)
    pred = icept + slope * c3
    err = 100.0 * (pred - yc) / yc
    print(f"{label}: fit on calls={c1} and calls={c2}, calls={c3} held out")
    print(f"  startup  : {icept/scale:,.3f} {unit}")
    print(f"  per call : {slope/scale:,.3f} {unit}")
    print(f"  predicted at calls={c3}: {pred/scale:,.3f} {unit}   "
          f"measured {yc/scale:,.3f} {unit}   error {err:+.2f}%")
    naive = yc / c3
    print(f"  naive total/calls at N={c3-1}: {naive/scale:,.3f} {unit}  "
          f"({100.0*(naive-slope)/slope:+.1f}% vs the slope)")
    print()

print("Cross-check: the time slope above and the pyperf mean in timing.txt")
print("come from different runs through different machinery. If they agree to")
print("a few percent, the fit is measuring the benchmark and not the harness.")
PYEOF

echo
cat "$OUT/regression.txt"
echo
echo "[+] done -> results/bm_nbody_opt3_cython/regression.txt"
