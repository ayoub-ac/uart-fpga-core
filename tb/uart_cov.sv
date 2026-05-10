// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage collector for uart_top. Sticky bins recorded
// across the regression so the harness can print a single coverage line
// at end-of-test.
//
// Bins (12 total):
//   c_tx_active        : at least one TX bit transmitted (FIFO popped)
//   c_rx_active        : at least one RX byte received successfully
//   c_tx_full          : TX FIFO observed full
//   c_tx_empty         : TX FIFO observed empty
//   c_rx_full          : RX FIFO observed full
//   c_rx_empty         : RX FIFO observed empty
//   c_parity_off       : a frame was sent with parity disabled
//   c_parity_on        : a frame was sent with parity enabled (any mode)
//   c_err_frame        : frame_err flag rose at least once
//   c_err_parity       : parity_err flag rose at least once
//   c_err_overrun      : overrun flag rose at least once
//   c_break            : break_o flag rose at least once
//   c_flow_rts         : RTS de-asserted at least once due to threshold
//   c_flow_cts         : CTS observed asserted (low) at least once

module uart_cov (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        tx_full_o,
  input logic        tx_empty_o,
  input logic        rx_full_o,
  input logic        rx_empty_o,
  input logic        parity_en_i,
  input logic        frame_err_o,
  input logic        parity_err_o,
  input logic        overrun_o,
  input logic        break_o,
  input logic        rts_n_o,
  input logic        cts_n_i,
  input logic        tx_wr_en_i,
  input logic        rx_rd_en_i
);

  logic c_tx_active   /*verilator public*/;
  logic c_rx_active   /*verilator public*/;
  logic c_tx_full     /*verilator public*/;
  logic c_tx_empty    /*verilator public*/;
  logic c_rx_full     /*verilator public*/;
  logic c_rx_empty    /*verilator public*/;
  logic c_parity_off  /*verilator public*/;
  logic c_parity_on   /*verilator public*/;
  logic c_err_frame   /*verilator public*/;
  logic c_err_parity  /*verilator public*/;
  logic c_err_overrun /*verilator public*/;
  logic c_break       /*verilator public*/;
  logic c_flow_rts    /*verilator public*/;
  logic c_flow_cts    /*verilator public*/;

  // Coverage is intentionally NOT reset by rst_ni: a session-level
  // reset (between tests) must not wipe accumulated bins. The bins
  // are zero-initialised once via the `initial` block below.
  always_ff @(posedge clk_i) begin
    if (tx_wr_en_i) begin
      c_tx_active <= 1'b1;
      if (parity_en_i) c_parity_on  <= 1'b1;
      else             c_parity_off <= 1'b1;
    end
    if (rx_rd_en_i)    c_rx_active <= 1'b1;
    if (tx_full_o)     c_tx_full   <= 1'b1;
    if (tx_empty_o)    c_tx_empty  <= 1'b1;
    if (rx_full_o)     c_rx_full   <= 1'b1;
    if (rx_empty_o)    c_rx_empty  <= 1'b1;
    if (frame_err_o)   c_err_frame <= 1'b1;
    if (parity_err_o)  c_err_parity <= 1'b1;
    if (overrun_o)     c_err_overrun <= 1'b1;
    if (break_o)       c_break       <= 1'b1;
    if (rts_n_o)       c_flow_rts    <= 1'b1;
    if (!cts_n_i)      c_flow_cts    <= 1'b1;
  end

  initial begin
    c_tx_active   = 1'b0;
    c_rx_active   = 1'b0;
    c_tx_full     = 1'b0;
    c_tx_empty    = 1'b0;
    c_rx_full     = 1'b0;
    c_rx_empty    = 1'b0;
    c_parity_off  = 1'b0;
    c_parity_on   = 1'b0;
    c_err_frame   = 1'b0;
    c_err_parity  = 1'b0;
    c_err_overrun = 1'b0;
    c_break       = 1'b0;
    c_flow_rts    = 1'b0;
    c_flow_cts    = 1'b0;
  end

endmodule
