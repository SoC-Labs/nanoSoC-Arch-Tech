//-----------------------------------------------------------------------------
// NanoSoC APB Subsystem adapted from Arm CMSDK APB Subsystem
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2021-6, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// The confidential and proprietary information contained in this file may
// only be used by a person authorised under and to the extent permitted
// by a subsisting licensing agreement from Arm Limited or its affiliates.
//
//            (C) COPYRIGHT 2010-2011 Arm Limited or its affiliates.
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
// Abstract : APB sub system
//-----------------------------------------------------------------------------
module nanosoc_soc_peripheral_apb_ss #(
  // Enable setting for APB extension ports
  // By default, all four extension ports are not used.
  // This can be overriden by parameters at instantiations.
  parameter APB_EXT_PORT12_ENABLE = 0,
  parameter APB_EXT_PORT13_ENABLE = 0,
  parameter APB_EXT_PORT14_ENABLE = 0,
  parameter APB_EXT_PORT15_ENABLE = 0,
  // Latch HWDATA at the AHB address phase in the AHB-to-APB bridge.
  // Default 0 preserves legacy single-master behaviour. Set to 1 when this
  // peripheral block is a target on a multi-master AHB matrix (e.g. driven by
  // a Cortex-M0+ over the multicore interconnect): with REGISTER_WDATA=0 the
  // bridge samples HWDATA combinatorially during the APB access, so a master
  // that advances to its next transaction before the APB write completes
  // corrupts back-to-back writes. REGISTER_WDATA=1 also enables the
  // write-retire hold below. See the multicore-system local-override history.
  parameter REGISTER_WDATA = 0,
  // 1 = instantiate the two socdebug_usrt_control debug byte-stream UARTs on
  // the uart0/uart1 slots (0x4000/0x5000). 0 = omit them: the slots answer
  // zero / PREADY high / no error, the usrt*_txd stream idles (tvalid 0), the
  // usrt*_rxd stream is always accepted (tready 1) and every UART0/1 interrupt
  // line is 0. Used by dies that tie the USRT streams off at the wrapper.
  parameter USRT_PRESENT = 1,
  // 1 = instantiate cmsdk_apb_test_slave on slot 0xB000 (validation only).
  // 0 = omit it: the slot answers zero / PREADY high / no error.
  parameter TEST_SLAVE_PRESENT = 1
) (
  // AHB interface for AHB to APB bridge
  input  wire           HCLK,
  input  wire           HRESETn,

  input  wire           HSEL,
  input  wire   [15:0]  HADDR,
  input  wire    [1:0]  HTRANS,
  input  wire           HWRITE,
  input  wire    [2:0]  HSIZE,
  input  wire    [3:0]  HPROT,
  input  wire           HREADY,
  input  wire   [31:0]  HWDATA,
  output wire           HREADYOUT,
  output wire   [31:0]  HRDATA,
  output wire           HRESP,

  input  wire           PCLK,     // Peripheral clock
  input  wire           PCLKG,    // Gate PCLK for bus interface only
  input  wire           PCLKEN,   // Clock divider for AHB to APB bridge
  input  wire           PRESETn,  // APB reset

  output wire   [11:0]  PADDR,
  output wire           PWRITE,
  output wire   [31:0]  PWDATA,
  output wire           PENABLE,

  output wire           ext12_psel,
  output wire           ext13_psel,
  output wire           ext14_psel,
  output wire           ext15_psel,

  input  wire   [31:0]  ext12_prdata,
  input  wire           ext12_pready,
  input  wire           ext12_pslverr,

  input  wire   [31:0]  ext13_prdata,
  input  wire           ext13_pready,
  input  wire           ext13_pslverr,

  input  wire   [31:0]  ext14_prdata,
  input  wire           ext14_pready,
  input  wire           ext14_pslverr,

  input  wire   [31:0]  ext15_prdata,
  input  wire           ext15_pready,
  input  wire           ext15_pslverr,

  output wire           APBACTIVE,

  // Peripherals
  // USRT0 TXD axi byte stream
  output wire           usrt0_txd_tvalid,
  output wire    [7:0]  usrt0_txd_tdata,
  input  wire           usrt0_txd_tready,
  
  // USRT0 RXD axi byte stream
  input  wire           usrt0_rxd_tvalid,
  input  wire    [7:0]  usrt0_rxd_tdata,
  output wire           usrt0_rxd_tready,

  // USRT1 TXD axi byte stream
  output wire           usrt1_txd_tvalid,
  output wire    [7:0]  usrt1_txd_tdata,
  input  wire           usrt1_txd_tready,
  
  // USRT1 RXD axi byte stream
  input  wire           usrt1_rxd_tvalid,
  input  wire    [7:0]  usrt1_rxd_tdata,
  output wire           usrt1_rxd_tready,

  // UART2
  input  wire           uart2_rxd,
  output wire           uart2_txd,
  output wire           uart2_txen,

  // Timer
  input  wire           timer0_extin,
  input  wire           timer1_extin,

  // Interrupt outputs
  output wire   [31:0]  apbsubsys_interrupt,
  output wire           watchdog_interrupt,
  output wire           watchdog_reset
);

  // --------------------------------------------------------------------------
  // Internal wires
  // --------------------------------------------------------------------------
  wire     [15:0]  i_paddr;
  wire             i_psel;
  wire             i_penable;
  wire             i_pwrite;
  wire     [2:0]   i_pprot;
  wire     [3:0]   i_pstrb;
  wire     [31:0]  i_pwdata;

  // wire from APB slave mux to APB bridge
  wire             i_pready_mux;
  wire     [31:0]  i_prdata_mux;
  wire             i_pslverr_mux;

  // Peripheral signals
  wire             timer0_psel;
  wire     [31:0]  timer0_prdata;
  wire             timer0_pready;
  wire             timer0_pslverr;

  wire             timer1_psel;
  wire     [31:0]  timer1_prdata;
  wire             timer1_pready;
  wire             timer1_pslverr;

  wire             dualtimer2_psel;
  wire     [31:0]  dualtimer2_prdata;
  wire             dualtimer2_pready;
  wire             dualtimer2_pslverr;

  wire             watchdog_psel;
  wire     [31:0]  watchdog_prdata;
  wire             watchdog_pready;
  wire             watchdog_pslverr;

  wire             uart0_psel;
  wire     [31:0]  uart0_prdata;
  wire             uart0_pready;
  wire             uart0_pslverr;

  wire             uart1_psel;
  wire     [31:0]  uart1_prdata;
  wire             uart1_pready;
  wire             uart1_pslverr;

  wire             uart2_psel;
  wire     [31:0]  uart2_prdata;
  wire             uart2_pready;
  wire             uart2_pslverr;

  wire             test_slave_psel;
  wire     [31:0]  test_slave_prdata;
  wire             test_slave_pready;
  wire             test_slave_pslverr;

  wire             psel3;
  wire             psel7;
  wire             psel9;
  wire             psel10;

  // Interrupt signals from peripherals
  wire             timer0_int;
  wire             timer1_int;
  wire             dualtimer2a_int;
  wire             dualtimer2b_int;
  wire             dualtimer2_comb_int;

  wire             uart0_txint;
  wire             uart0_rxint;
  wire             uart0_txovrint;
  wire             uart0_rxovrint;
  wire             uart0_combined_int;

  wire             uart1_txint;
  wire             uart1_rxint;
  wire             uart1_txovrint;
  wire             uart1_rxovrint;
  wire             uart1_combined_int;

  wire             uart2_txint;
  wire             uart2_rxint;
  wire             uart2_txovrint;
  wire             uart2_rxovrint;
  wire             uart2_combined_int;

  wire             uart0_overflow_int;
  wire             uart1_overflow_int;
  wire             uart2_overflow_int;

  wire             watchdog_int;
  wire             watchdog_rst;

  // Synchronized interrupt signals
  wire             i_uart0_txint;
  wire             i_uart0_rxint;
  wire             i_uart0_overflow_int;
  wire             i_uart1_txint;
  wire             i_uart1_rxint;
  wire             i_uart1_overflow_int;
  wire             i_uart2_txint;
  wire             i_uart2_rxint;
  wire             i_uart2_overflow_int;
  wire             i_timer0_int;
  wire             i_timer1_int;
  wire             i_dualtimer2_int;
  wire             i_watchdog_int;
  wire             i_watchdog_rst;

  // Bridge HREADYOUT before the (optional) write-retire hold below
  wire             i_hreadyout_raw;

  // AHB to APB bus bridge
  cmsdk_ahb_to_apb #(
    .ADDRWIDTH      (16),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (REGISTER_WDATA)
  ) u_ahb_to_apb (
    // AHB side
    .HCLK       (HCLK),
    .HRESETn    (HRESETn),
    .HSEL       (HSEL),
    .HADDR      (HADDR[15:0]),
    .HTRANS     (HTRANS),
    .HSIZE      (HSIZE),
    .HPROT      (HPROT),
    .HWRITE     (HWRITE),
    .HREADY     (HREADY),
    .HWDATA     (HWDATA),

    .HREADYOUT  (i_hreadyout_raw), // AHB Outputs (through write-retire hold)
    .HRDATA     (HRDATA),
    .HRESP      (HRESP),

    .PADDR      (i_paddr[15:0]),
    .PSEL       (i_psel),
    .PENABLE    (i_penable),
    .PSTRB      (i_pstrb),
    .PPROT      (i_pprot),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .APBACTIVE  (APBACTIVE),
    .PCLKEN     (PCLKEN),     // APB clock enable signal

    .PRDATA     (i_prdata_mux),
    .PREADY     (i_pready_mux),
    .PSLVERR    (i_pslverr_mux)
  );

  // -------------------------------------------------------------------------
  // Write-retire hold (only when REGISTER_WDATA=1).
  //
  // With REGISTER_WDATA=1 the bridge accepts the next AHB transaction IN the
  // ENDOK cycle (HREADYOUT=1 -> apb_select=1). A DATA write followed
  // immediately by a STATE read means the read's address phase overlaps the
  // write's final cycle; the bridge has not yet updated rwdata_reg, so the
  // STATE read can return stale data. Holding HREADYOUT=0 for the single ENDOK
  // cycle forces ENDOK->IDLE before the read address is captured, giving
  // rwdata_reg time to settle.
  //
  // When REGISTER_WDATA=0 this collapses to a direct passthrough, leaving
  // legacy timing bit-identical.
  // -------------------------------------------------------------------------
  generate if (REGISTER_WDATA) begin : g_write_retire_hold
    wire  i_ahb_accepted;
    assign i_ahb_accepted = HSEL & HTRANS[1] & HREADY;

    reg   r_last_was_write;
    always @(posedge HCLK or negedge HRESETn) begin
      if (!HRESETn)             r_last_was_write <= 1'b0;
      else if (i_ahb_accepted)  r_last_was_write <= HWRITE;
    end

    reg   r_prev_hreadyout;
    always @(posedge HCLK or negedge HRESETn) begin
      if (!HRESETn) r_prev_hreadyout <= 1'b1;  // bridge idles with HREADYOUT=1
      else          r_prev_hreadyout <= i_hreadyout_raw;
    end

    wire  w_hreadyout_rise = i_hreadyout_raw & ~r_prev_hreadyout;
    wire  w_wr_hold        = r_last_was_write & w_hreadyout_rise;

    assign HREADYOUT = i_hreadyout_raw & ~w_wr_hold;
  end else begin : g_no_write_retire_hold
    assign HREADYOUT = i_hreadyout_raw;
  end endgenerate

  // APB slave multiplexer
  cmsdk_apb_slave_mux #( // Parameter to determine which ports are used
    .PORT0_ENABLE  (1),                      // timer 0
    .PORT1_ENABLE  (1),                      // timer 1
    .PORT2_ENABLE  (1),                      // dual timer 0
    .PORT3_ENABLE  (1),                      // not used
    .PORT4_ENABLE  (1),                      // uart 0
    .PORT5_ENABLE  (1),                      // uart 1
    .PORT6_ENABLE  (1),                      // uart 2
    .PORT7_ENABLE  (1),                      // not used
    .PORT8_ENABLE  (1),                      // watchdog
    .PORT9_ENABLE  (1),                      // not used
    .PORT10_ENABLE (1),                      // not used
    .PORT11_ENABLE (1),                      // test slave for validation purpose
    .PORT12_ENABLE (APB_EXT_PORT12_ENABLE),
    .PORT13_ENABLE (APB_EXT_PORT13_ENABLE),
    .PORT14_ENABLE (APB_EXT_PORT14_ENABLE),
    .PORT15_ENABLE (APB_EXT_PORT15_ENABLE)
  ) u_apb_slave_mux (
    // Inputs
    .DECODE4BIT (i_paddr[15:12]),
    .PSEL       (i_psel),
    
    // PSEL (output) and return status & data (inputs) for each port
    .PSEL0    (timer0_psel),
    .PREADY0  (timer0_pready),
    .PRDATA0  (timer0_prdata),
    .PSLVERR0 (timer0_pslverr),

    .PSEL1    (timer1_psel),
    .PREADY1  (timer1_pready),
    .PRDATA1  (timer1_prdata),
    .PSLVERR1 (timer1_pslverr),

    .PSEL2    (dualtimer2_psel),
    .PREADY2  (dualtimer2_pready),
    .PRDATA2  (dualtimer2_prdata),
    .PSLVERR2 (dualtimer2_pslverr),

    .PSEL3    (psel3),
    .PREADY3  (1'b1),
    .PRDATA3  (32'h00000000),
    .PSLVERR3 (1'b1),

    .PSEL4    (uart0_psel),
    .PREADY4  (uart0_pready),
    .PRDATA4  (uart0_prdata),
    .PSLVERR4 (uart0_pslverr),

    .PSEL5    (uart1_psel),
    .PREADY5  (uart1_pready),
    .PRDATA5  (uart1_prdata),
    .PSLVERR5 (uart1_pslverr),

    .PSEL6    (uart2_psel),
    .PREADY6  (uart2_pready),
    .PRDATA6  (uart2_prdata),
    .PSLVERR6 (uart2_pslverr),

    .PSEL7    (psel7),
    .PREADY7  (1'b1),
    .PRDATA7  (32'h00000000),
    .PSLVERR7 (1'b1),

    .PSEL8    (watchdog_psel),
    .PREADY8  (watchdog_pready),
    .PRDATA8  (watchdog_prdata),
    .PSLVERR8 (watchdog_pslverr),

    .PSEL9    (psel9),
    .PREADY9  (1'b1),
    .PRDATA9  (32'h00000000),
    .PSLVERR9 (1'b1),

    .PSEL10    (psel10),
    .PREADY10  (1'b1),
    .PRDATA10  (32'h00000000),
    .PSLVERR10 (1'b1),

    .PSEL11    (test_slave_psel),
    .PREADY11  (test_slave_pready),
    .PRDATA11  (test_slave_prdata),
    .PSLVERR11 (test_slave_pslverr),

    .PSEL12    (ext12_psel),
    .PREADY12  (ext12_pready),
    .PRDATA12  (ext12_prdata),
    .PSLVERR12 (ext12_pslverr),

    .PSEL13    (ext13_psel),
    .PREADY13  (ext13_pready),
    .PRDATA13  (ext13_prdata),
    .PSLVERR13 (ext13_pslverr),

    .PSEL14    (ext14_psel),
    .PREADY14  (ext14_pready),
    .PRDATA14  (ext14_prdata),
    .PSLVERR14 (ext14_pslverr),

    .PSEL15    (ext15_psel),
    .PREADY15  (ext15_pready),
    .PRDATA15  (ext15_prdata),
    .PSLVERR15 (ext15_pslverr),

    // Output
    .PREADY    (i_pready_mux),
    .PRDATA    (i_prdata_mux),
    .PSLVERR   (i_pslverr_mux)
  );

  // -----------------------------------------------------------------
  // Timers

  cmsdk_apb_timer u_apb_timer_0 (
    .PCLK       (PCLK),             // PCLK for timer operation
    .PCLKG      (PCLKG),            // Gated PCLK for bus
    .PRESETn    (PRESETn),          // Reset
    // APB interface inputs
    .PSEL       (timer0_psel),
    .PADDR      (i_paddr[11:2]),
    .PENABLE    (i_penable),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .ECOREVNUM  (4'h0),             // Engineering-change-order revision bits

    // APB interface outputs
    .PRDATA     (timer0_prdata),
    .PREADY     (timer0_pready),
    .PSLVERR    (timer0_pslverr),

    .EXTIN      (timer0_extin),     // External input
    .TIMERINT   (timer0_int)        // interrupt output
  );

  cmsdk_apb_timer u_apb_timer_1 (
    .PCLK       (PCLK),             // PCLK for timer operation
    .PCLKG      (PCLKG),            // Gated PCLK for bus
    .PRESETn    (PRESETn),          // Reset
    // APB interface inputs
    .PSEL       (timer1_psel),
    .PADDR      (i_paddr[11:2]),
    .PENABLE    (i_penable),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .ECOREVNUM  (4'h0),             // Engineering-change-order revision bits

    // APB interface outputs
    .PRDATA     (timer1_prdata),
    .PREADY     (timer1_pready),
    .PSLVERR    (timer1_pslverr),

    .EXTIN      (timer1_extin),     // External input
    .TIMERINT   (timer1_int)        // interrupt output
  );

  // -----------------------------------------------------------------
  // Dual Timers
  cmsdk_apb_dualtimers u_apb_dualtimers_2 (
    // Inputs
    .PCLK       (PCLKG),
    .PRESETn    (PRESETn),
    .PENABLE    (i_penable),
    .PSEL       (dualtimer2_psel),
    .PADDR      (i_paddr[11:2]),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .TIMCLK     (PCLK),
    .TIMCLKEN1  (1'b1), // simple case:the timer 0 clock always enable
    .TIMCLKEN2  (1'b1), // simple case:the timer 1 clock always enable

    .ECOREVNUM  (4'h0), // Engineering-change-order revision bits

    // Outputs
    .PRDATA     (dualtimer2_prdata),

    .TIMINT1    (dualtimer2a_int),    // not used
    .TIMINT2    (dualtimer2b_int),    // not used
    .TIMINTC    (dualtimer2_comb_int)
  );

  // When using peripherals with APB (AMBA 2.0), the PREADY and PSLVERR
  // signals are not required. So we connect PREADY to 1 and PSLVERR to 0.
  assign dualtimer2_pslverr = 1'b0;
  assign dualtimer2_pready  = 1'b1;

  // -----------------------------------------------------------------
  // Watchdog
  cmsdk_apb_watchdog u_apb_watchdog (
    // Inputs
    .PCLK       (PCLKG),
    .PRESETn    (PRESETn),
    .PENABLE    (i_penable),
    .PSEL       (watchdog_psel),
    .PADDR      (i_paddr[11:2]),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .WDOGCLK    (PCLK),
    .WDOGCLKEN  (1'b1),
    .WDOGRESn   (PRESETn),

    .ECOREVNUM  (4'h0),             // Engineering-change-order revision bits

    // Outputs
    .PRDATA     (watchdog_prdata),

    .WDOGINT    (watchdog_int),     // connect to NMI
    .WDOGRES    (watchdog_rst)      // connect to reset generator
  );

  // When using peripherals with APB (AMBA 2.0), the PREADY and PSLVERR
  // signals are not required. So we connect PREADY to 1 and PSLVERR to 0.
  assign watchdog_pslverr = 1'b0;
  assign watchdog_pready  = 1'b1;

  // -----------------------------------------------------------------
  // UARTs
  generate
  if (USRT_PRESENT) begin : gen_usrt_0
  socdebug_usrt_control u_apb_usrt_0 (
    .PCLK              (PCLK),     // Peripheral clock
    .PCLKG             (PCLKG),    // Gated PCLK for bus
    .PRESETn           (PRESETn),  // Reset

    .PSEL              (uart0_psel),     // APB interface inputs
    .PADDR             (i_paddr[11:2]),
    .PENABLE           (i_penable),
    .PWRITE            (i_pwrite),
    .PWDATA            (i_pwdata),

    .PRDATA            (uart0_prdata),   // APB interface outputs
    .PREADY            (uart0_pready),
    .PSLVERR           (uart0_pslverr),

    .ECOREVNUM         (4'h0),// Engineering-change-order revision bits

    // USRT0 Interface - From USRT TXD
    .TX_VALID_o        (usrt0_txd_tvalid),
    .TX_DATA8_o        (usrt0_txd_tdata),
    .TX_READY_i        (usrt0_txd_tready),

    // USRT1 Interface - To USRT RXD
    .RX_VALID_i        (usrt0_rxd_tvalid),
    .RX_DATA8_i        (usrt0_rxd_tdata),
    .RX_READY_o        (usrt0_rxd_tready),

    .TXINT             (uart0_txint),       // Transmit Interrupt
    .RXINT             (uart0_rxint),       // Receive  Interrupt
    .TXOVRINT          (uart0_txovrint),    // Transmit Overrun Interrupt
    .RXOVRINT          (uart0_rxovrint),    // Receive  Overrun Interrupt
    .UARTINT           (uart0_combined_int) // Combined Interrupt
  );
  end else begin : gen_no_usrt_0
  // USRT0 absent: APB slot answers zero/ready, streams idle, interrupts low.
  assign uart0_prdata       = 32'h00000000;
  assign uart0_pready       = 1'b1;
  assign uart0_pslverr      = 1'b0;
  assign usrt0_txd_tvalid   = 1'b0;
  assign usrt0_txd_tdata    = 8'h00;
  assign usrt0_rxd_tready   = 1'b1;
  assign uart0_txint        = 1'b0;
  assign uart0_rxint        = 1'b0;
  assign uart0_txovrint     = 1'b0;
  assign uart0_rxovrint     = 1'b0;
  assign uart0_combined_int = 1'b0;
  wire   _unused_usrt0 = &{1'b0, uart0_psel, usrt0_txd_tready, usrt0_rxd_tvalid, usrt0_rxd_tdata};
  end
  endgenerate

  generate
  if (USRT_PRESENT) begin : gen_usrt_1
  socdebug_usrt_control u_apb_usrt_1 (
    .PCLK              (PCLK),     // Peripheral clock
    .PCLKG             (PCLKG),    // Gated PCLK for bus
    .PRESETn           (PRESETn),  // Reset

    .PSEL              (uart1_psel),     // APB interface inputs
    .PADDR             (i_paddr[11:2]),
    .PENABLE           (i_penable),
    .PWRITE            (i_pwrite),
    .PWDATA            (i_pwdata),

    .PRDATA            (uart1_prdata),   // APB interface outputs
    .PREADY            (uart1_pready),
    .PSLVERR           (uart1_pslverr),

    .ECOREVNUM         (4'h0),// Engineering-change-order revision bits

    // USRT1 Interface - From USRT TXD
    .TX_VALID_o        (usrt1_txd_tvalid),
    .TX_DATA8_o        (usrt1_txd_tdata),
    .TX_READY_i        (usrt1_txd_tready),

    // USRT1 Interface - To USRT RXD
    .RX_VALID_i        (usrt1_rxd_tvalid),
    .RX_DATA8_i        (usrt1_rxd_tdata),
    .RX_READY_o        (usrt1_rxd_tready),

    .TXINT             (uart1_txint),       // Transmit Interrupt
    .RXINT             (uart1_rxint),       // Receive  Interrupt
    .TXOVRINT          (uart1_txovrint),    // Transmit Overrun Interrupt
    .RXOVRINT          (uart1_rxovrint),    // Receive  Overrun Interrupt
    .UARTINT           (uart1_combined_int) // Combined Interrupt
  );
  end else begin : gen_no_usrt_1
  // USRT1 absent: APB slot answers zero/ready, streams idle, interrupts low.
  assign uart1_prdata       = 32'h00000000;
  assign uart1_pready       = 1'b1;
  assign uart1_pslverr      = 1'b0;
  assign usrt1_txd_tvalid   = 1'b0;
  assign usrt1_txd_tdata    = 8'h00;
  assign usrt1_rxd_tready   = 1'b1;
  assign uart1_txint        = 1'b0;
  assign uart1_rxint        = 1'b0;
  assign uart1_txovrint     = 1'b0;
  assign uart1_rxovrint     = 1'b0;
  assign uart1_combined_int = 1'b0;
  wire   _unused_usrt1 = &{1'b0, uart1_psel, usrt1_txd_tready, usrt1_rxd_tvalid, usrt1_rxd_tdata};
  end
  endgenerate

  cmsdk_apb_uart u_apb_uart_2 (
    .PCLK              (PCLK),     // Peripheral clock
    .PCLKG             (PCLKG),    // Gated PCLK for bus
    .PRESETn           (PRESETn),  // Reset

    .PSEL              (uart2_psel),     // APB interface inputs
    .PADDR             (i_paddr[11:2]),
    .PENABLE           (i_penable),
    .PWRITE            (i_pwrite),
    .PWDATA            (i_pwdata),

    .PRDATA            (uart2_prdata),   // APB interface outputs
    .PREADY            (uart2_pready),
    .PSLVERR           (uart2_pslverr),

    .ECOREVNUM         (4'h0),// Engineering-change-order revision bits

    .RXD               (uart2_rxd),      // Receive data

    .TXD               (uart2_txd),      // Transmit data
    .TXEN              (uart2_txen),     // Transmit Enabled

    .BAUDTICK          (),   // Baud rate x16 tick output (for testing)

    .TXINT             (uart2_txint),       // Transmit Interrupt
    .RXINT             (uart2_rxint),       // Receive  Interrupt
    .TXOVRINT          (uart2_txovrint),    // Transmit Overrun Interrupt
    .RXOVRINT          (uart2_rxovrint),    // Receive  Overrun Interrupt
    .UARTINT           (uart2_combined_int) // Combined Interrupt
  );

  // -----------------------------------------------------------------
  // Test slave (for validation purpose)
  generate
  if (TEST_SLAVE_PRESENT) begin : gen_test_slave
  cmsdk_apb_test_slave u_apb_test_slave(
    .PCLK              (PCLKG),    // use Gated PCLK for bus
    .PRESETn           (PRESETn),  // Reset

    .PSEL              (test_slave_psel),     // APB interface inputs
    .PADDR             (i_paddr[11:2]),
    .PENABLE           (i_penable),
    .PSTRB             (i_pstrb[3:0]),
    .PWRITE            (i_pwrite),
    .PWDATA            (i_pwdata),

    .PRDATA            (test_slave_prdata),   // APB interface outputs
    .PREADY            (test_slave_pready),
    .PSLVERR           (test_slave_pslverr)
  );
  end else begin : gen_no_test_slave
  // Test slave absent: APB slot answers zero/ready.
  assign test_slave_prdata  = 32'h00000000;
  assign test_slave_pready  = 1'b1;
  assign test_slave_pslverr = 1'b0;
  wire   _unused_test_slave = &{1'b0, test_slave_psel, i_pstrb};
  end
  endgenerate

  // Connection to external
  assign PADDR   = i_paddr[11:0];
  assign PENABLE = i_penable;
  assign PWRITE  = i_pwrite;
  assign PWDATA  = i_pwdata;

  assign uart0_overflow_int = uart0_txovrint | uart0_rxovrint;
  assign uart1_overflow_int = uart1_txovrint | uart1_rxovrint;
  assign uart2_overflow_int = uart2_txovrint | uart2_rxovrint;

  // If IRQ source are asynchronous to HCLK, then we
  // need to add synchronizers to prevent metastability
  // on interrupt signals.
  cmsdk_irq_sync u_irq_sync_0 (
    .RSTn   (HRESETn),
    .CLK    (HCLK),
    .IRQIN  (uart0_txint),
    .IRQOUT (i_uart0_txint)
  );

  cmsdk_irq_sync u_irq_sync_1 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart0_rxint),
    .IRQOUT(i_uart0_rxint)
  );

  cmsdk_irq_sync u_irq_sync_2 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart1_txint),
    .IRQOUT(i_uart1_txint)
  );

  cmsdk_irq_sync u_irq_sync_3 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart1_rxint),
    .IRQOUT(i_uart1_rxint)
  );

  cmsdk_irq_sync u_irq_sync_4 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart2_txint),
    .IRQOUT(i_uart2_txint)
  );

  cmsdk_irq_sync u_irq_sync_5 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart2_rxint),
    .IRQOUT(i_uart2_rxint)
  );

  cmsdk_irq_sync u_irq_sync_6 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (timer0_int),
    .IRQOUT(i_timer0_int)
  );

  cmsdk_irq_sync u_irq_sync_7 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (timer1_int),
    .IRQOUT(i_timer1_int)
  );

  cmsdk_irq_sync u_irq_sync_8 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (dualtimer2_comb_int),
    .IRQOUT(i_dualtimer2_int)
    );

  cmsdk_irq_sync u_irq_sync_9 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart0_overflow_int),
    .IRQOUT(i_uart0_overflow_int)
  );

  cmsdk_irq_sync u_irq_sync_10 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart1_overflow_int),
    .IRQOUT(i_uart1_overflow_int)
  );

  cmsdk_irq_sync u_irq_sync_11 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (uart2_overflow_int),
    .IRQOUT(i_uart2_overflow_int)
  );

  cmsdk_irq_sync u_irq_sync_12 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (watchdog_int),
    .IRQOUT(i_watchdog_int)
  );

  cmsdk_irq_sync u_irq_sync_13 (
    .RSTn  (HRESETn),
    .CLK   (HCLK),
    .IRQIN (watchdog_rst),
    .IRQOUT(i_watchdog_rst)
  );

  assign apbsubsys_interrupt[31:0] = {
    {16{1'b0}},                       // 16-31 (AHB GPIO #0 individual interrupt)
    1'b0,                             // 15 (DMA interrupt)
    i_uart2_overflow_int,             // 14
    i_uart1_overflow_int,             // 13
    i_uart0_overflow_int,             // 12
    1'b0,                             // 11
    i_dualtimer2_int,                 // 10
    i_timer1_int,                     // 9
    i_timer0_int,                     // 8
    1'b0,                             // 7 (GPIO #1 combined interrupt)
    1'b0,                             // 6 (GPIO #0 combined interrupt)
    i_uart2_txint,                    // 5
    i_uart2_rxint,                    // 4
    i_uart1_txint,                    // 3
    i_uart1_rxint,                    // 2
    i_uart0_txint,                    // 1
    i_uart0_rxint                     // 0
  };

  assign watchdog_interrupt = i_watchdog_int;
  assign watchdog_reset     = i_watchdog_rst;

endmodule
