// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// UART receiver with 16x oversampling and majority-vote bit recovery.
//
// The RX line `rx_i` is sampled on every `tick_x16_i` pulse from the
// baud generator (16 samples per bit time). The receiver:
//
//   1. Synchronises `rx_i` through a 2-FF chain to defeat metastability.
//   2. Watches for a high->low edge while idle. On the falling edge it
//      starts a sample counter and waits 8 ticks: that lands on bit
//      centre of the start bit. If `rx_i` is still 0 (confirming start),
//      the receiver locks on. Otherwise it returns to idle (rejects a
//      glitch).
//   3. After centre-of-start, samples every 16 ticks at bit centre. For
//      each data bit it captures three samples around centre (ticks 7,
//      8, 9) and majority-votes them — one wrong sample per bit is
//      tolerated (the 5% baud mismatch that the 16x oversampling
//      tolerates).
//   4. After the data bits it samples the parity (if enabled) and the
//      first stop bit. If the stop bit is 0, `frame_err_o` pulses for
//      one cycle. If the parity does not match the configured mode,
//      `parity_err_o` pulses.
//   5. Continuous-low detection: if `rx_i` stays at 0 for at least one
//      full frame (~ data_bits + parity + stop bit times), `break_o`
//      pulses for one cycle.
//
// On a successful frame, `data_valid_o` pulses for one cycle with
// `data_o` populated (data bits zero-extended into the low bits of a
// 9-bit word). The downstream FIFO captures it.

