#!/bin/bash
# =============================================================================
#  script_nbody.sh -- full pipeline for the nbody benchmark
#
#  Covers, as the project specification requires:
#    1. environment setup and dependency installation
#    2. baseline execution with pyperformance and perf
#    3. flame graph and performance data generation
#    4. post-optimization execution and performance comparison
#
#  Usage:   ./script_nbody.sh [setup|baseline|optimized|flamegraph|compare|all]
#           default is 'all'
#
#  Override the interpreter and benchmark directory if yours differ:
#           PY=/path/to/python BM=/path/to/benchmarks ./script_nbody.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/env.sh"

BENCH=nbody
NVAL=100                       # LOCKED: every nbody variant uses -n 100
VARIANTS=(bm_nbody_opt1 bm_nbody_opt2 bm_nbody_opt3_cython)
STAGE=${1:-all}

banner() { echo; echo "============================================================"; echo " $*"; echo "============================================================"; }

# -----------------------------------------------------------------------------
do_setup() {
    banner "SETUP"
    [ -x "$PY" ] || { echo "ERROR: \$PY not executable: $PY"; exit 1; }
    [ -d "$BM/bm_$BENCH" ] || { echo "ERROR: \$BM/bm_$BENCH not found: $BM"; exit 1; }

    echo "[*] development headers for the Cython variant"
    if ! ls /usr/include/python3.10*/Python.h >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq python3.10-dev python3.10-dbg
    fi

    echo "[*] cython"
    $PY -m pip install --quiet cython

    echo "[*] building the Cython extension"
    ( cd "$ROOT/benchmarks/bm_nbody_opt3_cython" && $PY setup.py build_ext --inplace )
    ls "$ROOT"/benchmarks/bm_nbody_opt3_cython/*.so >/dev/null \
        || { echo "ERROR: extension did not build"; exit 1; }

    echo "[*] verifying every variant reproduces the original physics"
    $PY "$ROOT/scripts/verify_nbody.py" || exit 1

    echo "[*] perf sample rate"
    echo 100000 > /proc/sys/kernel/perf_event_max_sample_rate 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# One variant, three measurements. See scripts/measure.sh for the rationale;
# in short: timing and counters come from different runs and are never mixed,
# and -e cpu-clock must be named or perf captures zero samples on this guest.
measure_one() {
    "$ROOT/scripts/measure.sh" "$1" "$NVAL"
}

do_baseline()  { banner "BASELINE"; measure_one "$BM/bm_$BENCH"; }

do_optimized() {
    banner "OPTIMIZED VARIANTS"
    for v in "${VARIANTS[@]}"; do measure_one "$ROOT/benchmarks/$v"; done
}

# -----------------------------------------------------------------------------
do_flamegraph() {
    banner "FLAME GRAPH"
    # Frame-pointer unwinding is useless on this -Og build, so use DWARF.
    # -F 99 rather than 199 because DWARF copies 16 KB of stack per sample.
    [ -x "$ROOT/FlameGraph/flamegraph.pl" ] || \
        git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$ROOT/FlameGraph"

    local out="$ROOT/results/_flamegraph"
    mkdir -p "$out"
    perf record -e cpu-clock -F 99 --call-graph dwarf,16384 \
        -o "$out/$BENCH.perf.data" -- \
        $PY -u "$BM/bm_$BENCH/run_benchmark.py" --worker -l 1 -w 1 -n "$NVAL"
    perf script -i "$out/$BENCH.perf.data" \
        | "$ROOT/FlameGraph/stackcollapse-perf.pl" > "$out/$BENCH.folded"
    "$ROOT/FlameGraph/flamegraph.pl" --title "$BENCH (fixed work, cpu-clock)" \
        "$out/$BENCH.folded" > "$out/flamegraph_$BENCH.svg"
    echo "[+] $out/flamegraph_$BENCH.svg"
}

# -----------------------------------------------------------------------------
do_compare() {
    banner "PERFORMANCE COMPARISON"
    printf "%-26s %14s %18s\n" "variant" "mean time" "instructions"
    printf "%-26s %14s %18s\n" "--------------------------" "--------------" "------------------"
    for n in "bm_$BENCH" "${VARIANTS[@]}"; do
        local d="$ROOT/results/$n"
        [ -d "$d" ] || continue
        local t i
        t=$(grep -hoE "Mean \+- std dev: .*" "$d/timing.txt" 2>/dev/null | tail -1 | sed 's/Mean +- std dev: //')
        i=$(grep -hE "^ *[0-9,]+ +instructions" "$d/stat.txt" 2>/dev/null | head -1 | awk '{print $1}')
        printf "%-26s %14s %18s\n" "$n" "${t:-n/a}" "${i:-n/a}"
    done
    echo
    echo "Per-call figures: divide instructions by $((NVAL + 1)) (1 warmup + $NVAL values)."
    echo "Full analysis and attribution: report_nbody.txt"
}

# -----------------------------------------------------------------------------
case "$STAGE" in
    setup)      do_setup ;;
    baseline)   do_baseline ;;
    optimized)  do_optimized ;;
    flamegraph) do_flamegraph ;;
    compare)    do_compare ;;
    all)        do_setup; do_baseline; do_optimized; do_flamegraph; do_compare ;;
    *) echo "usage: $0 [setup|baseline|optimized|flamegraph|compare|all]"; exit 1 ;;
esac
