# Locate the two things this project needs that are NOT part of this repository:
#
#   PY  the CPython 3.10 built --with-pydebug, inside the course venv
#   BM  the installed pyperformance benchmark directory
#
# Both belong to the course toolchain, not to the project. Nothing in this
# repository writes to either of them, and the repository does not have to live
# anywhere near them.
#
# Set them explicitly if yours are elsewhere:
#
#     export PY=/path/to/venv/bin/python
#     export BM=/path/to/pyperformance/data-files/benchmarks
#
# Otherwise they are discovered below: the location used for the measurements
# in the reports is tried first, then a glob, so rebuilding the venv somewhere
# else does not break the scripts.

_cds_first() {
    local c
    for c in "$@"; do
        [ -e "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

if [ -z "${PY:-}" ]; then
    PY=$(_cds_first \
        /root/sw-project/baseline/scripts/venv/cpython3.10-*/bin/python \
        "$HOME"/sw-project/baseline/scripts/venv/cpython3.10-*/bin/python \
        /root/*/baseline/scripts/venv/cpython3.10-*/bin/python \
        "$HOME"/*/baseline/scripts/venv/cpython3.10-*/bin/python \
        /root/*/venv*/bin/python3-dbg \
        2>/dev/null) || PY=""
fi

if [ -z "${BM:-}" ]; then
    BM=$(_cds_first \
        /root/sw-project/venv-dbg/lib/python3.10/site-packages/pyperformance/data-files/benchmarks \
        "$HOME"/sw-project/venv-dbg/lib/python3.10/site-packages/pyperformance/data-files/benchmarks \
        /root/*/*/lib/python3.*/site-packages/pyperformance/data-files/benchmarks \
        "$HOME"/*/*/lib/python3.*/site-packages/pyperformance/data-files/benchmarks \
        2>/dev/null) || BM=""
fi

if [ ! -x "${PY:-/nonexistent}" ]; then
    echo "ERROR: cannot find the debug interpreter." >&2
    echo "  Look for it:  ls -d /root/*/baseline/scripts/venv/cpython3.10-*" >&2
    echo "  Then:         export PY=<that path>/bin/python" >&2
    exit 1
fi

if [ ! -d "${BM:-/nonexistent}/bm_nbody" ]; then
    echo "ERROR: cannot find the installed pyperformance benchmarks." >&2
    echo "  Look for them:  find / -name bm_nbody -type d 2>/dev/null" >&2
    echo "  Then:           export BM=<the directory containing bm_nbody>" >&2
    exit 1
fi

export PY BM

if [ -z "${CDS_ENV_ANNOUNCED:-}" ]; then
    echo "[env] PY=$PY"
    echo "[env] BM=$BM"
    export CDS_ENV_ANNOUNCED=1
fi
