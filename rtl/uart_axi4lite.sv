// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// AXI4-Lite wrapper for `uart_top`.
//
// Exposes a register-mapped control / status interface so software can
// drive the UART over a 32-bit AXI4-Lite bus. The wrapper instantiates
// the sibling `axi4lite_slave` (vendored in the same `rtl/` directory)
// and decodes its register storage / pulse outputs into the UART's
// configuration ports.
//
// Register map (32-bit registers, byte-addressable, aligned 4):
//
//   0x00 RW   CTRL        [0]    soft_reset (W1, self-clear)
//                         [1]    flow_en
//                         [2]    parity_en
//                         [4:3]  parity_mode  (00 even, 01 odd, 10 mark, 11 space)
//                         [5]    stop_2
//                         [9:6]  data_bits    (5..9)
//                         [10]   tx_empty_irq_en
//                         [11]   rx_irq_en
//                         [12]   rx_full_irq_en
//                         [13]   err_irq_en
//                         others reserved (read 0)
//   0x04 RW   DIV         [DIV_WIDTH-1:0] baud divisor; write triggers reload
//   0x08 RW   RTS_THRESH  [n:0] RX FIFO level above which RTS de-asserts
//   0x0C RO   STATUS      [0] tx_full
//                         [1] tx_empty
//                         [2] rx_full
//                         [3] rx_empty
//                         [4] frame_err
//                         [5] parity_err
//                         [6] overrun
//                         [7] break
//                         [15:8] tx_level
//                         [23:16] rx_level
//                         [24] cts_n
//                         [25] rts_n
//                         [26] irq
//   0x10 W1C  ERR_CLEAR   write 1 to clear all sticky error flags
//   0x14 RW   TX_DATA     [8:0] data byte (or 9-bit). Write pushes into TX FIFO
//                         when the FIFO is not full. Reads return 0.
//   0x18 RC   RX_DATA     [8:0] data byte; read pops the head of the RX FIFO
//                         (read-clear in the regfile sense). Returns 0 if empty.
//
// Reads to undefined regions answer DECERR. Writes to RO bits are
// dropped silently (BRESP = OKAY) per AXI4-Lite convention.

