#!/bin/bash
# The two open measurements from the analysis doc:
#   A) --call-graph dwarf captures -> usable call chains and flame graphs
#   B) release-interpreter comparison -> measures the debug-build distortion
#
# Run from anywhere; paths resolve against the repo root.
#   scripts/cleanup_measurements.sh          # both parts
#   scripts/cleanup_measurements.sh dwarf    # part A only
#   scripts/cleanup_measurements.sh release  # part B only
set -eu

WHAT=${1:-both}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/env.sh"
OUT="$ROOT/results/_cleanup"
mkdir -p "$OUT"

[ -x "$PY" ] || { echo "ERROR: \$PY not executable"; exit 1; }
[ -d "$BM/bm_nbody" ] || { echo "ERROR: \$BM/bm_nbody not found"; exit 1; }

# ----------------------------------------------------------------- part A
do_dwarf() {
  echo "==================================================================="
  echo " A) DWARF call graphs"
  echo "==================================================================="
  AVAIL=$(df -Pm "$ROOT" | awk 'NR==2{print $4}')
  echo "[*] free space here: ${AVAIL} MB (need roughly 250 MB)"
  [ "$AVAIL" -lt 300 ] && { echo "ERROR: not enough free space"; exit 1; }

  if [ ! -x "$ROOT/FlameGraph/flamegraph.pl" ]; then
      echo "[*] cloning FlameGraph..."
      git clone --depth 1 https://github.com/brendangregg/FlameGraph.git "$ROOT/FlameGraph"
  fi

  # -F 99 rather than 199: DWARF copies 16 KB of stack per sample, so halve the rate.
  for spec in "nbody:100" "pyflate:20"; do
      NAME=${spec%%:*}; N=${spec##*:}
      echo
      echo "[*] $NAME  (--call-graph dwarf,16384 -F 99 -n $N)"
      perf record -e cpu-clock -F 99 --call-graph dwarf,16384 \
          -o "$OUT/${NAME}_dwarf.perf.data" -- \
          $PY -u "$BM/bm_${NAME}/run_benchmark.py" --worker -l 1 -w 1 -n "$N"

      echo "[*] building report (DWARF unwinds at report time, this is slow)..."
      perf report -i "$OUT/${NAME}_dwarf.perf.data" --stdio --no-children \
          > "$OUT/report_${NAME}_dwarf.txt"

      perf script -i "$OUT/${NAME}_dwarf.perf.data" \
          | "$ROOT/FlameGraph/stackcollapse-perf.pl" > "$OUT/${NAME}.folded"
      "$ROOT/FlameGraph/flamegraph.pl" --title "$NAME (fixed work, cpu-clock)" \
          "$OUT/${NAME}.folded" > "$OUT/flamegraph_${NAME}.svg"

      # A good capture shows function names under the eval loop; a bad one
      # shows raw hex, which is what frame-pointer unwinding produced before.
      echo "[*] call-graph check for $NAME:"
      BAD=$(grep -cE -- "--0x[0-9a-f]{8,}" "$OUT/report_${NAME}_dwarf.txt" || true)
      GOOD=$(grep -cE -- "--_Py|--__pyx|--bzip2_|--advance" "$OUT/report_${NAME}_dwarf.txt" || true)
      echo "      named frames: $GOOD    raw-hex frames: $BAD"
      if [ "$GOOD" -gt "$BAD" ]; then
          echo "      OK - call chains are usable"
      else
          echo "      STILL BROKEN - try --call-graph dwarf,32768, or report it"
      fi
  done
}

# ----------------------------------------------------------------- part B
do_release() {
  echo
  echo "==================================================================="
  echo " B) release vs debug interpreter"
  echo "==================================================================="
  PYREL=${PYREL:-$HOME/venv-release/bin/python}
  if [ ! -x "$PYREL" ]; then
      echo "[*] creating a release venv at $HOME/venv-release ..."
      python3 -m venv "$HOME/venv-release"
      "$HOME/venv-release/bin/pip" install --quiet --upgrade pip
      "$HOME/venv-release/bin/pip" install --quiet pyperf
  fi
  echo "[*] debug   : $($PY    -c 'import sys;print(sys.version.split()[0], "debug" if hasattr(sys,"gettotalrefcount") else "release")')"
  echo "[*] release : $($PYREL -c 'import sys;print(sys.version.split()[0], "debug" if hasattr(sys,"gettotalrefcount") else "release")')"

  : > "$OUT/release_vs_debug.txt"
  for spec in "nbody:100" "pyflate:20"; do
      NAME=${spec%%:*}; N=${spec##*:}
      for pair in "debug:$PY" "release:$PYREL"; do
          TAG=${pair%%:*}; INTERP=${pair#*:}
          echo "=== $NAME / $TAG (-n $N) ===" | tee -a "$OUT/release_vs_debug.txt"
          perf stat -r 3 -e task-clock,cycles,instructions -- \
              "$INTERP" -u "$BM/bm_${NAME}/run_benchmark.py" --worker -l 1 -w 1 -n "$N" \
              2>&1 | grep -E "task-clock|cycles|instructions|elapsed" \
              | tee -a "$OUT/release_vs_debug.txt"
          echo | tee -a "$OUT/release_vs_debug.txt"
      done
  done
  echo
  echo "[+] $OUT/release_vs_debug.txt"
  echo "    Divide instructions by 101 (nbody) or 21 (pyflate) for per-call figures."
  echo "    debug/release ratio is the measured distortion that the doc currently estimates."
}

case "$WHAT" in
  dwarf)   do_dwarf ;;
  release) do_release ;;
  both)    do_dwarf; do_release ;;
  *) echo "usage: $0 [dwarf|release|both]"; exit 1 ;;
esac

echo
echo "[+] done -> $OUT/"
ls -lh "$OUT/"
