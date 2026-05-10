# UART FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint            verilator --lint-only on RTL (baudgen + fifo +
#                        tx + rx + top + axi wrapper + testbench glue)
#   make sim             build the UART top-level simulator
#   make test            build + run sim, check for "+PASS"
#   make synth           Yosys: ice40 + ecp5 + xilinx generic for uart_top
#   make synth_report    run all available toolchains, emit SYNTH_REPORT.md
#   make vhdl-test       GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make clean           remove build artifacts

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

RTL_CORE := \
    rtl/uart_baudgen.sv \
    rtl/uart_fifo.sv \
    rtl/uart_tx.sv \
    rtl/uart_rx.sv \
    rtl/uart_top.sv

RTL_AXI := \
    rtl/axi4lite_regfile.sv \
    rtl/axi4lite_slave.sv \
    rtl/uart_axi4lite.sv

TB_TOP := tb/uart_top_tb.sv
TB_AUX := tb/uart_assertions.sv tb/uart_cov.sv
TB_CPP := tb/sim_main.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: lint sim test synth synth_report vhdl-test clean

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module uart_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module uart_axi4lite \
	    $(RTL_CORE) $(RTL_AXI)

sim: obj_dir/Vuart_top_tb

obj_dir/Vuart_top_tb: $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module uart_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
	    -o Vuart_top_tb

test: sim
	./obj_dir/Vuart_top_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top uart_top; synth_ice40 -top uart_top; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top uart_top; synth_ecp5 -top uart_top -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top uart_top; synth_xilinx -top uart_top; stat" \
	    | tee synth_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

clean:
	rm -rf obj_dir \
	    test.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log \
	    synth_report/ SYNTH_REPORT.md
