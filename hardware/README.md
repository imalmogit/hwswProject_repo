# Move-To-Front Accelerator (`mtf_unit`)

Hardware acceleration proposal for the bzip2 move-to-front stage in the
**pyflate** benchmark.

| | |
| --- | --- |
| RTL | `mtf_unit.v` (Verilog-2005) |
| Testbench | `tb_mtf_unit.v`, self-checking |
| Stimulus | `gen_stimulus.py` — captured from a real bzip2 decode |
| Verification | **PASS** — 89,837 operations, output stream identical to pyflate |

## 1. What it accelerates

pyflate's bzip2 decoder promotes one symbol to the front of a table on every
decoded symbol:

```python
def move_to_front(l, c):
    l[:] = l[c:c + 1] + l[0:c] + l[c + 1:]
```

Three slices, two concatenations and a slice assignment, over a table of up to
256 entries, once per symbol. Measured on the course guest:

| Measurement | Value |
| --- | --- |
| MTF calls per benchmark call | 89,837 |
| Table size in the test stream | 145 entries |
| **Instructions per MTF operation** | **≈ 21,400** (≈ 4.1 µs) |
| Share of the profile | 9.57%, or 15.13% with the allocator underneath |
| Same, excluding debug-build-only code | 11.7%, or 18.5% with the allocator |

The per-operation figure is measured, not estimated: optimization opt1 changes
`move_to_front` and nothing else, and removes 1.924 G instructions per benchmark
call across 89,837 operations.

Twenty-one thousand instructions to move one byte to the front of a 145-entry
list. The accelerator does it in **one cycle**.

## 2. Why this component

- **Fixed, tiny working set** — 256 bytes, resident in the unit. No memory
  traffic, no cache pressure, no DMA.
- **Trivially regular** — one index in, one byte out, one well-defined table
  mutation. No floating point, no variable latency, no exceptions.
- **Executed constantly** — once per decoded symbol, throughout bzip2.
- **Already proven in software** — replacing the rebuild with
  `l.insert(0, l.pop(c))` removed 72% of the stage's cost and made the whole
  benchmark 12.7% faster. The hardware removes the rest.
- **Not narrowly workload-specific** — MTF is a standard transform in bzip2,
  LZ77 variants and some cache-replacement policies.

## 3. Interface

Synchronous to `clk`, asynchronous active-low `rst_n`. Parameters: `N` = 256
table entries, `DW` = 8 symbol bits, `IW` = 8 index bits (`2**IW >= N`).

| Signal | Dir | Width | Description |
| --- | --- | --- | --- |
| `load_en` | in | 1 | write one table entry |
| `load_addr` | in | 8 | entry address |
| `load_data` | in | 8 | entry value |
| `load_len` | in | 9 | number of valid entries, 0…256 |
| `load_commit` | in | 1 | latch `load_len`, arm the table |
| `req_valid` | in | 1 | request a promotion |
| `req_index` | in | 8 | index `c` to promote |
| `req_ready` | out | 1 | high when the table is armed |
| `rsp_valid` | out | 1 | response strobe |
| `rsp_data` | out | 8 | the promoted symbol |
| `rsp_error` | out | 1 | `req_index >= load_len` |

**Latency** 1 cycle (registered outputs). **Throughput** 1 operation per cycle,
back to back, no bubbles, no stalls once armed. **Target** 200 MHz single-cycle.

## 4. Architecture

```
                 load_addr/load_data/load_en
                            │
                            ▼
  req_index ──┬──▶ ┌──────────────────┐
              │    │   TABLE  N x DW  │   256 x 8 flip-flops
              │    └──────────────────┘
              │         │        ▲
              │         │        │  conditional parallel shift
              │         ▼        │  entry[0]       <= sel_data
              │    ┌─────────┐   │  entry[i], i<=c <= entry[i-1]
              └───▶│ N:1 MUX │───┘  entry[i], i>c  <= entry[i]
                   └─────────┘
                        │ sel_data
                        ▼
                   ┌─────────┐
                   │ RSP REG │──▶ rsp_data, rsp_valid
                   └─────────┘
  req_index ──▶ ┌───────────────┐
                │  <  COMPARE   │──▶ rsp_error
  load_len ───▶ └───────────────┘

  FSM:  S_LOAD ──load_commit──▶ S_READY ──load_commit──▶ S_LOAD
```

**Datapath — three elements.** An `N:1` read multiplexer selects
`entry[req_index]`, which is both the response and the value written back to
position 0. A shift network of `N` 8-bit 2:1 multiplexers performs the
promotion: each entry either holds or takes its neighbour, decided by one
comparison against `req_index`. A 9-bit comparator does the bounds check.

**Control — two states.** `S_LOAD` accepts table writes and holds `req_ready`
low; `load_commit` latches the length and moves to `S_READY`, which accepts one
request per cycle. A further `load_commit` returns to `S_LOAD` for the next
bzip2 block. Response strobes assert only on an accepted request, so a bounds
violation mutates nothing.