module uart_axi4lite #(
  parameter int unsigned ADDR_WIDTH    = 8,
  parameter int unsigned TX_FIFO_DEPTH = 16,
  parameter int unsigned RX_FIFO_DEPTH = 16,
  parameter int unsigned DIV_WIDTH     = 16
) (
  input  logic                    s_axi_aclk,
  input  logic                    s_axi_aresetn,

  input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  logic [2:0]              s_axi_awprot,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,

  input  logic [31:0]             s_axi_wdata,
  input  logic [3:0]              s_axi_wstrb,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,

  output logic [1:0]              s_axi_bresp,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,

  input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
  input  logic [2:0]              s_axi_arprot,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,

  output logic [31:0]             s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready,

  // Serial pads.
  input  logic                    rx_i,
  output logic                    tx_o,
  input  logic                    cts_n_i,
  output logic                    rts_n_o,

  output logic                    irq_o
);

  localparam int unsigned NUM_REGS = 7;

  // Per-register attribute table (2 bits per register, reg 0 in LSBs).
  // 00 = RW, 01 = RO, 10 = RC, 11 = W1C.
  // Order:
  //   reg 0 CTRL       RW  (00)
  //   reg 1 DIV        RW  (00)
  //   reg 2 RTS_THRESH RW  (00)
  //   reg 3 STATUS     RO  (01)
  //   reg 4 ERR_CLEAR  W1C (11)
  //   reg 5 TX_DATA    RW  (00)  (write pushes; read returns 0 via mask)
  //   reg 6 RX_DATA    RC  (10)  (read pops; the FIFO is the source of data)
  localparam logic [2*NUM_REGS-1:0] REG_ATTR_INIT = {
      2'b10, // RX_DATA  reg 6 RC
      2'b00, // TX_DATA  reg 5 RW
      2'b11, // ERR_CLR  reg 4 W1C
      2'b01, // STATUS   reg 3 RO
      2'b00, // RTS_TH   reg 2 RW
      2'b00, // DIV      reg 1 RW
      2'b00  // CTRL     reg 0 RW
  };

  // Reset values: data_bits = 8 (CTRL[9:6] = 4'd8), DIV = 0, others 0.
  localparam logic [31:0] CTRL_RESET = 32'h0000_0200; // bits[9:6] = 4'b1000 = 8
  localparam logic [NUM_REGS*32-1:0] REG_RESET_INIT = {
      32'd0,        // RX_DATA
      32'd0,        // TX_DATA
      32'd0,        // ERR_CLEAR
      32'd0,        // STATUS (RO so reset is don't-care for storage)
      32'd0,        // RTS_THRESH
      32'd0,        // DIV
      CTRL_RESET    // CTRL
  };

  // Slave wires.
  logic [NUM_REGS*32-1:0] reg_storage;
  logic                   wr_event;
  logic [ADDR_WIDTH-1:0]  wr_event_addr;
  logic                   rd_event;
  logic [ADDR_WIDTH-1:0]  rd_event_addr;

  // RO payload: drives the STATUS register's read value.
  logic [NUM_REGS*32-1:0] rd_payload;

  axi4lite_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (32),
    .NUM_REGS   (NUM_REGS),
    .REG_ATTR   (REG_ATTR_INIT),
    .REG_RESET  (REG_RESET_INIT)
  ) u_slv (
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awprot   (s_axi_awprot),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arprot   (s_axi_arprot),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .rd_payload_i   (rd_payload),
    .slv_err_i      (1'b0),
    .reg_storage_o  (reg_storage),
    .wr_event_o     (wr_event),
    .wr_event_addr_o(wr_event_addr),
    .rd_event_o     (rd_event),
    .rd_event_addr_o(rd_event_addr)
  );

  // Decode register storage into UART configuration.
  logic [31:0] ctrl_reg;
  logic [31:0] div_reg;
  logic [31:0] rts_thresh_reg;
  logic [31:0] tx_data_reg;
  assign ctrl_reg       = reg_storage[ 0*32 +: 32];
  assign div_reg        = reg_storage[ 1*32 +: 32];
  assign rts_thresh_reg = reg_storage[ 2*32 +: 32];
  assign tx_data_reg    = reg_storage[ 5*32 +: 32];

  logic        soft_reset_pulse;
  logic        flow_en;
  logic        parity_en;
  logic [1:0]  parity_mode;
  logic        stop_2;
  logic [3:0]  data_bits;
  logic        tx_empty_irq_en;
  logic        rx_irq_en;
  logic        rx_full_irq_en;
  logic        err_irq_en;

  // CTRL[0] is W1 self-clearing soft-reset (we treat any write to CTRL with bit0=1 as a pulse).
  // We detect the pulse via wr_event on the CTRL register address.
  logic ctrl_write_pulse;
  logic [ADDR_WIDTH-3:0] wr_idx;
  logic [ADDR_WIDTH-3:0] rd_idx;
  assign wr_idx = wr_event_addr[ADDR_WIDTH-1:2];
  assign rd_idx = rd_event_addr[ADDR_WIDTH-1:2];
  assign ctrl_write_pulse = wr_event && (wr_idx == (ADDR_WIDTH-2)'(0));
  // The soft_reset bit is sampled on the same cycle storage is committed
  // (one cycle after wr_event). To make it a one-shot pulse we look at
  // the storage bit in combination with a one-cycle delayed flag.
  logic soft_reset_q;
  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) soft_reset_q <= 1'b0;
    else                soft_reset_q <= ctrl_reg[0];
  end
  assign soft_reset_pulse = ctrl_reg[0] & ~soft_reset_q;

  assign flow_en          = ctrl_reg[1];
  assign parity_en        = ctrl_reg[2];
  assign parity_mode      = ctrl_reg[4:3];
  assign stop_2           = ctrl_reg[5];
  assign data_bits        = ctrl_reg[9:6];
  assign tx_empty_irq_en  = ctrl_reg[10];
  assign rx_irq_en        = ctrl_reg[11];
  assign rx_full_irq_en   = ctrl_reg[12];
  assign err_irq_en       = ctrl_reg[13];

  // Divisor reload on every write to DIV.
  logic divisor_load;
  assign divisor_load = wr_event && (wr_idx == (ADDR_WIDTH-2)'(1));

  // TX push: pulse on every write to TX_DATA.
  logic tx_wr_en;
  assign tx_wr_en = wr_event && (wr_idx == (ADDR_WIDTH-2)'(5));

  // RX pop: pulse on every read of RX_DATA.
  logic rx_rd_en;
  assign rx_rd_en = rd_event && (rd_idx == (ADDR_WIDTH-2)'(6));

  // Error clear: pulse on any write to ERR_CLEAR (data is don't-care; the
  // reg is W1C so storage tracks bits that have NOT been cleared - we
  // only need the write event itself to nuke all sticky flags).
  logic clear_errors;
  assign clear_errors = wr_event && (wr_idx == (ADDR_WIDTH-2)'(4));

  // ---------------------------------------------------------------------
  // UART core.
  // ---------------------------------------------------------------------
  logic       tx_full;
  logic       tx_empty;
  logic [$clog2(TX_FIFO_DEPTH+1)-1:0] tx_level;
  logic [8:0] rx_rd_data;
  logic       rx_full;
  logic       rx_empty;
  logic [$clog2(RX_FIFO_DEPTH+1)-1:0] rx_level;
  logic       frame_err, parity_err, overrun, brk;
  logic       irq_w;
  logic       rts_n_w;

  // We want the soft-reset to clear the UART state. We OR it with the
  // global slave reset.
  logic core_rstn;
  assign core_rstn = s_axi_aresetn & ~soft_reset_pulse;

  // RTS threshold from the RTS_THRESH register, clipped to the FIFO
  // level width.
  localparam int unsigned RXLVL_W = $clog2(RX_FIFO_DEPTH+1);
  logic [RXLVL_W-1:0] rts_thresh_w;
  assign rts_thresh_w = rts_thresh_reg[RXLVL_W-1:0];

  // Divisor — clipped from the 32-bit reg to DIV_WIDTH bits.
  logic [DIV_WIDTH-1:0] div_w;
  assign div_w = div_reg[DIV_WIDTH-1:0];

  uart_top #(
    .TX_FIFO_DEPTH (TX_FIFO_DEPTH),
    .RX_FIFO_DEPTH (RX_FIFO_DEPTH),
    .DIV_WIDTH     (DIV_WIDTH)
  ) u_uart (
    .clk_i              (s_axi_aclk),
    .rst_ni             (core_rstn),
    .divisor_i          (div_w),
    .divisor_load_i     (divisor_load),
    .data_bits_i        (data_bits),
    .parity_en_i        (parity_en),
    .parity_mode_i      (parity_mode),
    .stop_2_i           (stop_2),
    .flow_en_i          (flow_en),
    .rts_thresh_i       (rts_thresh_w),
    .tx_wr_en_i         (tx_wr_en),
    .tx_wr_data_i       (tx_data_reg[8:0]),
    .tx_full_o          (tx_full),
    .tx_empty_o         (tx_empty),
    .tx_level_o         (tx_level),
    .rx_rd_en_i         (rx_rd_en),
    .rx_rd_data_o       (rx_rd_data),
    .rx_full_o          (rx_full),
    .rx_empty_o         (rx_empty),
    .rx_level_o         (rx_level),
    .frame_err_o        (frame_err),
    .parity_err_o       (parity_err),
    .overrun_o          (overrun),
    .break_o            (brk),
    .clear_errors_i     (clear_errors),
    .rx_irq_en_i        (rx_irq_en),
    .rx_full_irq_en_i   (rx_full_irq_en),
    .tx_empty_irq_en_i  (tx_empty_irq_en),
    .err_irq_en_i       (err_irq_en),
    .irq_o              (irq_w),
    .rx_i               (rx_i),
    .tx_o               (tx_o),
    .cts_n_i            (cts_n_i),
    .rts_n_o            (rts_n_w)
  );

  assign rts_n_o = rts_n_w;
  assign irq_o   = irq_w;

  // ---------------------------------------------------------------------
  // Build the read-only payload. STATUS at reg 3, RX_DATA at reg 6.
  // The other slots are RW/W1C and the regfile uses the storage path
  // for those reads, so '0' here is fine.
  // ---------------------------------------------------------------------
  logic [31:0] status_word;
  assign status_word = {
      5'd0,                                                    // [31:27]
      irq_w,                                                   // [26]
      rts_n_w,                                                 // [25]
      cts_n_i,                                                 // [24]
      {(8 - $clog2(RX_FIFO_DEPTH+1)){1'b0}},                   // [23:24-?]
      rx_level,                                                // [16+W:16]
      {(8 - $clog2(TX_FIFO_DEPTH+1)){1'b0}},                   // pad
      tx_level,                                                // [8+W:8]
      brk,                                                     // [7]
      overrun,                                                 // [6]
      parity_err,                                              // [5]
      frame_err,                                               // [4]
      rx_empty,                                                // [3]
      rx_full,                                                 // [2]
      tx_empty,                                                // [1]
      tx_full                                                  // [0]
  };

  // RX_DATA payload — surface the head of the RX FIFO so a software
  // read returns the byte while the regfile's RC mechanism on the
  // storage side keeps an accurate "consumed" pointer.
  logic [31:0] rx_data_word;
  assign rx_data_word = {23'd0, rx_rd_data};

  // Build the packed payload vector. Slot index = register index.
  always_comb begin
    rd_payload                = '0;
    rd_payload[3*32 +: 32]    = status_word;
    rd_payload[6*32 +: 32]    = rx_data_word;
  end

  // Tie-offs.
  logic _unused;
  assign _unused = ctrl_write_pulse;

endmodule
