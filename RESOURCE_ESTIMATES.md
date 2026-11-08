# Resource estimates

> **Unverified estimates.** The figures in this file have not been confirmed by a recorded, reproducible synthesis run or by hardware measurement. Treat every LUT, FF, BRAM, DSP, Fmax, throughput, latency and power figure here as an unverified estimate. Run `make synth_report` with your own toolchain to get real numbers.

Numbers below are unverified estimates intended to reflect Yosys generic
synthesis (`make synth_report`), not output from a recorded run. They are
meant as pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (unverified estimates, pre-PnR)

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | ~340 LUT4 / ~170 FF / 2 BRAM at default (TX/RX FIFO 16x9). The two FIFOs alone draw ~280 FFs and Yosys folds the FIFO storage into BRAM at this depth. Expected to fit on the UP5K (5280 logic tiles); not verified. |
| Lattice ECP5 LFE5UM-25         | ~340 LUT / ~160 FF / 0 BRAM at default. ECP5's 4-input LUT primitive gives results comparable to iCE40. nextpnr-ecp5 packs tighter on PnR. |
| Xilinx Artix-7 XC7A35T         | ~410 LUT6 / ~280 FF / 0 BRAM at default. Vivado synth_design may drop the LUT count via better mapping (not measured). |
| Cyclone V 5CSEMA5F31C6         | Quartus folds the FIFO into M10K block RAMs; ALM count drops correspondingly. |
| Gowin GW1NR-9 (Tang Nano 9K)   | Not characterised here. Comparable to ECP5 with vendor flow. |

For exact LUT/FF/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`.

## What dominates the area

* **TX and RX FIFOs**: each is `DEPTH * WIDTH = 16 * 9 = 144` flops at
  default, plus pointer / level counters. Switching to a deeper FIFO
  (32, 64, 128, 256) scales the FF cost linearly until the synthesiser
  decides to drop them into a block RAM (Yosys `synth_ice40` does this
  at depth >= 16 for `WIDTH * DEPTH >= 256` bits).
* **RX deserializer state**: 9-bit `data_q` shift, 4-bit `bit_idx_q`,
  4-bit `sample_q`, 13-bit `break_cnt_q`, plus the 3-FF synchroniser.
  ~35 FFs, dominated by the break counter (which is large because we
  count oversample ticks for a full ~11-bit-time low pulse).
* **TX serializer state**: 9-bit `shift_q`, 4-bit `bit_idx_q`, plus
  the configuration shadow (data_bits / parity_en / parity_mode /
  stop_2). ~25 FFs.
* **Baud generator**: `DIV_WIDTH`-bit counter and a 4-bit oversample
  counter. ~20 FFs at default `DIV_WIDTH = 16`.
* **Sticky error flags + interrupt OR**: <10 FFs.

The optional `uart_axi4lite.sv` wrapper adds the AXI4-Lite slave
(~600 LUT for a 7-register map; unverified estimate) on top of the bare core.

## What you can do to shrink it

* **Smaller FIFO depth**: drop to 8 or even 4. The `uart_top` parameter
  `TX_FIFO_DEPTH` and `RX_FIFO_DEPTH` are independent; for a polled
  driver that consumes every byte synchronously, FIFOs of depth 4 are
  enough.
* **Drop 9-bit support**: hardwire `WIDTH = 8` in `uart_fifo` and the
  related shift registers. Saves 1 FF per FIFO entry.
* **Drop break detection**: removes the 13-bit `break_cnt_q` and a few
  LUTs. Most embedded UARTs ship without break detection; if your
  protocol doesn't need it, the saving is real.

## What you can do to push throughput

UART is inherently slow (1 bit per bit-time). The throughput is
gated by the baud rate, not the RTL. To push raw bytes/sec:

* **Increase the FIFO depth** so the host can drop a burst into TX
  without back-pressure. Useful for shorts of data over a slow link.
* **Run the FPGA clock fast and the UART slow**. The 16x oversampler
  works on the system clock; raising `clk_i` while keeping baud
  constant makes the divisor larger but does NOT change throughput
  on the wire. Use this only if you need the headroom to share the
  clock with a faster bus.

## Frequency

All figures in this section are unverified estimates; no timing analysis
has been recorded.

* iCE40 UP5K, default toolchain (Yosys + nextpnr): ~80-100 MHz typical.
  Limited by the FIFO pointer carry and the baud counter.
* ECP5: ~120-150 MHz on generic synth.
* Artix-7 -1 speed grade: ~150 MHz with Yosys, easily 200+ MHz with
  Vivado.
* Cyclone V: similar to Artix-7 with M10K-backed FIFOs.

For a 50 MHz system clock and 115_200 baud, the throughput is ~11.5 KB/s
per direction. That's standard UART territory; the RTL itself is not
the bottleneck.

## Power

Unverified estimate (not measured): 5-10 mW dynamic on iCE40 UP5K at 50 MHz, depending on
serial-line activity. The synchroniser and the FIFO storage toggle
on every byte; the FSM toggles only during active frames.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers run the vendor flow:
- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
