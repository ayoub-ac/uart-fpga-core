-- SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog uart_top module.
--
-- This entity exposes uart_top's port list under a VHDL-friendly
-- interface. The architecture instantiates the SystemVerilog module by
-- component name; mixed-language elaboration is supported natively by
-- Vivado, Quartus, ModelSim/Questa, and Aldec, and via the GHDL VHPI
-- bridge for open simulation.
--
-- Status: WRAPPER ONLY. The UART datapath itself remains in
-- SystemVerilog (rtl/*.sv). A native VHDL port of the datapath is
-- listed as future work.
--
-- I/O contract: identical to uart_top.sv (see PORT_DESCRIPTION.md).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity uart_top_vhdl is
  generic (
    TX_FIFO_DEPTH : integer := 16;
    RX_FIFO_DEPTH : integer := 16;
    DIV_WIDTH     : integer := 16
  );
  port (
    clk_i              : in  std_logic;
    rst_ni             : in  std_logic;

    divisor_i          : in  std_logic_vector(DIV_WIDTH-1 downto 0);
    divisor_load_i     : in  std_logic;
    data_bits_i        : in  std_logic_vector( 3 downto 0);
    parity_en_i        : in  std_logic;
    parity_mode_i      : in  std_logic_vector( 1 downto 0);
    stop_2_i           : in  std_logic;
    flow_en_i          : in  std_logic;
    rts_thresh_i       : in  std_logic_vector( 4 downto 0);

    tx_wr_en_i         : in  std_logic;
    tx_wr_data_i       : in  std_logic_vector( 8 downto 0);
    tx_full_o          : out std_logic;
    tx_empty_o         : out std_logic;
    tx_level_o         : out std_logic_vector( 4 downto 0);

    rx_rd_en_i         : in  std_logic;
    rx_rd_data_o       : out std_logic_vector( 8 downto 0);
    rx_full_o          : out std_logic;
    rx_empty_o         : out std_logic;
    rx_level_o         : out std_logic_vector( 4 downto 0);

    frame_err_o        : out std_logic;
    parity_err_o       : out std_logic;
    overrun_o          : out std_logic;
    break_o            : out std_logic;
    clear_errors_i     : in  std_logic;

    rx_irq_en_i        : in  std_logic;
    rx_full_irq_en_i   : in  std_logic;
    tx_empty_irq_en_i  : in  std_logic;
    err_irq_en_i       : in  std_logic;
    irq_o              : out std_logic;

    rx_i               : in  std_logic;
    tx_o               : out std_logic;
    cts_n_i            : in  std_logic;
    rts_n_o            : out std_logic
  );
end entity uart_top_vhdl;

architecture rtl of uart_top_vhdl is

  component uart_top
    generic (
      TX_FIFO_DEPTH : integer;
      RX_FIFO_DEPTH : integer;
      DIV_WIDTH     : integer
    );
    port (
      clk_i              : in  std_logic;
      rst_ni             : in  std_logic;
      divisor_i          : in  std_logic_vector(DIV_WIDTH-1 downto 0);
      divisor_load_i     : in  std_logic;
      data_bits_i        : in  std_logic_vector( 3 downto 0);
      parity_en_i        : in  std_logic;
      parity_mode_i      : in  std_logic_vector( 1 downto 0);
      stop_2_i           : in  std_logic;
      flow_en_i          : in  std_logic;
      rts_thresh_i       : in  std_logic_vector( 4 downto 0);
      tx_wr_en_i         : in  std_logic;
      tx_wr_data_i       : in  std_logic_vector( 8 downto 0);
      tx_full_o          : out std_logic;
      tx_empty_o         : out std_logic;
      tx_level_o         : out std_logic_vector( 4 downto 0);
      rx_rd_en_i         : in  std_logic;
      rx_rd_data_o       : out std_logic_vector( 8 downto 0);
      rx_full_o          : out std_logic;
      rx_empty_o         : out std_logic;
      rx_level_o         : out std_logic_vector( 4 downto 0);
      frame_err_o        : out std_logic;
      parity_err_o       : out std_logic;
      overrun_o          : out std_logic;
      break_o            : out std_logic;
      clear_errors_i     : in  std_logic;
      rx_irq_en_i        : in  std_logic;
      rx_full_irq_en_i   : in  std_logic;
      tx_empty_irq_en_i  : in  std_logic;
      err_irq_en_i       : in  std_logic;
      irq_o              : out std_logic;
      rx_i               : in  std_logic;
      tx_o               : out std_logic;
      cts_n_i            : in  std_logic;
      rts_n_o            : out std_logic
    );
  end component;

begin

  u_uart : uart_top
    generic map (
      TX_FIFO_DEPTH => TX_FIFO_DEPTH,
      RX_FIFO_DEPTH => RX_FIFO_DEPTH,
      DIV_WIDTH     => DIV_WIDTH
    )
    port map (
      clk_i             => clk_i,
      rst_ni            => rst_ni,
      divisor_i         => divisor_i,
      divisor_load_i    => divisor_load_i,
      data_bits_i       => data_bits_i,
      parity_en_i       => parity_en_i,
      parity_mode_i     => parity_mode_i,
      stop_2_i          => stop_2_i,
      flow_en_i         => flow_en_i,
      rts_thresh_i      => rts_thresh_i,
      tx_wr_en_i        => tx_wr_en_i,
      tx_wr_data_i      => tx_wr_data_i,
      tx_full_o         => tx_full_o,
      tx_empty_o        => tx_empty_o,
      tx_level_o        => tx_level_o,
      rx_rd_en_i        => rx_rd_en_i,
      rx_rd_data_o      => rx_rd_data_o,
      rx_full_o         => rx_full_o,
      rx_empty_o        => rx_empty_o,
      rx_level_o        => rx_level_o,
      frame_err_o       => frame_err_o,
      parity_err_o      => parity_err_o,
      overrun_o         => overrun_o,
      break_o           => break_o,
      clear_errors_i    => clear_errors_i,
      rx_irq_en_i       => rx_irq_en_i,
      rx_full_irq_en_i  => rx_full_irq_en_i,
      tx_empty_irq_en_i => tx_empty_irq_en_i,
      err_irq_en_i      => err_irq_en_i,
      irq_o             => irq_o,
      rx_i              => rx_i,
      tx_o              => tx_o,
      cts_n_i           => cts_n_i,
      rts_n_o           => rts_n_o
    );

end architecture rtl;
