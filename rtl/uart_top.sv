// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// UART top-level combining baud generator, TX path (FIFO + serializer),
// RX path (deserializer + FIFO), error flags, and RTS/CTS hardware
// flow-control logic.
//
// Frame configuration is set on the configuration ports and is sampled
// at the start of every TX frame and at the start-of-frame edge of
// every RX frame, so software can change baud / parity / data bits
// between sessions without reset.
//
// Errors latch into sticky status bits (`frame_err_o`, `parity_err_o`,
// `overrun_o`, `break_o`). The integrator clears them by pulsing
// `clear_errors_i` for one cycle (typical use: software writes a
// W1C status register on the AXI wrapper).
//
// The interrupt output `irq_o` is a bitwise-OR of:
//   * RX FIFO non-empty  AND rx_irq_en_i
//   * RX FIFO full       AND rx_full_irq_en_i
//   * TX FIFO empty      AND tx_empty_irq_en_i
//   * Any latched error  AND err_irq_en_i
//
// RTS / CTS:
//   * `rts_n_o` is asserted (low) by the receiver when the RX FIFO
//     occupancy is at or below `rts_thresh_i`. It de-asserts (high)
//     when occupancy crosses above the threshold so the upstream stops
//     sending. This is "active-low" per RS-232 convention.
//   * `cts_n_i` is the input from the remote end. When `flow_en_i` is
//     set the TX path will not start a new frame while `cts_n_i` is
//     high. A frame already in flight runs to completion.

