# uart-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small synthesisable industrial UART IP core in SystemVerilog with
TX/RX FIFOs, programmable baud rate, configurable framing, parity,
RTS/CTS hardware flow-control, error flags, and an optional AXI4-Lite
register-mapped wrapper.

## Why

8250/16550-style UARTs are still the default debug + control link on
every FPGA dev board, MCU, and embedded SoC. This is a clean, lint-clean,
parametrizable replacement that synthesises in ~350 LUT and verifies
against itself in cross-loopback (no external simulator model needed).

## Quickstart

```bash
git clone https://github.com/ayoub-ac/uart-fpga-core.git
cd uart-fpga-core
make lint test            # Verilator lint + loopback / cross-baud / errors
make synth_report         # SYNTH_REPORT.md across iCE40 / ECP5 / Xilinx
```

## Features

* TX/RX shift registers, bit-banged at programmable baud
* Parametrizable TX FIFO + RX FIFO (default 16, configurable up to 256)
* 16x oversampling RX with majority-vote bit centering
* Data bits 5/6/7/8/9, parity none/even/odd/mark/space, 1 or 2 stop bits
* Hardware RTS/CTS flow-control (per-side configurable threshold)
* Sticky frame-error / parity-error / overrun / break-detect flags
* Aggregated maskable interrupt (TX empty / RX non-empty / RX full / errors)
* Optional `uart_axi4lite.sv` companion: 7-register AXI4-Lite slave
  built on the sibling [axi4lite-slave-fpga-core](https://github.com/ayoub-ac/axi4lite-slave-fpga-core)

## Port table (top-level, abridged)

| Signal              | Dir | Width | Description                                              |
|---------------------|-----|-------|----------------------------------------------------------|
| `clk_i`             | in  | 1     | System clock.                                            |
| `rst_ni`            | in  | 1     | Synchronous active-low reset.                            |
| `divisor_i`         | in  | DIV_WIDTH | `clk_freq / (16 * baud) - 1`.                        |
| `divisor_load_i`    | in  | 1     | Pulse to reload divisor.                                 |
| `data_bits_i`       | in  | 4     | 5..9.                                                    |
| `parity_en_i`       | in  | 1     | Enable parity bit.                                       |
| `parity_mode_i`     | in  | 2     | 00 even, 01 odd, 10 mark, 11 space.                      |
| `stop_2_i`          | in  | 1     | 0 = 1 stop, 1 = 2 stop bits.                             |
| `flow_en_i`         | in  | 1     | Enable RTS/CTS gating.                                   |
| `rts_thresh_i`      | in  | clog2(RX_DEPTH+1) | RX level above which `rts_n_o` de-asserts.   |
| `tx_wr_en_i`        | in  | 1     | Push into TX FIFO.                                       |
| `tx_wr_data_i`      | in  | 9     | Data to push (low `data_bits_i` bits used).              |
| `rx_rd_en_i`        | in  | 1     | Pop the RX FIFO head.                                    |
| `rx_rd_data_o`      | out | 9     | RX FIFO head data.                                       |
| `frame_err_o`       | out | 1     | Sticky frame error.                                      |
| `parity_err_o`      | out | 1     | Sticky parity error.                                     |
| `overrun_o`         | out | 1     | Sticky RX FIFO overrun.                                  |
| `break_o`           | out | 1     | Sticky break detect.                                     |
| `clear_errors_i`    | in  | 1     | Clear all sticky flags.                                  |
| `irq_o`             | out | 1     | Aggregate interrupt.                                     |
| `rx_i` / `tx_o`     |     | 1     | Serial pads.                                             |
| `cts_n_i` / `rts_n_o`|    | 1     | Hardware flow-control pads (active-low).                 |

Full timing, FIFO levels, and IRQ-mask details in
[`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md).

## Headline numbers

Real numbers from `make synth_report` (Yosys 0.x, default `uart_top` with
TX/RX depth 16):

| Target           | LUT       | FF    | BRAM | Notes                  |
|------------------|-----------|-------|------|------------------------|
| iCE40 UP5K       | 340       | 168   | 2    | LUT4 generic           |
| ECP5 LFE5UM-25   | 339       | 156   | 0    | abc9 mapping           |
| Xilinx Artix-7   | 412       | 283   | 0    | Yosys generic          |

See [`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) for the breakdown
and [`SYNTH_REPORT.md`](SYNTH_REPORT.md) for the most recent run.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint            # static-check the RTL + AXI wrapper
make test            # build and run the loopback / cross-baud / error suite
```

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

Eight test groups, all running in a single `make test`:

| #  | Test                 | Coverage                                          |
|----|----------------------|---------------------------------------------------|
| 0  | FIFO saturation prep | Asserts TX/RX FIFO `full` flags                   |
| 1  | Loopback 1000 bytes  | TX A -> RX B, byte-exact at 8N1                   |
| 2  | Cross-baud loopback  | A faster than B by ~1.5%, decode still byte-exact |
| 3  | Parity inject        | XOR a bit on the line, expect `parity_err`        |
| 4  | Frame error inject   | Force stop bit low, expect `frame_err`            |
| 5  | RX overrun           | Flood past FIFO depth, expect `overrun`           |
| 6  | Break detect         | Pull line low > 1 frame time, expect `break_o`    |
| 7  | Flow control RTS/CTS | Fill RX, observe RTS de-assertion                 |
| 8  | Data widths          | 5/6/7/8/9 bits, parity even/odd/none round-trip   |

5 SVA properties bind every cycle (TX/RX FIFO empty/full coherence,
overrun-implies-full, parity-err-implies-parity-en).
14-bin functional coverage at 100%.

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source use.
- **Commercial license** for closed-source / proprietary integrations.

See [`LICENSE.md`](LICENSE.md).

## Citation

```bibtex
@misc{uart-fpga-core,
  title  = {{uart-fpga-core}: a small parametrizable UART IP core in SystemVerilog with FIFOs, RTS/CTS, and an AXI4-Lite wrapper},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/uart-fpga-core}}
}
```

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
