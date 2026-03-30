//-----------------------------------------------------------------------------
// NanoSoC Testbench - FT1248 Interface
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : FT1248 protocol bridge, tracking, and file-based I/O
//            Active when P1[7] (FT1248MODE) is high
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_tb_ft1248 #(
  parameter ADP_FILENAME = "adp.cmd",
  parameter FAST_LOAD    = 0
)(
  input  wire        CLK,
  input  wire        NRST,
  input  wire        FT1248MODE,
  // P1 pins used by FT1248 (active in FT1248MODE)
  inout  wire        P1_0,       // ft_miso_in
  inout  wire        P1_1,       // ft_clk_out
  inout  wire        P1_2,       // ft_miosio_io
  inout  wire        P1_3,       // ft_ssn_out
  inout  wire        P1_4,       // uart2_rxd (loopback in FT1248 mode)
  inout  wire        P1_5,       // uart2_txd
  // Debug test enable
  output wire        debug_test_en
);

  // UART2 loopback in FT1248 mode
  bufif1 #1 (P1_4, P1_5, FT1248MODE);

  // FT1248 signal extraction
  wire ft_clk_out;
  wire ft_miso_in;
  wire ft_ssn_out;

  assign ft_clk_out = (FT1248MODE) ? P1_1 : 1'b0;
  bufif1 #1 (P1_0, ft_miso_in, FT1248MODE);
  assign ft_ssn_out = (FT1248MODE) ? P1_3 : 1'b1;

  wire ft_miosio_o;
  wire ft_miosio_z;
  wire ft_miosio_i;
  assign ft_miosio_i = (FT1248MODE) ? P1_2 : 1'b0;
  bufif1 #1 (P1_2, ft_miosio_o, (FT1248MODE & !ft_miosio_z));

  // AXI stream interface between file I/O and FT1248 bridge
  wire       txd8_tready;
  wire       txd8_tvalid;
  wire [7:0] txd8_tdata;
  wire       rxd8_tready;
  wire       rxd8_tvalid;
  wire [7:0] rxd8_tdata;

  // File-based stimulus -> FT1248 bridge
`ifndef COCOTB_SIM
  nanosoc_axi_stream_io_8_txd_from_file #(
    .TXDFILENAME(ADP_FILENAME),
    .FAST_LOAD(FAST_LOAD)
  ) u_nanosoc_axi_stream_io_8_txd_from_file (
    .aclk       (CLK),
    .aresetn    (NRST),
    .txd8_ready (txd8_tready),
    .txd8_valid (txd8_tvalid),
    .txd8_data  (txd8_tdata)
  );
`endif

  // FT1248 protocol bridge
  nanosoc_ft1248x1_to_axi_streamio_v1_0 u_nanosoc_ft1248x1_to_axi_streamio_v1_0 (
    .ft_clk_i     (ft_clk_out),
    .ft_ssn_i     (ft_ssn_out),
    .ft_miso_o    (ft_miso_in),
    .ft_miosio_i  (ft_miosio_i),
    .ft_miosio_o  (ft_miosio_o),
    .ft_miosio_z  (ft_miosio_z),
    .aclk         (CLK),
    .aresetn      (NRST),
    .rxd_tready_o (txd8_tready),
    .rxd_tvalid_i (txd8_tvalid),
    .rxd_tdata8_i (txd8_tdata),
    .txd_tready_i (rxd8_tready),
    .txd_tvalid_o (rxd8_tvalid),
    .txd_tdata8_o (rxd8_tdata)
  );

  // FT1248 output capture
`ifndef COCOTB_SIM
  nanosoc_axi_stream_io_8_rxd_to_file #(
    .RXDFILENAME("logs/ft1248_out.log")
  ) u_nanosoc_axi_stream_io_8_rxd_to_file (
    .aclk         (CLK),
    .aresetn      (NRST),
    .eof_received ( ),
    .rxd8_ready   (rxd8_tready),
    .rxd8_valid   (rxd8_tvalid),
    .rxd8_data    (rxd8_tdata)
  );
`endif

  // I/O stream tracking with debug test enable
  nanosoc_track_tb_iostream u_nanosoc_track_tb_iostream (
    .aclk         (CLK),
    .aresetn      (NRST),
    .rxd8_ready   (rxd8_tready),
    .rxd8_valid   (rxd8_tvalid),
    .rxd8_data    (rxd8_tdata),
    .DEBUG_TESTER_ENABLE  (debug_test_en),
    .AUXCTRL      ( ),
    .SIMULATIONEND( )
  );

  // FT1248 protocol tracker with UART output
  wire ft_clk2uart;
  wire ft_rxd2uart;
  wire ft_txd2uart;

  nanosoc_ft1248x1_track u_nanosoc_ft1248x1_track (
    .ft_clk_i     (ft_clk_out),
    .ft_ssn_i     (ft_ssn_out),
    .ft_miso_i    (ft_miso_in),
    .ft_miosio_i  (ft_miosio_i),
    .aclk         (CLK),
    .aresetn      (NRST),
    .FTDI_CLK2UART_o  (ft_clk2uart),
    .FTDI_OP2UART_o   (ft_rxd2uart),
    .FTDI_IP2UART_o   (ft_txd2uart)
  );

  // UART capture of FT1248 tracked output
`ifndef COCOTB_SIM
  nanosoc_uart_capture #(
    .LOGFILENAME("logs/ft1248_op.log")
  ) u_nanosoc_uart_capture1 (
    .RESETn               (NRST),
    .CLK                  (ft_clk2uart),
    .RXD                  (ft_rxd2uart),
    .DEBUG_TESTER_ENABLE  ( ),
    .SIMULATIONEND        (),
    .AUXCTRL              ()
  );
`endif

endmodule
