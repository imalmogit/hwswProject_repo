# HW/SW Co-design: nbody & pyflate

Analysis, software optimization, and a hardware-acceleration proposal for two
`pyperformance` benchmarks, measured on the course QEMU guest.

**Authors:** Almog As (313552952), Tal Schnieder (211628656)

## Results

| Variant | Time per call | vs. baseline | Instructions per call | vs. baseline |
| --- | ---: | ---: | ---: | ---: |
| nbody baseline | 477 ms | — | 2.909 G | — |
| nbody opt1 — hoist indexed reads | 428 ms | **−10.3%** | 2.662 G | −8.5% |
| nbody opt2 — `sqrt` instead of `pow` | 444 ms | −6.9% | 2.765 G | −4.9% |
| nbody opt3 — Cython typed core | 3.82 ms | **−99.2%** | 0.0197 G | −99.3% |
| pyflate baseline | 3.14 s | — | 16.610 G | — |
| pyflate opt1 — in-place move-to-front | 2.74 s | **−12.7%** | 14.686 G | −11.6% |
| pyflate opt2 — table-driven Huffman | 2.63 s | **−16.2%** | 13.943 G | −16.1% |

Both benchmarks meet the required 7% improvement threshold.

The proposed hardware accelerator targets pyflate's bzip2 move-to-front step.
It is implemented in Verilog and verified against 89,837 operations captured
from a real decode, with zero mismatches. Full analysis is in
[`report_nbody.txt`](report_nbody.txt) and
[`report_pyflate.txt`](report_pyflate.txt).

## Repository layout

```text
.
├── report_nbody.txt          analysis, optimizations, results, HW proposal
├── report_pyflate.txt        analysis, optimizations, results, HW proposal
├── script_nbody.sh           full nbody pipeline
├── script_pyflate.sh         full pyflate pipeline and RTL verification
├── prompt.txt                AI prompts used during the project
├── hardware/                 move-to-front accelerator
│   ├── mtf_unit.v            Verilog RTL
│   ├── tb_mtf_unit.v         self-checking testbench
│   ├── gen_stimulus.py       vectors from a real bzip2 decode
│   ├── Makefile              generate, compile, and simulate
│   └── README.md             interface and architecture details
├── benchmarks/               custom benchmark variants
├── scripts/                  measurement and verification harness
├── results/                  measurement outputs by variant
└── env/                      QEMU guest environment audit
```

The variants are cumulative: nbody opt2 includes opt1, and opt3 includes opt2.

## Prerequisites

- Course Ubuntu QEMU guest with `perf` available.
- CPython 3.10 built with `--with-pydebug`.
- Installed `pyperformance` benchmark data.
- `Cython` for nbody opt3.
- `iverilog` and `make` for the hardware simulation.

The scripts locate the Python interpreter and benchmark directory automatically.
If needed, set them explicitly:

```bash
export PY=/path/to/venv/bin/python
export BM=/path/to/pyperformance/data-files/benchmarks
```

## Run

From the repository root:

```bash
./script_nbody.sh
./script_pyflate.sh
```

Each script performs setup, correctness verification, baseline and optimized
measurements, profiling, flame-graph generation, and comparison. Individual
stages can also be run:

```bash
./script_nbody.sh setup
./script_nbody.sh baseline
./script_nbody.sh optimized
./script_nbody.sh flamegraph
./script_nbody.sh compare
./script_pyflate.sh hardware
```

Correctness is checked before measurement: nbody results are compared against
the original final energy after 20,000 timesteps, and pyflate results against
the benchmark's MD5 digest.

### Run the hardware verification only

```bash
cd hardware && make
```

Expected result:

```text
issued     : 89837
checked    : 89837
mismatches : 0
RESULT: PASS -- output stream matches pyflate exactly
```

## Measurement notes

- nbody uses `-l 1 -w 1 -n 100`; pyflate uses `-l 1 -w 1 -n 20`, including
  their baselines. Do not change these values unless all variants are rerun.
- Timing is collected with `pyperformance`; instruction counts are collected
  separately with `perf stat` on one fixed-work worker process.
- `perf record` uses `cpu-clock` and DWARF call graphs to obtain samples in the
  QEMU guest.

## Limitations

- Measurements use a debug (`--with-pydebug`) interpreter and a single-vCPU
  QEMU guest.
- The accelerator is verified in simulation only; it was not synthesized.


