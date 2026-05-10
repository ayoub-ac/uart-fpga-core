// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Top-level testbench wrapper for uart_top.
//
// Two UART instances are wired in a cross-loopback:
//
//   tx_a -> rx_b  (with optional fault injection on the line)
//   tx_b -> rx_a
//
// The C++ harness drives both ends, pushing bytes into TX FIFO A and
// expecting them out of RX FIFO B (and vice versa). Independent
// configuration ports allow the harness to test cross-baud (5%
// mismatch) and parity / frame-error injection.
//
// `inject_*` knobs let the harness flip individual bits on the link or
// extend a low pulse for break detection.

module uart_top_tb #(
  parameter int unsigned TX_FIFO_DEPTH = 16,
  parameter int unsigned RX_FIFO_DEPTH = 16,
  parameter int unsigned DIV_WIDTH     = 16
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  // Configuration for instance A.
  input  logic [DIV_WIDTH-1:0]      a_divisor_i,
  input  logic                      a_divisor_load_i,
  input  logic [3:0]                a_data_bits_i,
  input  logic                      a_parity_en_i,
  input  logic [1:0]                a_parity_mode_i,
  input  logic                      a_stop_2_i,
  input  logic                      a_flow_en_i,
  input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] a_rts_thresh_i,
  input  logic                      a_tx_wr_en_i,
  input  logic [8:0]                a_tx_wr_data_i,
  output logic                      a_tx_full_o,
  output logic                      a_tx_empty_o,
  output logic [$clog2(TX_FIFO_DEPTH+1)-1:0] a_tx_level_o,
  input  logic                      a_rx_rd_en_i,
  output logic [8:0]                a_rx_rd_data_o,
  output logic                      a_rx_full_o,
  output logic                      a_rx_empty_o,
  output logic [$clog2(RX_FIFO_DEPTH+1)-1:0] a_rx_level_o,
  output logic                      a_frame_err_o,
  output logic                      a_parity_err_o,
  output logic                      a_overrun_o,
  output logic                      a_break_o,
  input  logic                      a_clear_errors_i,
  input  logic                      a_rx_irq_en_i,
  input  logic                      a_rx_full_irq_en_i,
  input  logic                      a_tx_empty_irq_en_i,
  input  logic                      a_err_irq_en_i,
  output logic                      a_irq_o,
  output logic                      a_rts_n_o,

  // Configuration for instance B.
  input  logic [DIV_WIDTH-1:0]      b_divisor_i,
  input  logic                      b_divisor_load_i,
  input  logic [3:0]                b_data_bits_i,
  input  logic                      b_parity_en_i,
  input  logic [1:0]                b_parity_mode_i,
  input  logic                      b_stop_2_i,
  input  logic                      b_flow_en_i,
  input  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] b_rts_thresh_i,
  input  logic                      b_tx_wr_en_i,
  input  logic [8:0]                b_tx_wr_data_i,
  output logic                      b_tx_full_o,
  output logic                      b_tx_empty_o,
  output logic [$clog2(TX_FIFO_DEPTH+1)-1:0] b_tx_level_o,
  input  logic                      b_rx_rd_en_i,
  output logic [8:0]                b_rx_rd_data_o,
  output logic                      b_rx_full_o,
  output logic                      b_rx_empty_o,
  output logic [$clog2(RX_FIFO_DEPTH+1)-1:0] b_rx_level_o,
  output logic                      b_frame_err_o,
  output logic                      b_parity_err_o,
  output logic                      b_overrun_o,
  output logic                      b_break_o,
  input  logic                      b_clear_errors_i,
  input  logic                      b_rx_irq_en_i,
  input  logic                      b_rx_full_irq_en_i,
  input  logic                      b_tx_empty_irq_en_i,
  input  logic                      b_err_irq_en_i,
  output logic                      b_irq_o,
  output logic                      b_rts_n_o,

  // Fault injection knobs on the A->B link (XOR mask, force-low).
  input  logic                      inject_xor_a_to_b_i,
  input  logic                      inject_force_low_a_to_b_i
);

  logic tx_a, tx_b;
  logic rx_a, rx_b;

  // Cross-link with optional fault injection on A->B side.
  // - inject_xor inverts the bit (causes a parity / frame error
  //   depending on which bit it lands on).
  // - inject_force_low pins the line at 0 for break detection.
  logic a_to_b;
  assign a_to_b = inject_force_low_a_to_b_i ? 1'b0 :
                  (tx_a ^ inject_xor_a_to_b_i);
  assign rx_b   = a_to_b;
  assign rx_a   = tx_b;

  uart_top #(
    .TX_FIFO_DEPTH (TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH (RX_FIFO_DEPTH),
    .DIV_WIDTH     (DIV_WIDTH)
  ) u_a (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .divisor_i          (a_divisor_i),
    .divisor_load_i     (a_divisor_load_i),
    .data_bits_i        (a_data_bits_i),
    .parity_en_i        (a_parity_en_i),
    .parity_mode_i      (a_parity_mode_i),
    .stop_2_i           (a_stop_2_i),
    .flow_en_i          (a_flow_en_i),
    .rts_thresh_i       (a_rts_thresh_i),
    .tx_wr_en_i         (a_tx_wr_en_i),
    .tx_wr_data_i       (a_tx_wr_data_i),
    .tx_full_o          (a_tx_full_o),
    .tx_empty_o         (a_tx_empty_o),
    .tx_level_o         (a_tx_level_o),
    .rx_rd_en_i         (a_rx_rd_en_i),
    .rx_rd_data_o       (a_rx_rd_data_o),
    .rx_full_o          (a_rx_full_o),
    .rx_empty_o         (a_rx_empty_o),
    .rx_level_o         (a_rx_level_o),
    .frame_err_o        (a_frame_err_o),
    .parity_err_o       (a_parity_err_o),
    .overrun_o          (a_overrun_o),
    .break_o            (a_break_o),
    .clear_errors_i     (a_clear_errors_i),
    .rx_irq_en_i        (a_rx_irq_en_i),
    .rx_full_irq_en_i   (a_rx_full_irq_en_i),
    .tx_empty_irq_en_i  (a_tx_empty_irq_en_i),
    .err_irq_en_i       (a_err_irq_en_i),
    .irq_o              (a_irq_o),
    .rx_i               (rx_a),
    .tx_o               (tx_a),
    .cts_n_i            (b_rts_n_o),  // B drives RTS, A treats it as CTS
    .rts_n_o            (a_rts_n_o)
  );

  uart_top #(
    .TX_FIFO_DEPTH (TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH (RX_FIFO_DEPTH),
    .DIV_WIDTH     (DIV_WIDTH)
  ) u_b (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .divisor_i          (b_divisor_i),
    .divisor_load_i     (b_divisor_load_i),
    .data_bits_i        (b_data_bits_i),
    .parity_en_i        (b_parity_en_i),
    .parity_mode_i      (b_parity_mode_i),
    .stop_2_i           (b_stop_2_i),
    .flow_en_i          (b_flow_en_i),
    .rts_thresh_i       (b_rts_thresh_i),
    .tx_wr_en_i         (b_tx_wr_en_i),
    .tx_wr_data_i       (b_tx_wr_data_i),
    .tx_full_o          (b_tx_full_o),
    .tx_empty_o         (b_tx_empty_o),
    .tx_level_o         (b_tx_level_o),
    .rx_rd_en_i         (b_rx_rd_en_i),
    .rx_rd_data_o       (b_rx_rd_data_o),
    .rx_full_o          (b_rx_full_o),
    .rx_empty_o         (b_rx_empty_o),
    .rx_level_o         (b_rx_level_o),
    .frame_err_o        (b_frame_err_o),
    .parity_err_o       (b_parity_err_o),
    .overrun_o          (b_overrun_o),
    .break_o            (b_break_o),
    .clear_errors_i     (b_clear_errors_i),
    .rx_irq_en_i        (b_rx_irq_en_i),
    .rx_full_irq_en_i   (b_rx_full_irq_en_i),
    .tx_empty_irq_en_i  (b_tx_empty_irq_en_i),
    .err_irq_en_i       (b_err_irq_en_i),
    .irq_o              (b_irq_o),
    .rx_i               (rx_b),
    .tx_o               (tx_b),
    .cts_n_i            (a_rts_n_o),  // A drives RTS, B treats it as CTS
    .rts_n_o            (b_rts_n_o)
  );

  // ----------------------------------------------------------------
  // SVA + functional coverage on instance A.
  // ----------------------------------------------------------------
  uart_assertions #(
    .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
  ) u_assert_a (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .tx_o           (tx_a),
    .tx_level_o     (a_tx_level_o),
    .tx_full_o      (a_tx_full_o),
    .tx_empty_o     (a_tx_empty_o),
    .rx_level_o     (a_rx_level_o),
    .rx_full_o      (a_rx_full_o),
    .rx_empty_o     (a_rx_empty_o),
    .parity_en_i    (a_parity_en_i),
    .parity_err_o   (a_parity_err_o),
    .overrun_o      (a_overrun_o),
    .clear_errors_i (a_clear_errors_i)
  );

  uart_assertions #(
    .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
  ) u_assert_b (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .tx_o           (tx_b),
    .tx_level_o     (b_tx_level_o),
    .tx_full_o      (b_tx_full_o),
    .tx_empty_o     (b_tx_empty_o),
    .rx_level_o     (b_rx_level_o),
    .rx_full_o      (b_rx_full_o),
    .rx_empty_o     (b_rx_empty_o),
    .parity_en_i    (b_parity_en_i),
    .parity_err_o   (b_parity_err_o),
    .overrun_o      (b_overrun_o),
    .clear_errors_i (b_clear_errors_i)
  );

  uart_cov u_cov (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .tx_full_o    (a_tx_full_o),
    .tx_empty_o   (a_tx_empty_o),
    .rx_full_o    (b_rx_full_o),
    .rx_empty_o   (b_rx_empty_o),
    .parity_en_i  (a_parity_en_i),
    .frame_err_o  (b_frame_err_o),
    .parity_err_o (b_parity_err_o),
    .overrun_o    (b_overrun_o),
    .break_o      (b_break_o),
    .rts_n_o      (b_rts_n_o),  // B's RTS rises in the flow_control test
    .cts_n_i      (a_rts_n_o),  // A's RTS gates B's TX; observe assertion (low)
    .tx_wr_en_i   (a_tx_wr_en_i),
    .rx_rd_en_i   (b_rx_rd_en_i)
  );

endmodule
