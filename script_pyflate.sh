#!/bin/bash
# =============================================================================
#  script_pyflate.sh -- full pipeline for the pyflate benchmark
#
#  Covers, as the project specification requires:
#    1. environment setup and dependency installation
#    2. baseline execution with pyperformance and perf
#    3. flame graph and performance data generation
#    4. post-optimization execution and performance comparison
#    5. RTL verification of the proposed hardware accelerator
#
#  Usage:   ./script_pyflate.sh [setup|baseline|optimized|flamegraph|compare|hardware|all]
#           default is 'all'
#
#  Override the interpreter and benchmark directory if yours differ:
#           PY=/path/to/python BM=/path/to/benchmarks ./script_pyflate.sh
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/env.sh"

BENCH=pyflate
NVAL=20                        # LOCKED: every pyflate variant uses -n 20
VARIANTS=(bm_pyflate_opt1 bm_pyflate_opt2)
STAGE=${1:-all}

banner() { echo; echo "============================================================"; echo " $*"; echo "============================================================"; }

# -----------------------------------------------------------------------------
do_setup() {
    banner "SETUP"
    [ -x "$PY" ] || { echo "ERROR: \$PY not executable: $PY"; exit 1; }
    [ -d "$BM/bm_$BENCH" ] || { echo "ERROR: \$BM/bm_$BENCH not found: $BM"; exit 1; }

    echo "[*] copying the pyflate data file into each variant"
    for v in "${VARIANTS[@]}"; do
        mkdir -p "$ROOT/benchmarks/$v/data"
        cp "$BM/bm_pyflate/data/interpreter.tar.bz2" "$ROOT/benchmarks/$v/data/"
    done

    echo "[*] verifying every variant reproduces the benchmark's MD5 digest"
    $PY "$ROOT/scripts/verify_pyflate.py" || exit 1

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
# The proposed accelerator is verified against vectors captured from a real
# decode; see report_pyflate.txt section 5 and hardware/README.md.
do_hardware() {
    banner "HARDWARE ACCELERATOR VERIFICATION"
    if ! command -v iverilog >/dev/null 2>&1; then
        echo "[!] iverilog not installed -- skipping RTL simulation"
        echo "    install with: apt-get install -y iverilog"
        return 0
    fi
    ( cd "$ROOT/hardware" && \
      PYFLATE_SRC="$ROOT/benchmarks/bm_pyflate_opt1/run_benchmark.py" \
      PYFLATE_DATA="$ROOT/benchmarks/bm_pyflate_opt1/data/interpreter.tar.bz2" \
      make )
}

# -----------------------------------------------------------------------------
case "$STAGE" in
    setup)      do_setup ;;
    baseline)   do_baseline ;;
    optimized)  do_optimized ;;
    flamegraph) do_flamegraph ;;
    compare)    do_compare ;;
    hardware)   do_hardware ;;
    all)        do_setup; do_baseline; do_optimized; do_flamegraph; do_compare; do_hardware ;;
    *) echo "usage: $0 [setup|baseline|optimized|flamegraph|compare|hardware|all]"; exit 1 ;;
esac