module uart_rx (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        tick_x16_i,

  // Frame configuration. Sampled on the falling edge of `rx_i` (start
  // detect).
  input  logic [3:0]  data_bits_i,
  input  logic        parity_en_i,
  input  logic [1:0]  parity_mode_i,
  input  logic        stop_2_i,

  // Serial input.
  input  logic        rx_i,

  // Decoded frame (one-cycle pulse on data_valid_o).
  output logic        data_valid_o,
  output logic [8:0]  data_o,

  // Error pulses (one cycle each).
  output logic        frame_err_o,
  output logic        parity_err_o,
  output logic        break_o,

  // Liveness.
  output logic        busy_o
);

  // ---------- Synchroniser ----------
  logic rx_sync0_q, rx_sync1_q, rx_sync_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_sync0_q <= 1'b1;
      rx_sync1_q <= 1'b1;
      rx_sync_q  <= 1'b1;
    end else begin
      rx_sync0_q <= rx_i;
      rx_sync1_q <= rx_sync0_q;
      rx_sync_q  <= rx_sync1_q;
    end
  end

  // ---------- FSM ----------
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_START  = 3'd1,
    S_DATA   = 3'd2,
    S_PARITY = 3'd3,
    S_STOP   = 3'd4,
    S_STOP2  = 3'd5
  } state_e;

  state_e      state_q;
  logic [3:0]  sample_q;     // 0..15 within a bit time
  logic [3:0]  bit_idx_q;
  logic [8:0]  data_q;
  logic [3:0]  data_bits_q;
  logic        parity_en_q;
  logic [1:0]  parity_mode_q;
  logic        stop_2_q;
  logic        votes0_q, votes1_q;  // running majority counters at samples 7..9
  logic        parity_bit_q;
  logic [12:0] break_cnt_q;          // counts x16 ticks while line is 0
  logic        break_armed_q;        // set after first low; cleared on high
  logic        data_valid_pulse_q;
  logic        frame_err_pulse_q;
  logic        parity_err_pulse_q;
  logic        break_pulse_q;

  assign data_valid_o = data_valid_pulse_q;
  assign frame_err_o  = frame_err_pulse_q;
  assign parity_err_o = parity_err_pulse_q;
  assign break_o      = break_pulse_q;
  assign data_o       = data_q;
  assign busy_o       = (state_q != S_IDLE);

  // Compute expected parity from received data + mode.
  function automatic logic exp_parity(input logic [8:0] d,
                                      input logic [3:0] nbits,
                                      input logic [1:0] mode);
    logic xor_acc;
    integer i;
    xor_acc = 1'b0;
    for (i = 0; i < 9; i = i + 1) begin
      if (i < nbits) xor_acc = xor_acc ^ d[i];
    end
    case (mode)
      2'b00:  exp_parity = xor_acc;
      2'b01:  exp_parity = ~xor_acc;
      2'b10:  exp_parity = 1'b1;
      default:exp_parity = 1'b0;
    endcase
  endfunction

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q            <= S_IDLE;
      sample_q           <= 4'd0;
      bit_idx_q          <= 4'd0;
      data_q             <= 9'd0;
      data_bits_q        <= 4'd8;
      parity_en_q        <= 1'b0;
      parity_mode_q      <= 2'b00;
      stop_2_q           <= 1'b0;
      votes0_q           <= 1'b0;
      votes1_q           <= 1'b0;
      parity_bit_q       <= 1'b0;
      break_cnt_q        <= 13'd0;
      break_armed_q      <= 1'b0;
      data_valid_pulse_q <= 1'b0;
      frame_err_pulse_q  <= 1'b0;
      parity_err_pulse_q <= 1'b0;
      break_pulse_q      <= 1'b0;
    end else begin
      data_valid_pulse_q <= 1'b0;
      frame_err_pulse_q  <= 1'b0;
      parity_err_pulse_q <= 1'b0;
      break_pulse_q      <= 1'b0;

      if (tick_x16_i) begin
        // Break detection: count how many consecutive 16x ticks the
        // synchronised line stays at 0. A frame at 8N1 is 10 bit times
        // = 160 ticks; if the line is low for >= 11*16 = 176 ticks
        // we treat that as a break.
        if (rx_sync_q == 1'b0) begin
          if (break_cnt_q != 13'h1fff) break_cnt_q <= break_cnt_q + 13'd1;
          if (break_cnt_q == 13'd175 && !break_armed_q) begin
            break_pulse_q <= 1'b1;
            break_armed_q <= 1'b1;
          end
        end else begin
          break_cnt_q   <= 13'd0;
          break_armed_q <= 1'b0;
        end

        case (state_q)
          S_IDLE: begin
            // Detect falling edge: rx_sync transitions to 0.
            if (rx_sync_q == 1'b0) begin
              data_bits_q   <= data_bits_i;
              parity_en_q   <= parity_en_i;
              parity_mode_q <= parity_mode_i;
              stop_2_q      <= stop_2_i;
              sample_q      <= 4'd1;       // already at sample #0 (the "0")
              state_q       <= S_START;
              votes0_q      <= 1'b0;
              votes1_q      <= 1'b0;
              data_q        <= 9'd0;
              bit_idx_q     <= 4'd0;
            end
          end

          S_START: begin
            sample_q <= sample_q + 4'd1;
            // At sample 7 (centre of the start bit) recheck the line.
            // If still low, lock; if high, abort (it was a glitch).
            if (sample_q == 4'd7) begin
              if (rx_sync_q == 1'b1) begin
                state_q  <= S_IDLE;
              end
            end
            // After 16 samples (a full bit time), advance to data.
            if (sample_q == 4'd15) begin
              state_q   <= S_DATA;
              sample_q  <= 4'd0;
              bit_idx_q <= 4'd0;
              votes0_q  <= 1'b0;
              votes1_q  <= 1'b0;
            end
          end

          S_DATA: begin
            sample_q <= sample_q + 4'd1;
            // Majority vote on samples 7, 8, 9. We compute "the bit was
            // 1 if at least 2 of the 3 samples are 1". We capture the
            // first sample on tick 7 (votes0), the second on tick 8
            // (votes1), and combine on tick 9.
            if (sample_q == 4'd7) votes0_q <= rx_sync_q;
            if (sample_q == 4'd8) votes1_q <= rx_sync_q;
            if (sample_q == 4'd9) begin
              // majority of {votes0_q, votes1_q, rx_sync_q}
              data_q[bit_idx_q] <=
                  (votes0_q & votes1_q) | (votes0_q & rx_sync_q) |
                  (votes1_q & rx_sync_q);
            end
            if (sample_q == 4'd15) begin
              sample_q <= 4'd0;
              if (bit_idx_q == data_bits_q - 4'd1) begin
                if (parity_en_q) state_q <= S_PARITY;
                else             state_q <= S_STOP;
              end else begin
                bit_idx_q <= bit_idx_q + 4'd1;
              end
            end
          end

          S_PARITY: begin
            sample_q <= sample_q + 4'd1;
            if (sample_q == 4'd7) votes0_q <= rx_sync_q;
            if (sample_q == 4'd8) votes1_q <= rx_sync_q;
            if (sample_q == 4'd9) begin
              parity_bit_q <=
                  (votes0_q & votes1_q) | (votes0_q & rx_sync_q) |
                  (votes1_q & rx_sync_q);
            end
            if (sample_q == 4'd15) begin
              sample_q <= 4'd0;
              state_q  <= S_STOP;
            end
          end

          S_STOP: begin
            sample_q <= sample_q + 4'd1;
            if (sample_q == 4'd7) votes0_q <= rx_sync_q;
            if (sample_q == 4'd8) votes1_q <= rx_sync_q;
            // Decision at sample 9: if the stop bit is 0, frame error.
            if (sample_q == 4'd9) begin
              logic stop_bit;
              stop_bit = (votes0_q & votes1_q) | (votes0_q & rx_sync_q) |
                         (votes1_q & rx_sync_q);
              if (stop_bit == 1'b0) begin
                frame_err_pulse_q <= 1'b1;
              end else begin
                // Frame is structurally fine. Check parity if enabled.
                if (parity_en_q) begin
                  if (parity_bit_q != exp_parity(data_q, data_bits_q,
                                                 parity_mode_q)) begin
                    parity_err_pulse_q <= 1'b1;
                  end else begin
                    data_valid_pulse_q <= 1'b1;
                  end
                end else begin
                  data_valid_pulse_q <= 1'b1;
                end
              end
              // Return to IDLE now: we've decided on the stop bit; the
              // remaining 6 sample-ticks of the bit time are consumed
              // by the inter-frame margin. Exiting early gives the FSM
              // up to 6/16 of a bit time of slack to catch the next
              // falling edge — this is what extends the cross-baud
              // tolerance. For 2-stop-bit configurations we still must
              // wait for the second stop bit, so we stay in S_STOP2.
              if (stop_2_q) begin
                state_q  <= S_STOP2;
                sample_q <= 4'd10;
              end else begin
                state_q  <= S_IDLE;
                sample_q <= 4'd0;
              end
            end
          end

          S_STOP2: begin
            sample_q <= sample_q + 4'd1;
            // After 1 + 1 stop bits we have sample_q traversing 10..15
            // in S_STOP first, then 0..15 here. We exit at sample 9
            // here too, for the same drift-tolerance reasoning.
            if (sample_q == 4'd9) begin
              state_q  <= S_IDLE;
              sample_q <= 4'd0;
            end
          end

          default: state_q <= S_IDLE;
        endcase
      end
    end
  end

endmodule
