// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Synchronous parametrizable FIFO for UART TX / RX paths.
//
// Single clock domain. DEPTH must be a power of two so the read / write
// pointers can wrap with one-bit comparisons. WIDTH is the data word
// width (9 bits to carry the optional 9-bit data mode plus a flag).
//
// Side-effect: `level_o` is the current occupancy (0..DEPTH). The user
// (the UART top) compares this to a programmable threshold for RTS
// flow-control assertion and for the RX FIFO interrupt level.
//
// Behavior:
//   * push fires when wr_en && !full.
//   * pop  fires when rd_en && !empty.
//   * simultaneous push and pop on a non-full, non-empty FIFO succeed
//     and leave the level unchanged.
//   * push to a full FIFO is silently dropped (the integrator is
//     expected to gate wr_en on !full or to handle overrun externally).

module uart_fifo #(
  parameter int unsigned DEPTH = 16,
  parameter int unsigned WIDTH = 9
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              wr_en_i,
  input  logic [WIDTH-1:0]  wr_data_i,
  input  logic              rd_en_i,
  output logic [WIDTH-1:0]  rd_data_o,

  output logic              empty_o,
  output logic              full_o,
  output logic [$clog2(DEPTH+1)-1:0] level_o
);

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned LVL_W = $clog2(DEPTH + 1);

  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [PTR_W-1:0] wr_ptr_q;
  logic [PTR_W-1:0] rd_ptr_q;
  logic [LVL_W-1:0] lvl_q;

  assign empty_o = (lvl_q == '0);
  assign full_o  = (lvl_q == LVL_W'(DEPTH));
  assign level_o = lvl_q;

  // Read data is the head of the FIFO; combinational so the consumer
  // sees it on the cycle they assert rd_en_i.
  assign rd_data_o = mem_q[rd_ptr_q];

  logic do_push;
  logic do_pop;
  assign do_push = wr_en_i && !full_o;
  assign do_pop  = rd_en_i && !empty_o;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      lvl_q    <= '0;
    end else begin
      if (do_push) begin
        mem_q[wr_ptr_q] <= wr_data_i;
        if (DEPTH == 1) wr_ptr_q <= '0;
        else            wr_ptr_q <= wr_ptr_q + PTR_W'(1);
      end
      if (do_pop) begin
        if (DEPTH == 1) rd_ptr_q <= '0;
        else            rd_ptr_q <= rd_ptr_q + PTR_W'(1);
      end
      // Level: +1 on push-only, -1 on pop-only, unchanged on both or
      // neither.
      if (do_push && !do_pop) lvl_q <= lvl_q + LVL_W'(1);
      else if (!do_push && do_pop) lvl_q <= lvl_q - LVL_W'(1);
    end
  end

endmodule
