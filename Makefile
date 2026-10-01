#============================================================================
# rv32i-cpu -- build, simulate, differential verification, lint
#
#   make lint     Verilator --lint-only + Icarus syntax check (must be clean)
#   make prog     assemble tb/programs/*.S into sim/*.hex
#   make sim      run every program on the RTL, write sim/rtl_*.log/.state
#   make iss      run every program on the reference model, sim/iss_*.log
#   make diff     line-diff the logs and compare architectural state
#   make unit     run the module level self-checking testbenches
#   make random   constrained random instruction streams (differential)
#   make cov      instruction coverage report
#   make all      lint + unit + prog + sim + iss + diff + random + cov
#   make wave P=smoke   open the waveform of one program in GTKWave
#   make syn      Yosys synthesis / resource report (needs yosys installed)
#   make clean
#
# The assembler and the reference model are the independent RV32I tools of the
# neighbouring rvai project.  Point RVAI_DIR elsewhere (or run `make vendor`)
# if you need this project to be self contained.
#============================================================================

# The assembler and the reference model came from the neighbouring rvai
# project during development.  A checkout of this repository uses the vendored
# copy instead, so the project builds standalone: `make vendor` refreshes it
# from ../rvai/sw when that project is present.
RVAI_DIR ?= $(firstword $(wildcard tools/vendor ../rvai/sw))

IVL  ?= iverilog
VVP  ?= vvp
VL   ?= verilator
PY   ?= python3
GTKW ?= gtkwave

BUILD := build
INC   := -I rtl/include
IVLFLAGS := -g2005 -Wall -Wno-timescale $(INC)

RTL := \
	rtl/alu/rv32i_alu.v \
	rtl/alu/rv32i_brcmp.v \
	rtl/regfile/rv32i_regfile.v \
	rtl/control/rv32i_immgen.v \
	rtl/control/rv32i_decoder.v \
	rtl/control/rv32i_hazard.v \
	rtl/core/rv32i_cpu.v \
	rtl/memory/rv32i_ram.v \
	rtl/soc/rv32i_soc.v

TB_SOC  := tb/tb_rv32i.v
TB_UNIT := $(wildcard tb/unit/tb_*.v)
UNITS   := $(basename $(notdir $(TB_UNIT)))