module uart_top #(
  parameter int unsigned TX_FIFO_DEPTH = 16,
  parameter int unsigned RX_FIFO_DEPTH = 16,
  parameter int unsigned DIV_WIDTH     = 16
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  // Baud / frame configuration. Sampled at frame boundaries.
  input  logic [DIV_WIDTH-1:0]              divisor_i,
  input  logic                              divisor_load_i,
  input  logic [3:0]                        data_bits_i,    // 5..9
  input  logic                              parity_en_i,
  input  logic [1:0]                        parity_mode_i,  // 00=even 01=odd 10=mark 11=space
  input  logic                              stop_2_i,
  input  logic                              flow_en_i,
  input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rts_thresh_i,

  // TX user-side FIFO push.
  input  logic                              tx_wr_en_i,
  input  logic [8:0]                        tx_wr_data_i,
  output logic                              tx_full_o,
  output logic                              tx_empty_o,
  output logic [$clog2(TX_FIFO_DEPTH+1)-1:0] tx_level_o,

  // RX user-side FIFO pop.
  input  logic                              rx_rd_en_i,
  output logic [8:0]                        rx_rd_data_o,
  output logic                              rx_full_o,
  output logic                              rx_empty_o,
  output logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_level_o,

  // Status. `*_o` flags latch sticky until `clear_errors_i`.
  output logic                              frame_err_o,
  output logic                              parity_err_o,
  output logic                              overrun_o,
  output logic                              break_o,
  input  logic                              clear_errors_i,

  // Interrupt enables and aggregate IRQ.
  input  logic                              rx_irq_en_i,
  input  logic                              rx_full_irq_en_i,
  input  logic                              tx_empty_irq_en_i,
  input  logic                              err_irq_en_i,
  output logic                              irq_o,

  // Serial pads.
  input  logic                              rx_i,
  output logic                              tx_o,
  input  logic                              cts_n_i,
  output logic                              rts_n_o
);

  // ---------------------------------------------------------------------
  // Baud generator.
  // ---------------------------------------------------------------------
  logic tick_x16;
  logic tick_x1;
  uart_baudgen #(.DIV_WIDTH(DIV_WIDTH)) u_baud (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .divisor_i      (divisor_i),
    .divisor_load_i (divisor_load_i),
    .tick_x16_o     (tick_x16),
    .tick_x1_o      (tick_x1)
  );

  // ---------------------------------------------------------------------
  // TX path: FIFO -> serializer.
  // ---------------------------------------------------------------------
  logic        tx_fifo_empty;
  logic [8:0]  tx_fifo_data;
  logic        tx_data_ready;
  logic        tx_busy;
  logic [$clog2(TX_FIFO_DEPTH+1)-1:0] tx_lvl;

  // Pop the head of the TX FIFO when the serializer is ready and we have
  // a frame queued.
  logic tx_pop;
  assign tx_pop = !tx_fifo_empty && tx_data_ready;

  uart_fifo #(.DEPTH(TX_FIFO_DEPTH), .WIDTH(9)) u_txf (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .wr_en_i   (tx_wr_en_i),
    .wr_data_i (tx_wr_data_i),
    .rd_en_i   (tx_pop),
    .rd_data_o (tx_fifo_data),
    .empty_o   (tx_fifo_empty),
    .full_o    (tx_full_o),
    .level_o   (tx_lvl)
  );
  assign tx_empty_o = tx_fifo_empty;
  assign tx_level_o = tx_lvl;

  uart_tx u_tx (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .tick_x1_i     (tick_x1),
    .data_bits_i   (data_bits_i),
    .parity_en_i   (parity_en_i),
    .parity_mode_i (parity_mode_i),
    .stop_2_i      (stop_2_i),
    .flow_en_i     (flow_en_i),
    .cts_n_i       (cts_n_i),
    .data_valid_i  (!tx_fifo_empty),
    .data_ready_o  (tx_data_ready),
    .data_i        (tx_fifo_data),
    .tx_o          (tx_o),
    .busy_o        (tx_busy)
  );

  // ---------------------------------------------------------------------
  // RX path: deserializer -> FIFO.
  // ---------------------------------------------------------------------
  logic       rx_data_valid;
  logic [8:0] rx_data;
  logic       rx_frame_err_pulse;
  logic       rx_parity_err_pulse;
  logic       rx_break_pulse;
  logic       rx_busy;
  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_lvl;
  logic       rx_fifo_full;

  uart_rx u_rx (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .tick_x16_i    (tick_x16),
    .data_bits_i   (data_bits_i),
    .parity_en_i   (parity_en_i),
    .parity_mode_i (parity_mode_i),
    .stop_2_i      (stop_2_i),
    .rx_i          (rx_i),
    .data_valid_o  (rx_data_valid),
    .data_o        (rx_data),
    .frame_err_o   (rx_frame_err_pulse),
    .parity_err_o  (rx_parity_err_pulse),
    .break_o       (rx_break_pulse),
    .busy_o        (rx_busy)
  );

  // RX FIFO. A push to a full FIFO sets the overrun flag and is
  // dropped (the FIFO module already gates push on !full).
  logic rx_overrun_pulse;
  assign rx_overrun_pulse = rx_data_valid && rx_fifo_full;

  uart_fifo #(.DEPTH(RX_FIFO_DEPTH), .WIDTH(9)) u_rxf (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .wr_en_i   (rx_data_valid),
    .wr_data_i (rx_data),
    .rd_en_i   (rx_rd_en_i),
    .rd_data_o (rx_rd_data_o),
    .empty_o   (rx_empty_o),
    .full_o    (rx_fifo_full),
    .level_o   (rx_lvl)
  );
  assign rx_full_o  = rx_fifo_full;
  assign rx_level_o = rx_lvl;

  // ---------------------------------------------------------------------
  // Sticky error flags.
  // ---------------------------------------------------------------------
  logic frame_err_q;
  logic parity_err_q;
  logic overrun_q;
  logic break_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      frame_err_q  <= 1'b0;
      parity_err_q <= 1'b0;
      overrun_q    <= 1'b0;
      break_q      <= 1'b0;
    end else begin
      if (clear_errors_i) begin
        frame_err_q  <= 1'b0;
        parity_err_q <= 1'b0;
        overrun_q    <= 1'b0;
        break_q      <= 1'b0;
      end else begin
        if (rx_frame_err_pulse)  frame_err_q  <= 1'b1;
        if (rx_parity_err_pulse) parity_err_q <= 1'b1;
        if (rx_overrun_pulse)    overrun_q    <= 1'b1;
        if (rx_break_pulse)      break_q      <= 1'b1;
      end
    end
  end
  assign frame_err_o  = frame_err_q;
  assign parity_err_o = parity_err_q;
  assign overrun_o    = overrun_q;
  assign break_o      = break_q;

  // ---------------------------------------------------------------------
  // RTS: assert (low) when RX FIFO has room, de-assert when above thresh.
  // ---------------------------------------------------------------------
  // rts_n_o = 0 (asserted) means "I'm ready, send more".
  // rts_n_o = 1 (de-asserted) means "FIFO almost full, stop sending".
  assign rts_n_o = (rx_lvl > rts_thresh_i);

  // ---------------------------------------------------------------------
  // Aggregate IRQ.
  // ---------------------------------------------------------------------
  logic any_err;
  assign any_err = frame_err_q | parity_err_q | overrun_q | break_q;
  assign irq_o   = (rx_irq_en_i      && !rx_empty_o) ||
                   (rx_full_irq_en_i && rx_fifo_full) ||
                   (tx_empty_irq_en_i && tx_fifo_empty) ||
                   (err_irq_en_i      && any_err);

  // Tie-off unused.
  logic _unused;
  assign _unused = tx_busy | rx_busy;

endmodule
