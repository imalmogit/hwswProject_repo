# Move-To-Front Accelerator (`mtf_unit`)

Hardware acceleration proposal for the bzip2 move-to-front stage in the
**pyflate** benchmark.

| | |
| --- | --- |
| RTL | `mtf_unit.v` (Verilog-2005) |
| Testbench | `tb_mtf_unit.v`, self-checking |
| Stimulus | `gen_stimulus.py` — captured from a real bzip2 decode |
| Verification status | **PASS** — 89,837 operations, output stream identical to pyflate |

---

## 1. What it accelerates

pyflate's bzip2 decoder promotes one symbol to the front of a table on every
decoded symbol:

```python
def move_to_front(l, c):
    l[:] = l[c:c + 1] + l[0:c] + l[c + 1:]
```

Three slices, two concatenations and a slice assignment, over a table of up to
256 entries, executed once per symbol. Measured on the course guest:

| Measurement | Value |
| --- | --- |
| MTF calls per benchmark call | 89,837 |
| Table size in the test stream | 145 entries |
| Instructions attributed to the MTF list operations | 1.798 G per benchmark call |
| **Instructions per MTF operation** | **≈ 20,000** |
| Share of the profile | 10.74% (18.47% including the allocator underneath) |
| Time spent in the stage | 337 ms of 3.14 s |

Twenty thousand instructions to move one byte to the front of a 145-entry
list. The accelerator does it in **one cycle**.

## 2. Why this component

- **Fixed, tiny working set.** 256 bytes, resident in the unit. No memory
  traffic, no cache pressure, no DMA.
- **Trivially regular.** One index in, one byte out, one well-defined table
  mutation. No floating point, no variable latency, no exceptions.
- **Executed constantly.** 89,837 times per benchmark call, and in bzip2
  generally once per decoded symbol.
- **Already proven in software.** Replacing the rebuild with
  `l.insert(0, l.pop(c))` removed 68% of the stage's cost and made the whole
  benchmark 12.7% faster. The hardware removes the rest.
- **Not workload-specific in the narrow sense.** MTF is a standard transform
  in bzip2, LZ77 variants, and some cache-replacement policies.

## 3. Interface

All signals synchronous to `clk`, active-low reset `rst_n`.

### Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `N` | 256 | table entries |
| `DW` | 8 | symbol width in bits |
| `IW` | 8 | index width; requires `2**IW >= N` |

### Ports

| Signal | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | clock |
| `rst_n` | in | 1 | asynchronous active-low reset |
| `load_en` | in | 1 | write one table entry |
| `load_addr` | in | `IW` = 8 | entry address |
| `load_data` | in | `DW` = 8 | entry value |
| `load_len` | in | `IW+1` = 9 | number of valid entries, 0…256 |
| `load_commit` | in | 1 | latch `load_len`, arm the table |
| `req_valid` | in | 1 | request a promotion |
| `req_index` | in | `IW` = 8 | index `c` to promote |
| `req_ready` | out | 1 | high when the table is armed |
| `rsp_valid` | out | 1 | response strobe |
| `rsp_data` | out | `DW` = 8 | the promoted symbol |
| `rsp_error` | out | 1 | `req_index >= load_len` |

### Timing

| Property | Value |
| --- | --- |
| Latency | 1 cycle (registered outputs) |
| Throughput | 1 operation per cycle, back-to-back, no bubbles |
| Stall conditions | none once armed |
| Target frequency | **200 MHz** single-cycle (see §6) |

## 4. Architecture

```
                 load_addr/load_data/load_en
                            │
                            ▼
  req_index ──┬──▶ ┌──────────────────┐
              │    │   TABLE  N x DW  │   256 x 8 flip-flops
              │    │   entry[0..N-1]  │
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
                        ▲
  req_index ──▶ ┌───────────────┐
                │  <  COMPARE   │──▶ rsp_error
  load_len ───▶ └───────────────┘

  CONTROL FSM:   S_LOAD ──load_commit──▶ S_READY ──load_commit──▶ S_LOAD
                 (accept writes)         (accept requests)
```

**Datapath.** Three elements. An `N:1` read multiplexer selects
`entry[req_index]`, which is both the response value and the value written
back to position 0. A conditional shift network of `N` 8-bit 2:1 multiplexers
performs the promotion: each entry either holds, or takes its neighbour, based
on a single comparison against `req_index`. A 9-bit magnitude comparator
performs the bounds check against the committed length.

**Control.** A two-state FSM. `S_LOAD` accepts table writes and holds
`req_ready` low; `load_commit` latches the length and moves to `S_READY`.
`S_READY` accepts one request per cycle; a further `load_commit` returns to
`S_LOAD` for the next bzip2 block. Response strobes default low and assert only
on an accepted request, so a bounds violation mutates nothing.

## 5. Hardware/software interface

Two integration options. The measured behaviour of optimization opt2 makes the
choice consequential.

### Option A — ISA extension (recommended)

Two custom instructions in the style of RISC-V `custom-0`:

| Instruction | Operands | Effect |
| --- | --- | --- |
| `mtf.load rs1, rs2` | `rs1` = index, `rs2` = value | write one table entry |
| `mtf.commit rs1` | `rs1` = length | arm the table |
| `mtf.next rd, rs1` | `rs1` = index | `rd` ← promoted symbol; table updated |

