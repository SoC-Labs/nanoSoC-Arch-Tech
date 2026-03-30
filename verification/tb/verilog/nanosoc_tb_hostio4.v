//-----------------------------------------------------------------------------
// NanoSoC Testbench - HOSTIO4 Stream Interface
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : HOSTIO4 target interface with tristate buffer emulation
//            Active when P1[7] (FT1248MODE) is low (EXTIO mode)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_tb_hostio4 (
  input  wire        CLK,
  input  wire        NRST,
  input  wire        TEST,
  inout  wire [7:0]  P1,
  output wire        FT1248MODE,
  // 4-channel AXIS interface
  output wire        axis_rx0_tready,
  output wire        axis_rx0_tvalid,
  output wire [7:0]  axis_rx0_tdata8,
  output wire        axis_rx1_tready,
  output wire        axis_rx1_tvalid,
  output wire [7:0]  axis_rx1_tdata8,
  output wire        axis_tx0_tready,
  output wire        axis_tx0_tvalid,
  output wire [7:0]  axis_tx0_tdata8,
  output wire        axis_tx1_tready,
  output wire        axis_tx1_tvalid,
  output wire [7:0]  axis_tx1_tdata8,
  // External IO signals
  output wire        ioreq1,
  output wire        ioreq2,
  output wire        ioack
);

  // Internal IO interface signals
  wire [3:0] iodata4_i;
  wire [3:0] iodata4_o;
  wire [3:0] iodata4_e;
  wire [3:0] iodata4_t;

  assign FT1248MODE = P1[7];

  hostio4_target u_hostio4_target (
    .clk             ( CLK             ),
    .resetn          ( NRST            ),
    .testmode        ( TEST            ),
    // RX 4-channel AXIS interface
    .axis_rx0_tready ( axis_rx0_tready ),
    .axis_rx0_tvalid ( axis_rx0_tvalid ),
    .axis_rx0_tdata8 ( axis_rx0_tdata8 ),
    .axis_rx1_tready ( axis_rx1_tready ),
    .axis_rx1_tvalid ( axis_rx1_tvalid ),
    .axis_rx1_tdata8 ( axis_rx1_tdata8 ),
    .axis_tx0_tready ( axis_tx0_tready ),
    .axis_tx0_tvalid ( axis_tx0_tvalid ),
    .axis_tx0_tdata8 ( axis_tx0_tdata8 ),
    .axis_tx1_tready ( axis_tx1_tready ),
    .axis_tx1_tvalid ( axis_tx1_tvalid ),
    .axis_tx1_tdata8 ( axis_tx1_tdata8 ),
    // External IO interface
    .iodata4_i       ( iodata4_i       ),
    .iodata4_o       ( iodata4_o       ),
    .iodata4_e       ( iodata4_e       ),
    .iodata4_t       ( iodata4_t       ),
    .ioreq1_a        ( ioreq1          ),
    .ioreq2_a        ( ioreq2          ),
    .ioack_o         ( ioack           )
  );

  // Tristate buffer emulation
  assign ioreq1    = FT1248MODE ? 1'b0 : P1[0];
  assign ioreq2    = FT1248MODE ? 1'b0 : P1[1];
  bufif0 #1 (P1[2], ioack,        FT1248MODE);
  bufif0 #1 (P1[3], iodata4_o[0], (iodata4_t[0] | FT1248MODE));
  bufif0 #1 (P1[4], iodata4_o[1], (iodata4_t[1] | FT1248MODE));
  bufif0 #1 (P1[5], iodata4_o[2], (iodata4_t[2] | FT1248MODE));
  bufif0 #1 (P1[6], iodata4_o[3], (iodata4_t[3] | FT1248MODE));
  assign iodata4_i = {4{FT1248MODE}} | P1[6:3];

endmodule
