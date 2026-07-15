//-----------------------------------------------------------------------------
// NanoSoC Pin Multiplexing Controller adapted from ARM CMSDK Pin multiplexing control
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright � 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// The confidential and proprietary information contained in this file may
// only be used by a person authorised under and to the extent permitted
// by a subsisting licensing agreement from Arm Limited or its affiliates.
//
//            (C) COPYRIGHT 2010-2013 Arm Limited or its affiliates.
//                ALL RIGHTS RESERVED
//
// This entire notice must be reproduced on all copies of this file
// and copies of this file may only be made by a person if such person is
// permitted to do so under the terms of a subsisting license agreement
// from Arm Limited or its affiliates.
//
//      SVN Information
//
//      Checked In          : $Date: 2017-10-10 15:55:38 +0100 (Tue, 10 Oct 2017) $
//
//      Revision            : $Revision: 371321 $
//
//      Release Information : Cortex-M System Design Kit-r1p1-00rel0
//
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : Pin multiplexing control for example Cortex-M0/Cortex-M0+
//            microcontroller
//-----------------------------------------------------------------------------
//
module nanosoc_pin_mux (
    //-------------------------------------------
    // I/O ports
    //-------------------------------------------
    // UART
    output wire             uart0_rxd,
    input  wire             uart0_txd,
    input  wire             uart0_txen,
    output wire             uart1_rxd,
    input  wire             uart1_txd,
    input  wire             uart1_txen,
    output wire             uart2_rxd,
    input  wire             uart2_txd,
    input  wire             uart2_txen,

    // Timer
    output wire             timer0_extin,
    output wire             timer1_extin,

`ifdef CORTEX_M0PLUS
`ifdef ARM_CMSDK_INCLUDE_MTB
    // CoreSight MTB M0+
    output wire             TSTART,
    output wire             TSTOP,
`endif
`endif

    // IO Ports
    //
    // p0_in / p1_in are the SAMPLED PAD VALUES, driven in from outside this
    // block. They were originally OUTPUTS, synthesized here by a "port input
    // feedback" network that modelled the pads internally (read back what you
    // drove, else a pull-up '1'). That made sense when this block owned the
    // pads. It no longer does: the SoC takes real pad inputs and routes them
    // to the GPIO blocks directly.
    //
    // When that refactor happened, nanosoc_ss_systemctrl stopped connecting
    // these ports (`.p1_in ( ), // was(p1_in) now from pad inputs`) but the
    // feedback network was left in place — and this block DERIVES the UART
    // receive lines from p1_in (see `uart2_rxd` below). The result was that
    // UART2's RXD was a loopback of the SoC's own P1[4] drive (or a constant
    // '1'), and a host byte could never reach the console receiver on any
    // target. Making these true inputs is what closes that path.
    input  wire  [15:0]     p0_in,
    input  wire  [15:0]     p0_out,
    input  wire  [15:0]     p0_outen,
    input  wire  [15:0]     p0_altfunc,

    input  wire  [15:0]     p1_in,
    input  wire  [15:0]     p1_out,
    input  wire  [15:0]     p1_outen,
    input  wire  [15:0]     p1_altfunc,

    output wire  [15:0]     p1_out_mux,    //alt-function mux
    output wire  [15:0]     p1_out_en_mux  //alt-function mux
);

  //-------------------------------------------
  // Internal wires
  //-------------------------------------------
  wire      [15:0]     p0_out_mux;
  wire      [15:0]     p0_out_en_mux;
// wire      [15:0]     p1_out_mux;    // promoted to block output
// wire      [15:0]     p1_out_en_mux; // promoted to block output

  //-------------------------------------------
  // Beginning of main code
  //-------------------------------------------
  // inputs
  assign    uart0_rxd    = p1_in[0];
  assign    uart1_rxd    = p1_in[2];
  assign    uart2_rxd    = p1_in[4];
  assign    timer0_extin = p1_in[8];
  assign    timer1_extin = p1_in[9];


  // Output function mux
  assign    p0_out_mux    = p0_out; // No function muxing for Port 0

  assign    p1_out_mux[0] =                               p1_out[0];
  assign    p1_out_mux[1] = (p1_altfunc[1]) ? uart0_txd : p1_out[1];
  assign    p1_out_mux[2] =                               p1_out[2];
  assign    p1_out_mux[3] = (p1_altfunc[3]) ? uart1_txd : p1_out[3];
  assign    p1_out_mux[4] =                               p1_out[4];
  assign    p1_out_mux[5] = (p1_altfunc[5]) ? uart2_txd : p1_out[5];
  assign    p1_out_mux[15:6] = p1_out[15:6];

`ifdef CORTEX_M0PLUS
`ifdef ARM_CMSDK_INCLUDE_MTB
  // MTB control
  // The TSTART/TSTOP synchronising logic is instantiated within the
  // cmsdk_mcu_system module.
  assign    TSTART       = p1_in[7];
  assign    TSTOP        = p1_in[6];
  // This allows TSTART and TSTOP to be controlled from external sources.
`endif
`endif

  // Output enable mux
  assign    p0_out_en_mux   = p0_outen; // No function muxing for Port 0

  assign    p1_out_en_mux[0] =                                p1_outen[0];
  assign    p1_out_en_mux[1] = (p1_altfunc[1]) ? uart0_txen : p1_outen[1];
  assign    p1_out_en_mux[2] =                                p1_outen[2];
  assign    p1_out_en_mux[3] = (p1_altfunc[3]) ? uart1_txen : p1_outen[3];
  assign    p1_out_en_mux[4] =                                p1_outen[4];
  assign    p1_out_en_mux[5] = (p1_altfunc[5]) ? uart2_txen : p1_outen[5];
  assign    p1_out_en_mux[15:6] = p1_outen[15:6];


// Port input feedback — REMOVED.
//
// This block used to synthesize p0_in/p1_in itself:
//
//   assign p0_in[N] = p0_out_en_mux[N] ? p0_out_mux[N] : 1'b1;
//   assign p1_in[N] = p1_out_en_mux[N] ? p1_out_mux[N] : 1'b1;
//
// i.e. an internal pad model: read back whatever the SoC drove, else a
// pull-up '1'. That was correct when this block owned the pads.
//
// It is now WRONG, and was actively harmful: the SoC takes real pad inputs
// and nanosoc_ss_systemctrl had stopped connecting these ports, so the
// feedback network kept driving them from the SoC's own outputs — while
// `uart2_rxd` (above) is derived from p1_in[4]. UART2's receive line was
// therefore a loopback of the SoC's own GPIO drive, never the pad, and no
// host byte could reach the console receiver on FPGA or ASIC.
//
// p0_in/p1_in are now true inputs, driven from the sampled pads. See
// mps3-nanosoc-platform tests/uart2_rx_path for the bench that pins this down.

endmodule
