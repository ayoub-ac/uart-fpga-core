# Security model

`uart_top` is a transport: it does not encrypt, does not authenticate,
and does not validate payload semantics. This document lists the
hardware-level safety properties the design DOES guarantee, the
attacker model it does NOT cover, and how to harden a deployment.

## What the core defends against

### 1. Frame structure validation

* `frame_err_o` latches when the stop bit is low (a corrupted frame).
  Software must read the flag and decide what to do (drop the byte,
  resync, raise an alarm). The flag is sticky — clearing requires an
  explicit `clear_errors_i` pulse.
* `parity_err_o` latches when the configured parity does not match the
  received parity. Same sticky / explicit-clear semantics.
* `overrun_o` latches when the RX FIFO has been pushed past its capacity.
  No data is silently dropped without raising the flag.
* `break_o` latches when the RX line stays low for more than one frame
  time (~11 bit times). This is the canonical "remote sender pulled the
  line down" indication — useful as a soft-reset trigger or as a
  watchdog signal in industrial deployments.

### 2. Synchroniser hardening

The RX line is registered through a 3-FF synchroniser chain to defeat
metastability when `rx_i` arrives from a clock domain not aligned with
`clk_i`. There is no path that could carry a glitched sample through
the FSM.

### 3. Bounded counters

* The baud-generator counter is bounded to `divisor_i` and resets on
  every wrap.
* The 16x oversample counter is a 4-bit free-running counter; the FSM
  decision points (samples 7..9) are checked deterministically.
* The TX bit index and RX bit index are bounded to `data_bits_i - 1`
  by the FSM transition; an out-of-range index cannot drive the shift
  register.

The functional coverage report in `tb/uart_cov.sv` includes 14 sticky
bins covering all error paths; a regression that fails to trip any of
them blocks the gate.

## What the core does NOT cover

* **Confidentiality**: UART traffic is plaintext on the wire. If you need
  to protect the link, terminate it inside a tunnel (TLS at the host
  driver, an AES-GCM payload-layer crypto in the embedded firmware, or
  the sibling [aes-gcm-fpga-core](https://github.com/ayoub-ac/aes-gcm-fpga-core)
  if you are encrypting in hardware).
* **Authentication**: a UART has no built-in identity. An attacker with
  physical access to the wire can impersonate either endpoint. Use a
  cryptographic MAC at the firmware layer if integrity matters.
* **Replay protection**: not provided. Bind a monotonic counter into your
  firmware-layer protocol if needed.
* **Side-channel resistance**: not specifically countered. The bit-rate
  is data-independent, but power analysis on the FIFO control signals
  could in principle leak FIFO occupancy information.
* **Fault-injection on the UART FSM**: not protected. A hostile particle
  flipping a bit in the bit-index counter can corrupt one byte; the
  parity / frame-error flags will latch on the affected frame, but a
  silent corruption inside the data bits is possible if the flip lands
  in `data_q`. Triple-modular redundancy is not shipped.
* **Voltage glitching on rx_i**: a deliberately slow voltage transition
  could fool the synchroniser; mitigation is to add a Schmitt-trigger
  buffer at the pad level (FPGA tools usually expose this as an IOSTANDARD).
* **Denial of service**: an attacker holding the line low forever
  asserts `break_o` and prevents any RX. The integrator must decide
  what to do; software policy, not hardware.

## How to use the core safely

1. **Always check `frame_err_o` and `parity_err_o`** before consuming
   the corresponding RX byte. A typical driver structure is
   `if (overrun_o || frame_err_o || parity_err_o) handle_err(); else
   consume_byte()`.
2. **Hold `rst_ni` low for at least 4 cycles** after power-on and before
   the first command.
3. **If `flow_en_i` is on, wire `rts_n_o` to a real pad**. Otherwise
   the core's flow-control logic still runs, but the remote end will
   never see the back-pressure.
4. **Set `rts_thresh_i` conservatively**. If the remote takes long to
   react to RTS de-assertion, you need headroom: use
   `rts_thresh_i = RX_FIFO_DEPTH - margin` where `margin` covers
   one round-trip-time-worth of frames at your baud rate.
5. **Wipe TX/RX state after a sensitive session** by pulsing the soft
   reset (the AXI wrapper's CTRL[0] bit, or a global rst_ni cycle on
   the bare core). Working data lives in the FIFOs until then.

## Reporting issues

Found a bug, a state machine corner case we missed, or a discrepancy
with a real UART trace? Open an issue or contact the email in the
README. Coordinated disclosure welcome. We do not currently offer a
bug bounty.