## 5. Hardware/software interface

**Option A — ISA extension (recommended).** Three custom instructions in the
style of RISC-V `custom-0`: `mtf.load rs1, rs2` writes an entry, `mtf.commit
rs1` arms the table, and `mtf.next rd, rs1` promotes `rs1` and returns the
symbol in `rd`. The unit sits beside the integer ALU and writes back through
the normal result path; `mtf.next` is single-cycle with no memory operand.
Software side: a CPython extension module exposing `mtf_load(table)` and
`mtf_next(c)`, with `move_to_front` replaced by a call to the latter.

**Option B — memory-mapped peripheral.** A 32-bit AXI4-Lite slave with five
registers: `CTRL` (commit, soft reset), `LEN`, `LOAD` (address and data),
`REQ` (the write issues the operation) and `RSP` (error bit plus symbol).
Needs a small driver plus the same extension module. No DMA — one index in and
one byte out is far below the threshold where DMA setup would pay.

**Why the choice matters.** Optimization opt2 in this project replaced `pow`
with a cheaper formula and made nbody **3.7% slower**, because reaching the
cheaper operation cost a Python-level function call. The same failure mode
applies here:

| Path | Cost per operation |
| --- | --- |
| Today, pure Python | ≈ 21,400 instructions ≈ 4.1 µs |
| Option A, custom instruction | 1 cycle ≈ 5 ns, plus the Python call |
| Option B, two bus round trips | ≈ 100–200 ns, plus the Python call |

Both dwarf the 4.1 µs being replaced, so either works here. The general rule
stands: an accelerator whose invocation path costs more than the work it
replaces is a net loss, and this project measured that outcome once.

## 6. Frequency, area and power

**Frequency.** The critical path is the `N:1` read multiplexer followed by the
shift-network write — roughly eight levels of 2:1 multiplexing plus setup.
200 MHz single-cycle is conservative on any modern process. Registering
`sel_data` would split it into two stages if a higher clock were needed;
throughput stays at 1 op/cycle and the decoder consumes each symbol before
issuing the next, so latency does not matter.

**Area.** 2,048 flip-flops of table storage, 2,048 8-bit 2:1 mux cells for the
shift network, a 256:1 read mux, a 9-bit comparator and a 1-bit FSM. Small
beside a 32 KB L1 cache, and a single shared structure rather than something
replicated per core.

**Power and energy.** Clock-gated outside `S_READY`, and only the entries below
`req_index` switch on each operation, so average switching tracks the mean
promoted index rather than the full table. The defensible claim is energy per
operation rather than peak power: replacing ≈ 21,400 executed instructions,
five heap allocations and ≈ 1,450 refcounted pointer copies with one register
transfer cuts the energy for that operation by orders of magnitude.

## 7. Expected speedup and its limit

"The stage" has two defensible definitions. The narrow one is the MTF list
operations; the wide one adds the allocator traffic those slices cause, which
the accelerator also eliminates because the allocations stop happening at all.

| Basis | Narrow | Wide |
| --- | --- | --- |
| Share of profile | 9.57% | 15.13% |
| Excluding debug-build-only code | 11.7% | 18.5% |
| Time per benchmark call | 368 ms | 581 ms |
| **Amdahl ceiling** | **1.13×** | **1.23×** |
| Stage speedup | 820× | 1294× |

At 200 MHz the unit performs all 89,837 operations of a decode in 449 µs,
against 368–581 ms in software. **The stage stops mattering entirely, and the
benchmark still only gets about 1.23× faster.** That is Amdahl's law, and
stating it plainly is more useful than quoting the 1294×. For comparison, the
software fix (opt1) already delivered −12.7% time and −11.6% instructions.

**Assumptions.** The table fits in `N` = 256 entries, which bzip2 guarantees and
`rsp_error` catches otherwise; one operation per decoded symbol, which the
captured trace confirms; and an invocation path cheap relative to 4.1 µs, true
for both options above. Note also that the profile comes from a `--with-pydebug`
interpreter — 0.321 G of opt1's measured gain is debug-only work absent from a
release build, so the release benefit is smaller.

## 8. Verification

```bash
make                             # generate stimulus, compile, simulate
```

`gen_stimulus.py` instruments `move_to_front` during an actual decode of
`interpreter.tar.bz2` and records the initial table plus every
(index, promoted symbol) pair. pyflate calls it from two places — a 6-entry
selector table and the 145-entry symbol table — and the generator picks the
busier one. The testbench loads the captured table, streams all 89,837 requests
back to back with no bubbles, and compares every response against the value
Python produced, plus reset, arming and bounds-check coverage.

```
  reset       : req_ready low until the table is armed
  arm         : req_ready high after load_commit
  bounds check: index 145 correctly rejected
  issued     : 89837
  checked    : 89837
  mismatches : 0
  RESULT: PASS -- output stream matches pyflate exactly
```

Matching the Python output stream symbol for symbol is the meaningful check: it
shows the unit is a drop-in replacement for the function it removes, not merely
a plausible piece of logic.
