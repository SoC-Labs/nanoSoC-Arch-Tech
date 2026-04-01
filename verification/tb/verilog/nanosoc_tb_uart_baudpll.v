//-----------------------------------------------------------------------------
// NanoSoC Testbench - UART Baud Rate PLL and Capture
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// Abstract : Baud rate divider with phase-lock loop for UART capture.
//            Generates recovered baud clock from UART TX data edges.
//            38400 baud from 24MHz PCLK: 24000000/6250 = 38400
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_tb_uart_baudpll #(
  parameter BAUDPROGDIV16 = 389,
  parameter LOGFILENAME   = "logs/uart2.log",
  parameter TAG           = ""
)(
  input  wire        PCLK,
  input  wire        NRST,
  input  wire        UARTXD_in,
  input  wire        FT1248MODE,
  output wire        debug_test_en
);

  // Baud rate divider
  reg [8:0] bauddiv;
  wire      baudclken = (bauddiv == 9'b0);

  always @(negedge NRST or posedge PCLK)
    if (!NRST)
      bauddiv <= 0;
    else
      bauddiv <= (baudclken) ? (BAUDPROGDIV16-1) : (bauddiv - 1);

  wire baudx16_clk = bauddiv[8];

  // UART data with FT1248MODE override
  wire UARTXD = UARTXD_in | FT1248MODE;

  // Edge detection for phase lock
  reg UARTXD_del;
  always @(negedge NRST or posedge baudx16_clk)
    if (!NRST)
      UARTXD_del <= 1'b0;
    else
      UARTXD_del <= UARTXD;

  wire UARTXD_edge = UARTXD_del ^ UARTXD;

  // Phase-locked divider (divide-by-16)
  reg [3:0] pllq;
  always @(negedge NRST or posedge baudx16_clk)
    if (!NRST)
      pllq[3:0] <= 4'b0000;
    else
      if (UARTXD_edge)
        pllq[3:0] <= 4'b0110; // sync to mid bit-time
      else
        pllq[3:0] <= pllq[3:0] - 1;

  wire baud_clk = pllq[3];

  reg baud_clk_del;
  always @(negedge NRST or posedge PCLK)
    if (!NRST)
      baud_clk_del <= 1'b1;
    else
      baud_clk_del <= baud_clk;

  // UART clock selection
  wire FASTMODE = 1'b0;
  wire uart_clk = (FASTMODE) ? PCLK : baud_clk;

  // UART capture
`ifndef COCOTB_SIM
  nanosoc_uart_capture #(
    .LOGFILENAME(LOGFILENAME),
    .TAG(TAG)
  ) u_nanosoc_uart_capture (
    .RESETn               (NRST),
    .CLK                  (uart_clk),
    .RXD                  (UARTXD),
    .DEBUG_TESTER_ENABLE  (debug_test_en),
    .SIMULATIONEND        (),
    .AUXCTRL              ()
  );
`endif

endmodule