PROGS := $(wildcard tb/programs/*.S)
NAMES := $(basename $(notdir $(PROGS)))

# programs that end in an intentional trap are compared against a checked in
# expectation file instead of the reference model (the model is byte granular
# and, per the RTL specification, does not trap on misaligned accesses)
EXPECTED := $(wildcard tb/programs/*.expected)
EXP_NAMES := $(basename $(notdir $(EXPECTED)))

.PHONY: all lint build prog sim iss diff unit random cov wave syn vendor figures clean help

all: lint unit prog sim iss diff random cov

help:
	@sed -n '2,25p' Makefile

$(BUILD):
	@mkdir -p $(BUILD)

#----------------------------------------------------------------------------
# lint / syntax
#----------------------------------------------------------------------------
lint: | $(BUILD)
	@echo "== iverilog syntax check =="
	$(IVL) $(IVLFLAGS) -o $(BUILD)/lint.vvp $(RTL) $(TB_SOC)
	@echo "== verilator lint =="
	$(VL) --lint-only -Wall -Wno-DECLFILENAME +incdir+rtl/include \
	    --top-module rv32i_soc $(RTL)
	@echo "lint: clean"

#----------------------------------------------------------------------------
# SoC level simulation
#----------------------------------------------------------------------------
$(BUILD)/tb_rv32i.vvp: $(RTL) $(TB_SOC) | $(BUILD)
	$(IVL) $(IVLFLAGS) -s tb_rv32i -o $@ $(RTL) $(TB_SOC)

prog: $(addprefix $(BUILD)/,$(addsuffix .hex,$(NAMES)))

lintasm:
	@$(PY) tools/lint_asm.py $(PROGS)
	@echo "lintasm: all program immediates in range"

# The bundled assembler does not range check I/S type immediates, so every
# program is linted first: a silently truncated immediate would make a directed
# test check the wrong value and hide a real failure.
$(BUILD)/%.hex: tb/programs/%.S | $(BUILD)
	@$(PY) tools/lint_asm.py $< || exit 1
	$(PY) $(RVAI_DIR)/asm.py $< -o $@ --map $(BUILD)/$*.map

# One program at a time: every run shares build/image.hex, which the elaborated
# RAM initialisation reads.
sim: $(BUILD)/tb_rv32i.vvp prog
	@set -e; for n in $(NAMES); do \
	    cp $(BUILD)/$$n.hex $(BUILD)/image.hex; \
	    printf '  sim %-22s' $$n; \
	    $(VVP) $(BUILD)/tb_rv32i.vvp +log=$(BUILD)/rtl_$$n.log \
	           +state=$(BUILD)/rtl_$$n.state > $(BUILD)/rtl_$$n.out 2>&1 \
	        || { echo FAIL; cat $(BUILD)/rtl_$$n.out; exit 1; }; \
	    tail -1 $(BUILD)/rtl_$$n.out; \
	done

iss: prog
	@for n in $(NAMES); do \
	    printf '  iss %-22s' $$n; \
	    $(PY) $(RVAI_DIR)/iss.py $(BUILD)/$$n.hex --log $(BUILD)/iss_$$n.log > /dev/null; \
	    echo "ok"; \
	done

# run_diff.py decides each program: log equality with the model, the program's
# own self-check verdict, and the full architectural state comparison.  A
# program that fails its own check is a failure even if the model agrees.
diff: sim iss
	@$(PY) tools/run_diff.py --build $(BUILD) --names "$(NAMES)" --iss-dir $(RVAI_DIR)

#----------------------------------------------------------------------------
# module level unit tests
#----------------------------------------------------------------------------
unit: | $(BUILD)
	@set -e; for u in $(UNITS); do \
	    printf '  unit %-20s' $$u; \
	    $(IVL) $(IVLFLAGS) -s $$u -o $(BUILD)/$$u.vvp $(RTL) tb/unit/$$u.v > $(BUILD)/$$u.build 2>&1 \
	        || { echo "BUILD FAIL"; cat $(BUILD)/$$u.build; exit 1; }; \
	    $(VVP) $(BUILD)/$$u.vvp > $(BUILD)/$$u.out 2>&1 \
	        || { echo "FAIL"; cat $(BUILD)/$$u.out; exit 1; }; \
	    grep -E "PASS|FAIL" $(BUILD)/$$u.out | head -1; \
	done

#----------------------------------------------------------------------------
# constrained random differential regression
#----------------------------------------------------------------------------
SEEDS ?= 100
random: $(BUILD)/tb_rv32i.vvp | $(BUILD)
	@$(PY) tools/run_random.py --seeds $(SEEDS) --build $(BUILD) \
	    --vvp "$(VVP) $(BUILD)/tb_rv32i.vvp" --iss-dir $(RVAI_DIR)

cov: $(BUILD)/tb_rv32i.vvp prog
	@$(PY) tools/coverage.py --build $(BUILD) --names "$(NAMES)" \
	    --vvp "$(VVP) $(BUILD)/tb_rv32i.vvp"

#----------------------------------------------------------------------------
# waveforms
#----------------------------------------------------------------------------
wave: $(BUILD)/tb_rv32i.vvp prog
	@cp $(BUILD)/$(P).hex $(BUILD)/image.hex
	@$(VVP) $(BUILD)/tb_rv32i.vvp +log=$(BUILD)/rtl_$(P).log \
	    +state=$(BUILD)/rtl_$(P).state +dump_vcd > /dev/null
	$(GTKW) $(BUILD)/tb_rv32i.vcd &

#----------------------------------------------------------------------------
# documentation figures
#----------------------------------------------------------------------------
# The two figures are checked in under docs/figures; this target regenerates
# them and needs Pillow (any Python with PIL works, e.g. a venv or the system
# python3 with `pip install pillow`).
figures:
	@$(PY) tools/make_figures.py || \
	    echo "figures: needs Pillow; the checked-in PNGs in docs/figures are unaffected"

#----------------------------------------------------------------------------
# synthesis (optional)
#----------------------------------------------------------------------------
syn:
	@command -v yosys > /dev/null || { \
	    echo "yosys not installed: see syn/README.md for what this target does"; exit 1; }
	yosys -q syn/rv32i_soc.ys

#----------------------------------------------------------------------------
# self containment
#----------------------------------------------------------------------------
vendor: | $(BUILD)
	@mkdir -p tools/vendor
	cp ../rvai/sw/asm.py ../rvai/sw/iss.py tools/vendor/
	@echo "tools/vendor refreshed from ../rvai/sw"
	@echo "  $$(shasum -a 256 tools/vendor/*.py | awk '{print $$1}' | tr '\n' ' ')"

clean:
	rm -f $(BUILD)/*.vvp $(BUILD)/*.vcd $(BUILD)/*.out $(BUILD)/*.log \
	      $(BUILD)/*.hex $(BUILD)/*.map $(BUILD)/*.state $(BUILD)/*.build \
	      $(BUILD)/*.json
	@rm -rf $(BUILD)/random
