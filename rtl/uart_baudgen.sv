// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Programmable UART baud-rate generator.
//
// Produces a 16x oversampling tick `tick_x16_o` that pulses for one
// `clk_i` cycle every `(divisor_i + 1)` clocks, where the user computes
//
//     divisor = round(clk_freq_hz / (16 * baud_rate_hz)) - 1
//
// So at clk_freq = 50 MHz and baud = 115_200, divisor = 26 (the actual
// rate is 50e6 / (27*16) = 115_741, ~0.47% fast — within the 5% the
// 16x oversampler tolerates per block).
//
// A separate 1x baud tick `tick_x1_o` pulses once per 16 oversample
// ticks; the TX path uses it to clock out one bit per pulse. The RX path
// only needs the 16x tick — bit centering is done by counting samples.
//
// The divisor is sampled at reset and is then re-armable on a non-zero
// `divisor_load_i` strobe (one cycle). Holding the divisor stable while
// idle is allowed; changing it mid-frame causes a glitched frame.
//
// All counters reset cleanly on `rst_ni = 0`.

module uart_baudgen #(
  parameter int unsigned DIV_WIDTH = 16
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // Divisor for the 16x oversample. clk_freq / (16 * baud) - 1.
  input  logic [DIV_WIDTH-1:0]  divisor_i,
  input  logic                  divisor_load_i,

  output logic                  tick_x16_o,
  output logic                  tick_x1_o
);

  logic [DIV_WIDTH-1:0] cnt_q;
  logic [DIV_WIDTH-1:0] div_q;
  logic [3:0]           x16_cnt_q;

  // tick_x16: one-cycle pulse when cnt_q reaches the loaded divisor.
  assign tick_x16_o = (cnt_q == div_q);
  assign tick_x1_o  = tick_x16_o && (x16_cnt_q == 4'd15);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      cnt_q     <= '0;
      div_q     <= '0;
      x16_cnt_q <= 4'd0;
    end else begin
      if (divisor_load_i) begin
        div_q     <= divisor_i;
        cnt_q     <= '0;
        x16_cnt_q <= 4'd0;
      end else if (tick_x16_o) begin
        cnt_q     <= '0;
        x16_cnt_q <= x16_cnt_q + 4'd1;
      end else begin
        cnt_q     <= cnt_q + {{(DIV_WIDTH-1){1'b0}}, 1'b1};
      end
    end
  end

endmodule
