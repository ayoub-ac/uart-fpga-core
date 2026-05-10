// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// UART transmitter: serialises a 9-bit data word into a UART frame on
// the `tx_o` line.
//
// Frame format (little-endian on the wire, LSB-first):
//
//     idle  start   data[0]..data[N-1]   [parity]  stop[1]  [stop[2]]   idle
//      1      0      d0 d1 d2 ... dN-1     p         1         1         1
//
// Parameters at run-time:
//   * data_bits_i  : 5..9 (number of payload bits per frame)
//   * parity_en_i  : enable parity bit between data and stop
//   * parity_mode_i: encoding of the parity bit (00=even, 01=odd,
//                     10=mark, 11=space)
//   * stop_2_i     : 0 = one stop bit, 1 = two stop bits
//
// Hardware flow-control:
//   * cts_n_i (active-low CTS from the receiver). When cts_n_i is high
//     and `flow_en_i` is set, the TX waits in IDLE before launching the
//     start bit; a frame already in flight runs to completion.
//
// Bit timing is driven by `tick_x1_o` from `uart_baudgen` — one bit per
// pulse. The TX never samples or generates anything between pulses; the
// `tx_o` line is held at the current bit value until the next tick.
//
// On reset, `tx_o` rests at marking (1) per RS-232 convention. The
// module asserts `busy_o` while a frame is in flight.

module uart_tx (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Baud tick: one pulse per bit time (downsampled from the 16x).
  input  logic        tick_x1_i,

  // Frame configuration (sampled at the start of each frame).
  input  logic [3:0]  data_bits_i,    // 5..9
  input  logic        parity_en_i,
  input  logic [1:0]  parity_mode_i,  // 00 even, 01 odd, 10 mark, 11 space
  input  logic        stop_2_i,

  // Flow control.
  input  logic        flow_en_i,
  input  logic        cts_n_i,        // active-low CTS

  // Data input handshake (handshake at posedge clk).
  input  logic        data_valid_i,
  output logic        data_ready_o,
  input  logic [8:0]  data_i,

  // Serial output.
  output logic        tx_o,
  output logic        busy_o
);

  // FSM states
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_START  = 3'd1,
    S_DATA   = 3'd2,
    S_PARITY = 3'd3,
    S_STOP1  = 3'd4,
    S_STOP2  = 3'd5
  } state_e;

  state_e state_q;
  logic [3:0]  bit_idx_q;
  logic [8:0]  shift_q;
  logic [3:0]  data_bits_q;
  logic        parity_en_q;
  logic [1:0]  parity_mode_q;
  logic        stop_2_q;
  logic        tx_q;

  // Compute parity over the data being shifted (XOR of all payload bits).
  // Pre-compute as the frame is loaded so we don't have to track it
  // bit-by-bit.
  logic        parity_bit_q;

  function automatic logic compute_parity(input logic [8:0] d,
                                          input logic [3:0] nbits,
                                          input logic [1:0] mode);
    logic xor_acc;
    integer i;
    xor_acc = 1'b0;
    for (i = 0; i < 9; i = i + 1) begin
      if (i < nbits) xor_acc = xor_acc ^ d[i];
    end
    case (mode)
      2'b00:  compute_parity = xor_acc;            // even
      2'b01:  compute_parity = ~xor_acc;           // odd
      2'b10:  compute_parity = 1'b1;               // mark
      default:compute_parity = 1'b0;               // space (2'b11)
    endcase
  endfunction

  // Accept new frame when idle, baud-armed, and (if flow enabled) CTS asserted.
  logic accept_frame;
  assign accept_frame = (state_q == S_IDLE) && data_valid_i &&
                        !(flow_en_i && cts_n_i);

  assign data_ready_o = (state_q == S_IDLE) && !(flow_en_i && cts_n_i);
  assign tx_o         = tx_q;
  assign busy_o       = (state_q != S_IDLE);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;
      bit_idx_q     <= 4'd0;
      shift_q       <= 9'd0;
      data_bits_q   <= 4'd8;
      parity_en_q   <= 1'b0;
      parity_mode_q <= 2'b00;
      stop_2_q      <= 1'b0;
      parity_bit_q  <= 1'b0;
      tx_q          <= 1'b1;
    end else begin
      case (state_q)
        S_IDLE: begin
          tx_q <= 1'b1;
          if (accept_frame) begin
            shift_q       <= data_i;
            data_bits_q   <= data_bits_i;
            parity_en_q   <= parity_en_i;
            parity_mode_q <= parity_mode_i;
            stop_2_q      <= stop_2_i;
            parity_bit_q  <= compute_parity(data_i, data_bits_i, parity_mode_i);
            bit_idx_q     <= 4'd0;
            state_q       <= S_START;
          end
        end

        S_START: begin
          tx_q <= 1'b0;
          if (tick_x1_i) begin
            state_q   <= S_DATA;
            bit_idx_q <= 4'd0;
            tx_q      <= shift_q[0];
          end
        end

        S_DATA: begin
          if (tick_x1_i) begin
            // Output the bit corresponding to bit_idx_q+1 next, advance.
            if (bit_idx_q == data_bits_q - 4'd1) begin
              if (parity_en_q) begin
                state_q <= S_PARITY;
                tx_q    <= parity_bit_q;
              end else begin
                state_q <= S_STOP1;
                tx_q    <= 1'b1;
              end
            end else begin
              bit_idx_q <= bit_idx_q + 4'd1;
              tx_q      <= shift_q[bit_idx_q + 4'd1];
            end
          end
        end

        S_PARITY: begin
          if (tick_x1_i) begin
            state_q <= S_STOP1;
            tx_q    <= 1'b1;
          end
        end

        S_STOP1: begin
          if (tick_x1_i) begin
            if (stop_2_q) begin
              state_q <= S_STOP2;
              tx_q    <= 1'b1;
            end else begin
              state_q <= S_IDLE;
              tx_q    <= 1'b1;
            end
          end
        end

        S_STOP2: begin
          if (tick_x1_i) begin
            state_q <= S_IDLE;
            tx_q    <= 1'b1;
          end
        end

        default: begin
          state_q <= S_IDLE;
          tx_q    <= 1'b1;
        end
      endcase
    end
  end

endmodule
