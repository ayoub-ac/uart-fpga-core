# VHDL wrapper

`uart_top_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `uart_top` module under a VHDL-friendly interface. Use
it from a VHDL design that does not want to touch SystemVerilog
directly.

## Status

**Wrapper only.** The UART datapath (baud generator, TX/RX FSMs, FIFOs,
flow control) lives in `rtl/*.sv` and is instantiated as a SystemVerilog
black-box. Mixed-language elaboration requires a simulator or synthesiser that
supports it; the wrapper has not been verified with any specific tool.

No pure VHDL re-implementation of the datapath exists.

## Usage

### Vivado / Quartus / Diamond

```tcl
# Vivado
read_verilog -sv {rtl/uart_baudgen.sv rtl/uart_fifo.sv rtl/uart_tx.sv \
                  rtl/uart_rx.sv rtl/uart_top.sv}
read_vhdl -vhdl2008 vhdl_wrapper/uart_top_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/uart_baudgen.sv rtl/uart_fifo.sv rtl/uart_tx.sv rtl/uart_rx.sv rtl/uart_top.sv
vcom -2008 vhdl_wrapper/uart_top_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

`make vhdl-test` wraps a smoke test that compiles both sides; run it
from the repository root. The target is a no-op (with a notice) if
`ghdl` is not on `$PATH`.

## What this wrapper does NOT change

* Latency, throughput, area: intended to be identical to `uart_top.sv`; not verified.
* Endianness: same as the SV core (LSB-first on the wire).
* Reset polarity: still active-low synchronous (`rst_ni`).
