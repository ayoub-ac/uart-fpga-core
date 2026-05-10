# Port description

Detailed handshake, framing, and timing for `uart_top` and the
optional `uart_axi4lite` wrapper.

## Reset

`rst_ni` is **synchronous active-low**. Hold it low for at least 4
clock cycles before the first command. After de-assertion, the TX
output rests at 1 (mark idle), all FIFOs are empty, and the baud
generator is armed — but pulse `divisor_load_i` once with the desired
divisor before driving any frames.

## Baud generator

Divisor is computed as

```
divisor = round(clk_freq_hz / (16 * baud_rate_hz)) - 1
```

For `clk = 50 MHz` and `baud = 115_200`: `divisor = 26`. Actual rate
is `50e6 / (27 * 16) = 115_741`, ~0.47% fast. The 16x oversampler with
mid-bit majority vote tolerates up to roughly **2% accumulated drift
across one frame**, so any divisor that lands within that bound is
reliable.

`divisor_load_i = 1` resets the internal sample / bit counters and
loads the new divisor on the next clock edge. Changing divisor
mid-frame causes a glitched frame; gate the change on `tx_empty_o`
and `rx_empty_o` if you care.

## TX path

```
clk_i               |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
tx_full_o           ‾‾|________________________________
tx_wr_en_i          ___|‾‾|_____________________________
tx_wr_data_i        ___|byte|___________________________
tx_o                ‾‾‾‾‾‾‾|_______________ data ... stop ‾‾‾
                          start         (bit_time = (divisor+1) * 16 cycles)
```

Push by asserting `tx_wr_en_i` for one cycle with `tx_wr_data_i`. The
push is dropped if `tx_full_o = 1`. The serializer pulls from the
FIFO whenever it is idle (`tx_o = 1` for at least one bit time).

For 9-bit data mode, the 9 LSBs of `tx_wr_data_i` are used; bit 8
is the high data bit. For shorter data widths (5/6/7/8) the high bits
of `tx_wr_data_i` are ignored.

## RX path

```
clk_i               |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
rx_i                ‾‾‾‾|________start_data...stop‾‾‾‾‾‾‾‾‾‾‾‾
                       falling-edge detect
data_valid (internal) _________________________|‾|________
rx_empty_o          ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|________
rx_rd_en_i          ___________________________________|‾‾|__
rx_rd_data_o        _________________________________|byte|__
```

The deserializer:

1. Synchronises `rx_i` through a 3-FF chain.
2. Detects a high->low edge while idle. Waits 8 oversample ticks
   (= mid of start bit). If the line is still 0, locks on; otherwise
   abandons (rejects glitches).
3. For each data bit, captures three samples around bit-centre
   (oversample ticks 7, 8, 9) and majority-votes them.
4. After the data bits, samples parity (if enabled), then the first
   stop bit. If the stop bit is 0, `frame_err_o` latches. If parity
   does not match, `parity_err_o` latches. Otherwise the byte is
   pushed into the RX FIFO.
5. Returns to IDLE 6 oversample ticks after the stop-bit decision
   so the next falling-edge can be caught early — this is what gives
   the design its drift tolerance across frames.

## Error flags

All four error flags (`frame_err_o`, `parity_err_o`, `overrun_o`,
`break_o`) are **sticky**: once raised, they stay until
`clear_errors_i` is pulsed for one cycle. This is the standard
software-driven model where the driver reads the status, decides
what to do, then clears.

`overrun_o` triggers when an RX frame has been correctly decoded but
the RX FIFO is full at the moment of the push — the byte is dropped
and the flag rises.

`break_o` triggers when the RX line stays low for >= 11 bit times
(approximately one frame at 8N1). The detection re-arms after the
line returns to 1.

## Hardware flow control (RTS / CTS)

* `rts_n_o` is asserted (low) when the RX FIFO has room: specifically,
  when the level is at or below `rts_thresh_i`. It de-asserts (goes
  high) when the level rises past the threshold so the remote stops
  sending.
* `cts_n_i` is the input from the remote. With `flow_en_i = 1`, the TX
  serializer will not start a new frame while `cts_n_i` is high. A
  frame already in flight runs to completion.

A typical full-duplex pairing crosses the wires: A's `rts_n_o`
connects to B's `cts_n_i`, and vice versa.

## Interrupt aggregation

`irq_o` is a bitwise OR of:

* `rx_irq_en_i      && !rx_empty_o`       (RX FIFO has at least one byte)
* `rx_full_irq_en_i && rx_full_o`         (RX FIFO is full — stop sending)
* `tx_empty_irq_en_i && tx_empty_o`       (TX FIFO drained — refill needed)
* `err_irq_en_i      && (any sticky error)` (frame / parity / overrun / break)

Each enable is independent. The interrupt is level-sensitive; clear it
by reading the data, clearing the error flag, or refilling the FIFO.

## AXI4-Lite wrapper register map

`uart_axi4lite.sv` exposes 7 32-bit registers:

| Offset | Reg        | Attr | Description                                      |
|--------|------------|------|--------------------------------------------------|
| 0x00   | CTRL       | RW   | Soft-reset bit / flow_en / parity / data_bits / IRQ enables |
| 0x04   | DIV        | RW   | Baud divisor; write triggers reload              |
| 0x08   | RTS_THRESH | RW   | RX FIFO level above which RTS de-asserts         |
| 0x0C   | STATUS     | RO   | TX/RX flags + levels + error bits + IRQ          |
| 0x10   | ERR_CLEAR  | W1C  | Write any value to clear all sticky error flags  |
| 0x14   | TX_DATA    | RW   | Write to push into TX FIFO                       |
| 0x18   | RX_DATA    | RC   | Read pops the RX FIFO head                       |

CTRL bit layout:

| Bit   | Field           |
|-------|-----------------|
| [0]   | soft_reset      |
| [1]   | flow_en         |
| [2]   | parity_en       |
| [4:3] | parity_mode (00 even, 01 odd, 10 mark, 11 space) |
| [5]   | stop_2          |
| [9:6] | data_bits (5..9) |
| [10]  | tx_empty_irq_en |
| [11]  | rx_irq_en       |
| [12]  | rx_full_irq_en  |
| [13]  | err_irq_en      |

STATUS bit layout:

| Bit     | Field                              |
|---------|------------------------------------|
| [0]     | tx_full                            |
| [1]     | tx_empty                           |
| [2]     | rx_full                            |
| [3]     | rx_empty                           |
| [4]     | frame_err                          |
| [5]     | parity_err                         |
| [6]     | overrun                            |
| [7]     | break                              |
| [15:8]  | tx_level (zero-padded)             |
| [23:16] | rx_level (zero-padded)             |
| [24]    | cts_n (input from remote)          |
| [25]    | rts_n (current RTS state)          |
| [26]    | irq                                |

Out-of-range / mis-aligned accesses receive DECERR per AXI4-Lite §A8.1.1.
