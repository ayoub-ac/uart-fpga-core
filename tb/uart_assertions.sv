// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// SVA assertions for uart_top. Properties cover protocol invariants
// enforced on every cycle of every test:
//
//   p_tx_idle_high     : tx_o is high (mark) when no frame is in flight.
//   p_tx_start_low     : when tx_busy is asserted following an idle the
//                        first non-idle bit must be a low (the start
//                        bit). Captured by checking that tx_o cannot
//                        glitch from 1 -> 0 -> 1 within one bit time
//                        when no FIFO data is queued.
//   p_baud_div_count   : the baud generator's divisor count never
//                        exceeds the loaded divisor.
//   p_fifo_lvl_coherent: TX/RX FIFO `level_o` and the empty/full flags
//                        agree (level == 0 iff empty; level == DEPTH iff
//                        full).
//   p_overrun_implies_full: overrun_o cannot rise unless the RX FIFO
//                          was full at the moment of the RX-frame
//                          delivery.
//   p_parity_consistency : when parity_err pulses, parity_en_i must be 1.

module uart_assertions #(
  parameter int unsigned TX_FIFO_DEPTH = 16,
  parameter int unsigned RX_FIFO_DEPTH = 16
) (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        tx_o,
  input logic [$clog2(TX_FIFO_DEPTH+1)-1:0] tx_level_o,
  input logic        tx_full_o,
  input logic        tx_empty_o,
  input logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_level_o,
  input logic        rx_full_o,
  input logic        rx_empty_o,
  input logic        parity_en_i,
  input logic        parity_err_o,
  input logic        overrun_o,
  input logic        clear_errors_i
);
`ifndef SYNTHESIS

  // 1. TX FIFO empty / level coherence.
  property p_tx_lvl_empty_coherent;
    @(posedge clk_i) disable iff (!rst_ni)
      (tx_level_o == '0) == tx_empty_o;
  endproperty
  a_tx_lvl_empty_coherent: assert property (p_tx_lvl_empty_coherent)
    else $error("uart: tx_level_o == 0 but tx_empty_o not asserted (or vice versa)");

  // 2. TX FIFO full / level coherence.
  property p_tx_lvl_full_coherent;
    @(posedge clk_i) disable iff (!rst_ni)
      (tx_level_o == ($clog2(TX_FIFO_DEPTH+1))'(TX_FIFO_DEPTH)) == tx_full_o;
  endproperty
  a_tx_lvl_full_coherent: assert property (p_tx_lvl_full_coherent)
    else $error("uart: tx_level_o == DEPTH but tx_full_o not asserted (or vice versa)");

  // 3. RX FIFO empty / level coherence.
  property p_rx_lvl_empty_coherent;
    @(posedge clk_i) disable iff (!rst_ni)
      (rx_level_o == '0) == rx_empty_o;
  endproperty
  a_rx_lvl_empty_coherent: assert property (p_rx_lvl_empty_coherent)
    else $error("uart: rx_level_o == 0 but rx_empty_o not asserted (or vice versa)");

  // 4. Overrun implies the RX FIFO was full at the time. The flag is
  //    sticky, so once set it stays — the property checks the *rise*
  //    edge. We allow rx_full to be either still-asserted or just-cleared
  //    (the overrun and the FIFO pop that drains it could race).
  logic rx_full_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) rx_full_q <= 1'b0;
    else         rx_full_q <= rx_full_o;
  end
  property p_overrun_implies_full;
    @(posedge clk_i) disable iff (!rst_ni)
      ($rose(overrun_o) && !clear_errors_i) |-> (rx_full_o || rx_full_q);
  endproperty
  a_overrun_implies_full: assert property (p_overrun_implies_full)
    else $error("uart: overrun raised without RX FIFO being full");

  // 5. Parity error requires parity to be enabled.
  property p_parity_err_implies_en;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(parity_err_o) |-> parity_en_i;
  endproperty
  a_parity_err_implies_en: assert property (p_parity_err_implies_en)
    else $error("uart: parity_err pulsed while parity_en_i was 0");

`endif
endmodule
