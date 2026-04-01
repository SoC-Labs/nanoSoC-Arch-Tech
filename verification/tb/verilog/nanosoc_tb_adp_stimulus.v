//-----------------------------------------------------------------------------
// NanoSoC Testbench - ADP Stimulus and Capture
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : AXI stream file-based stimulus drivers and capture monitors
//            for ADP command channel (rx0/tx0) and data channel (rx1/tx1)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_tb_adp_stimulus #(
  parameter ADP_FILENAME     = "adp.cmd",
  parameter DATA_IN_FILENAME = "data_in.csv",
  parameter DATA_OUT_FILENAME= "logs/data_out.csv",
  parameter FAST_LOAD        = 0,
  parameter TAG              = ""
)(
  input  wire        CLK,
  input  wire        NRST,
  // ADP command channel (rx0 = to DUT, tx0 = from DUT)
  input  wire        axis_rx0_tready,
  output wire        axis_rx0_tvalid,
  output wire [7:0]  axis_rx0_tdata8,
  input  wire        axis_tx0_tready,
  input  wire        axis_tx0_tvalid,
  input  wire [7:0]  axis_tx0_tdata8,
  // Data channel (rx1 = to DUT, tx1 = from DUT)
  input  wire        axis_rx1_tready,
  output wire        axis_rx1_tvalid,
  output wire [7:0]  axis_rx1_tdata8,
  input  wire        axis_tx1_tready,
  input  wire        axis_tx1_tvalid,
  input  wire [7:0]  axis_tx1_tdata8,
  // Control
  output wire        test_done,
  output wire        debug_test_en
);

  // ADP command file reader -> rx0
  nanosoc_axi_stream_io_8_txd_from_file #(
    .TXDFILENAME(ADP_FILENAME),
    .FAST_LOAD(FAST_LOAD)
  ) u_nanosoc_axi_stream_io_adp_txd_from_file (
    .aclk       (CLK),
    .aresetn    (NRST),
    .txd8_ready (axis_rx0_tready),
    .txd8_valid (axis_rx0_tvalid),
    .txd8_data  (axis_rx0_tdata8)
  );

  // Monitor: log ADP commands being sent (rx0)
  nanosoc_axi_stream_io_8_rxd_to_file #(
    .RXDFILENAME("logs/extadp_in.log")
  ) u_nanosoc_axi_stream_io_8_adprxd_to_file (
    .aclk         (CLK),
    .aresetn      (NRST),
    .eof_received ( ),
    .rxd8_ready   ( ),
    .rxd8_valid   (axis_rx0_tvalid & axis_rx0_tready),
    .rxd8_data    (axis_rx0_tdata8)
  );

  // Monitor: log ADP responses from DUT (tx0) - drives test_done
  nanosoc_axi_stream_io_8_rxd_to_file #(
    .RXDFILENAME("logs/extadp_out.log"),
    .VERBOSE(0)
  ) u_nanosoc_axi_stream_io_stream_adp_rxd_to_file (
    .aclk         (CLK),
    .aresetn      (NRST),
    .eof_received (test_done),
    .rxd8_ready   (axis_tx0_tready),
    .rxd8_valid   (axis_tx0_tvalid),
    .rxd8_data    (axis_tx0_tdata8)
  );

  // Capture: ADP output with debug tester enable detection
  soclabs_axis8_capture #(
    .LOGFILENAME("logs/extio_adp_out.log"),
    .TAG(TAG)
  ) u_soclabs_axis8_capture1 (
    .RESETn               (NRST),
    .CLK                  (CLK),
    .RXD8_READY           ( ),
    .RXD8_VALID           (axis_tx0_tvalid & axis_tx0_tready),
    .RXD8_DATA            (axis_tx0_tdata8),
    .DEBUG_TESTER_ENABLE  (debug_test_en),
    .SIMULATIONEND        (),
    .AUXCTRL              ()
  );

  // Data input file reader -> rx1
  nanosoc_axi_stream_io_8_txd_from_datafile #(
    .TXDFILENAME(DATA_IN_FILENAME)
  ) u_nanosoc_axi_stream_io_8_txd_from_datafile (
    .aclk       (CLK),
    .aresetn    (NRST),
    .txd8_ready (axis_rx1_tready),
    .txd8_valid (axis_rx1_tvalid),
    .txd8_data  (axis_rx1_tdata8)
  );

  // Monitor: log data output from DUT (tx1)
  nanosoc_axi_stream_io_8_rxd_to_file #(
    .RXDFILENAME(DATA_OUT_FILENAME)
  ) u_nanosoc_axi_stream_io_extdata_8_rxd_to_file (
    .aclk         (CLK),
    .aresetn      (NRST),
    .eof_received ( ),
    .rxd8_ready   (axis_tx1_tready),
    .rxd8_valid   (axis_tx1_tvalid),
    .rxd8_data    (axis_tx1_tdata8)
  );

endmodule
