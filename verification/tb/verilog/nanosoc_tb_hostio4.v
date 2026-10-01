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

  // Pin values, as a board's pins would carry them: always a 0 or a 1.
  //
  // hostio4_target drives P1[6:3] from its data registers whenever its pad
  // enable is on, and a data register no stimulus has written yet (an rx
  // buffer, read back after the SoC resets itself and the model does not)
  // is X in simulation. That X reached the pins: after the testbench's second
  // reset of the SoC, P1[6:3] were X for whole microseconds, so every read of
  // GPIO port 1 in that window returned 0000ffXX. stage0 reads its strap
  // (P1[7]) there when it is built with Arm GNU 13.3 (a smaller boot ROM, so
  // the read comes 6.1 us after the reset instead of 7.3 us), and the stage0
  // trace check cannot compare an X. The SoC's own logic only ever looked at
  // P1[7], which the pull-down keeps 0.
  //
  // A real host's register holds a 0 or a 1 (an FPGA flip-flop powers up 0),
  // so the model drives 0 for a bit it does not know, and an enable it does
  // not know leaves the pin undriven (the pull-up). Every bit the model does
  // know is driven exactly as before: with defined values this is the same
  // model.
  function pin01;          // 1 only for a known 1: X/Z -> 0
    input b;
    pin01 = (b === 1'b1);
  endfunction

  wire       drive_ok = (FT1248MODE === 1'b0);              // EXTIO mode, known
  wire       ioack_pin = pin01(ioack);
  wire [3:0] data_pin  = {pin01(iodata4_o[3]), pin01(iodata4_o[2]),
                          pin01(iodata4_o[1]), pin01(iodata4_o[0])};
  wire [3:0] data_oe   = {4{drive_ok}} & {(iodata4_t[3] === 1'b0), (iodata4_t[2] === 1'b0),
                                          (iodata4_t[1] === 1'b0), (iodata4_t[0] === 1'b0)};

  // Tristate buffer emulation
  assign ioreq1    = FT1248MODE ? 1'b0 : P1[0];
  assign ioreq2    = FT1248MODE ? 1'b0 : P1[1];
  bufif1 #1 (P1[2], ioack_pin,   drive_ok);
  bufif1 #1 (P1[3], data_pin[0], data_oe[0]);
  bufif1 #1 (P1[4], data_pin[1], data_oe[1]);
  bufif1 #1 (P1[5], data_pin[2], data_oe[2]);
  bufif1 #1 (P1[6], data_pin[3], data_oe[3]);
  assign iodata4_i = {4{FT1248MODE}} | P1[6:3];

endmodule
