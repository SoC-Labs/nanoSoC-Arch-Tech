//-----------------------------------------------------------------------------
// NanoSoC Testbench - Debug Tester
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : CMSDK debug tester with GPIO tristate connections and
//            JTAG/SWD debug interface pullups
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_tb_debug_tester #(
  parameter BE = 0
)(
  input  wire        CLK,
  input  wire        NRST_ext,
  input  wire        debug_test_en,
  // GPIO P0 connection (directly driven by debug tester)
  inout  wire [7:0]  P0,
  // JTAG/SWD debug interface
  inout  wire        nTRST,
  inout  wire        TDI,
  inout  wire        TDO,
  inout  wire        SWDIOTMS,
  inout  wire        SWCLKTCK
);

  wire [5:0] debug_command;
  wire       debug_running;
  wire       debug_err;

  // Debug interface pullups/pulldowns
  pullup   (nTRST);
  pullup   (TDI);
  pullup   (TDO);
  pullup   (SWDIOTMS);
  pulldown (SWCLKTCK);

  // Debug command/status pulldowns
  genvar gi;
  generate
    for (gi = 0; gi < 6; gi = gi + 1) begin : gen_dbgcmd_pd
      pulldown(debug_command[gi]);
    end
  endgenerate
  pulldown(debug_running);
  pulldown(debug_err);

  // Tristate logic for GPIO connection
  bufif1 (P0[7], debug_running, debug_test_en);
  bufif1 (P0[6], debug_err,     debug_test_en);
  bufif1 (debug_command[5], P0[5], debug_test_en);
  bufif1 (debug_command[4], P0[4], debug_test_en);
  bufif1 (debug_command[3], P0[3], debug_test_en);
  bufif1 (debug_command[2], P0[2], debug_test_en);
  bufif1 (debug_command[1], P0[1], debug_test_en);
  bufif1 (debug_command[0], P0[0], debug_test_en);

  cmsdk_debug_tester #(
    .ROM_MEMFILE((BE==1) ? "debugtester_be.hex" : "debugtester_le.hex")
  ) u_cmsdk_debug_tester (
    .CLK                 (CLK),
    .PORESETn            (NRST_ext),
    .DBGCMD              (debug_command[5:0]),
    .DBGRUNNING          (debug_running),
    .DBGERROR            (debug_err),
    .TRACECLK            (1'b0),
    .TRACEDATA           (4'h0),
    .SWV                 (1'b0),
    .TDO                 (TDO),
    .nTRST               (nTRST),
    .SWCLKTCK            (SWCLKTCK),
    .TDI                 (TDI),
    .SWDIOTMS            (SWDIOTMS)
  );

endmodule
