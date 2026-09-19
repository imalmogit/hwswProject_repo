# Build and verify the move-to-front accelerator.
#   make            -- generate stimulus, compile, simulate
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= $(shell sh -c ". $(CURDIR)/../scripts/env.sh >/dev/null 2>&1; echo \$$PY")
PYTHON   := $(if $(PYTHON),$(PYTHON),python3)

# Point these at the pyflate source and its data file.
PYFLATE_SRC  ?= ../benchmarks/bm_pyflate_opt1/run_benchmark.py
PYFLATE_DATA ?= ../benchmarks/bm_pyflate_opt1/data/interpreter.tar.bz2

STIM = stim_table.hex stim_vectors.hex stim_params.vh

all: sim

$(STIM): gen_stimulus.py
	PYFLATE_SRC=$(PYFLATE_SRC) PYFLATE_DATA=$(PYFLATE_DATA) $(PYTHON) gen_stimulus.py

tb_mtf: $(STIM) tb_mtf_unit.v mtf_unit.v
	$(IVERILOG) -Wall -g2005 -o tb_mtf tb_mtf_unit.v mtf_unit.v

sim: tb_mtf
	$(VVP) tb_mtf

lint:
	$(IVERILOG) -Wall -g2005 -o /dev/null mtf_unit.v

clean:
	rm -f tb_mtf $(STIM)

.PHONY: all sim lint clean