The unit sits beside the integer ALU and writes back through the normal result
path. `mtf.next` is a single-cycle instruction with no memory operand.

Software changes: a CPython extension module exposing `mtf_load(table)` and
`mtf_next(c)`, with `move_to_front` replaced by a call to the latter. The
decoder is otherwise unchanged.

### Option B — memory-mapped peripheral

A 32-bit slave on a peripheral bus (AXI4-Lite or similar):

| Offset | Access | Register |
| --- | --- | --- |
| `0x00` | W | `CTRL` — bit 0 `commit`, bit 1 `soft_reset` |
| `0x04` | W | `LEN` — table length, bits 8:0 |
| `0x08` | W | `LOAD` — bits 15:8 address, bits 7:0 data |
| `0x0C` | W | `REQ` — index; the write issues the operation |
| `0x10` | R | `RSP` — bit 8 `error`, bits 7:0 promoted symbol |
| `0x14` | R | `STATUS` — bit 0 `ready` |

Requires a small kernel driver or `/dev/mem` mapping plus the same CPython
extension module. No DMA: one index in and one byte out per operation is far
below the threshold where DMA setup would pay.

### Why the choice matters

Optimization opt2 in this project replaced `pow` with a cheaper formula and
made nbody **3.5% slower**, because reaching the cheaper operation cost a
Python-level function call. The same failure mode applies here. Per MTF
operation:

| Path | Cost per operation |
| --- | --- |
| Today, pure Python | ≈ 20,000 instructions ≈ 3.8 µs |
| Option A, custom instruction | 1 cycle ≈ 5 ns, plus the Python call to the extension |
| Option B, two bus round trips | ≈ 100–200 ns, plus the Python call |

Both dwarf the 3.8 µs being replaced, so either works here. The general lesson
stands: an accelerator whose invocation path costs more than the work it
replaces is a net loss, and this project measured exactly that outcome once.

## 6. Frequency, area and power

**Frequency.** The critical path is the `N:1` read multiplexer followed by the
shift-network write, roughly eight levels of 2:1 multiplexing plus setup. A
**200 MHz** single-cycle target is conservative on any modern process. If a
higher clock is needed, registering `sel_data` splits the path into two stages:
latency becomes 2 cycles, throughput stays at 1 operation per cycle, and the
decoder does not care about latency because it consumes each symbol before
issuing the next.

**Area.**

| Element | Size |
| --- | --- |
| Table storage | 256 × 8 = 2,048 flip-flops |
| Shift network | 2,048 8-bit-wide 2:1 mux cells |
| Read multiplexer | 256:1 × 8 bit |
| Bounds comparator | 9-bit |
| Control | 1-bit FSM + 9-bit length register |

Roughly 2 K flops and 2 K mux cells. Small next to a 32 KB L1 cache, and it is
a single shared structure rather than something replicated per core.

**Power.** The unit is clock-gated outside `S_READY` and switches only the
entries below `req_index` on each operation, so average switching is
proportional to the mean promoted index rather than to the full table.

**Energy — the defensible claim.** Peak power rises while the unit is active.
The argument is energy per operation: replacing ≈ 20,000 executed instructions,
five heap allocations and ≈ 1,450 refcounted pointer copies with one register
transfer reduces the energy required for that operation by orders of magnitude,
even at higher instantaneous power.

## 7. Expected speedup and its limit

| Basis | Value |
| --- | --- |
| Share of profile: MTF list operations | 10.74% |
| Share including the allocator underneath | 18.47% |
| **Amdahl ceiling, list operations alone** | **1.12×** |
| **Amdahl ceiling, including the allocator** | **1.23×** |
| Measured software analogue (opt1) | −12.7% time, −11.6% instructions |

At 200 MHz the hardware performs all 89,837 operations of a decode in 449 µs,
against 337 ms in software — a factor of 751 on that stage. **The stage stops
mattering entirely, and the benchmark still only gets about 1.23× faster.**
That is Amdahl's law, and stating it plainly is more useful than quoting the
751×.

### Assumptions

1. The table fits in `N = 256` entries. bzip2 guarantees this; the unit raises
   `rsp_error` rather than misbehaving if it is violated.
2. One operation per decoded symbol, which the captured trace confirms.
3. The invocation path is cheap relative to 3.8 µs — true for both integration
   options above.
4. The profile share is taken from a `--with-pydebug` interpreter. 0.372 G of
   the measured allocator saving is debug-only work that would not exist in a
   release build, so the release-build benefit is smaller. This is stated in
   the report's threats-to-validity section.

## 8. Verification

```bash
python3 gen_stimulus.py          # capture vectors from a real bzip2 decode
iverilog -Wall -g2005 -o tb tb_mtf_unit.v mtf_unit.v
vvp tb
```

`gen_stimulus.py` instruments `move_to_front` during an actual decode of
`interpreter.tar.bz2` and records the initial table plus every
(index, promoted symbol) pair. pyflate calls `move_to_front` from two places —
a 6-entry selector table and the 145-entry symbol table — and the generator
selects the busier one.

The testbench loads the captured table, streams all 89,837 requests back to
back with no bubbles, and compares every response against the value Python
produced. It additionally checks that `req_ready` stays low before the table is
armed, that it rises after `load_commit`, and that an index equal to the table
length raises `rsp_error` without mutating the table.

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
demonstrates the unit is a drop-in replacement for the function it removes, not
merely a plausible piece of logic.
