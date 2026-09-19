#!/usr/bin/env python
"""Check every pyflate variant still decompresses to the expected MD5.

    scripts/verify_pyflate.py [path/to/bm_pyflate]

The baseline defaults to $BM/bm_pyflate.
"""
import hashlib, importlib.util, os, sys, time

EXPECT = "afa004a630fe072901b1d9628b960974"   # the digest the benchmark asserts
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def _find_bm():
    """$BM if set, else look for the installed pyperformance benchmarks.

    They live outside this repository and the scripts export $BM, so this
    fallback only matters when the file is run by hand."""
    if os.environ.get("BM"):
        return os.environ["BM"]
    import glob
    home = os.path.expanduser("~")
    for pat in (
        "/root/sw-project/venv-dbg/lib/python3.10/site-packages/"
        "pyperformance/data-files/benchmarks",
        home + "/sw-project/venv-dbg/lib/python3.10/site-packages/"
        "pyperformance/data-files/benchmarks",
        "/root/*/*/lib/python3.*/site-packages/pyperformance/data-files/benchmarks",
        home + "/*/*/lib/python3.*/site-packages/pyperformance/data-files/benchmarks",
    ):
        for hit in sorted(glob.glob(pat)):
            if os.path.isdir(os.path.join(hit, "bm_nbody")):
                return hit
    sys.exit("cannot find the pyperformance benchmarks; set $BM")

BM = _find_bm()
BASE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BM, "bm_pyflate")

TARGETS = [("original", BASE)] + [
    (n, os.path.join(ROOT, "benchmarks", "bm_" + n))
    for n in ("pyflate_opt1", "pyflate_opt2")]

def run(folder):
    path = os.path.join(folder, "run_benchmark.py")
    data = os.path.join(folder, "data", "interpreter.tar.bz2")
    if not os.path.exists(data):                 # fall back to the baseline's copy
        data = os.path.join(BASE, "data", "interpreter.tar.bz2")
    spec = importlib.util.spec_from_file_location("p_%d" % len(sys.modules), path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = m
    spec.loader.exec_module(m)
    with open(data, "rb") as fp:
        field = m.RBitfield(fp)
        magic = field.readbits(16)
        assert magic == 0x425a, "expected bzip2 magic, got %#x" % magic
        t0 = time.perf_counter()
        out = m.bzip2_main(field)
        dt = time.perf_counter() - t0
    return hashlib.md5(out).hexdigest(), dt, len(out)

base = None
ok = True
print(f"{'variant':<18} {'time':>10}  {'vs base':>8}   md5     bytes out")
for name, folder in TARGETS:
    if not os.path.exists(os.path.join(folder, "run_benchmark.py")):
        print(f"{name:<18} MISSING: {folder}")
        ok = False
        continue
    digest, dt, n = run(folder)
    if base is None:
        base = dt
    good = digest == EXPECT
    ok &= good
    print(f"{name:<18} {dt*1000:8.1f}ms  {base/dt:7.2f}x   "
          f"{'OK ' if good else 'BAD'}     {n}")
print()
print("PASS - every variant reproduces the expected MD5" if ok
      else "FAIL - a variant produced wrong output")
sys.exit(0 if ok else 1)
