//-----------------------------------------------------------------------------
// NanoSoC Testbench adpated from example Cortex-M0 controller testbench
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Flynn (d.w.flynn@soton.ac.uk)
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
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
// Abstract : Testbench for the Cortex-M0 example system
//-----------------------------------------------------------------------------
//
`timescale 1ns/1ps
`include "gen_defines.v"
import nanosoc_soc_config_pkg::*;

module nanosoc_tb;

  wire        CLK;   // crystal pin 1
  wire        TEST;  // 0 for system usaged
  wire        NRST;    // active low reset
  wire        NRST_early;  // active low reset
  wire        NRST_late;   // active low reset
  wire        NRST_ext;    // active low reset

  wire [15:0] P0;      // Port 0
  wire [15:0] P1;      // Port 1

  wire        VDDIO;
  wire        VSSIO;
  wire        VDD;
  wire        VSS;
  wire        VDDACC;

  //Debug tester signals
  wire        nTRST;
  wire        TDI;
  wire        SWDIOTMS;
  wire        SWCLKTCK;
  wire        TDO;

  wire        PCLK;          // Clock for UART capture device

  wire        debug_test_en1; // UART2 output trace (CMSDK)
  wire        debug_test_en2; // FT1248 output trace (nanosoc V1)
  wire        debug_test_en3; // EXTIO output trace (nanosoc V2)
  wire        debug_test_en; // To enable the debug tester connection to MCU GPIO P0
                             // This signal is controlled by software,
                             // Use "UartPutc((char) 0x1B)" to send ESCAPE code to start
                             // the command, use "UartPutc((char) 0x11)" to send debug test
                             // enable command, use "UartPutc((char) 0x12)" to send debug test
                             // disable command. Refer to tb_uart_capture.v file for detail
  assign debug_test_en = debug_test_en1 | debug_test_en2 | debug_test_en3; // UART2, FT1248 or EXTIO

  //-----------------------------------------
  // System options

`define MEM_INIT 1;
localparam BE=0;
`define ARM_CMSDK_INCLUDE_DEBUG_TESTER 1

`ifdef ADP_FILE
  localparam ADP_FILENAME=`ADP_FILE;
`else
  localparam ADP_FILENAME="adp.cmd";
`endif

localparam DATA_IN_FILENAME="data_in.csv";
localparam DATA_OUT_FILENAME="logs/data_out.csv";

`ifdef SDF_SIM
initial
  $sdf_annotate ( "../../../src/rtl/nanosoc_chip_pads_44pin.sdf"
                 , u_nanosoc_chip_pads
                 ,
                 , "sdf_annotate.log"
                 , "MAXIMUM"
                 );
`endif // SDF_SIM

`ifdef VCD_SIM
initial begin
  $dumpfile("waves.vcd");
  $dumpvars(6,u_nanosoc_chip_pads);
  end
`endif // VCD_SIM

 // --------------------------------------------------------------------------------
 // Cortex-M0/Cortex-M0+ Microcontroller
 // --------------------------------------------------------------------------------

`ifdef SDF_SIM
  nanosoc_chip_pads
   u_nanosoc_chip_pads (
`ifdef POWER_PINS
  .VDDIO      (VDDIO),
  .VSSIO      (VSSIO),
  .VDD        (VDD),
  .VSS        (VSS),
  .VDDACC     (VDDACC),
`endif
  .SE         (1'b0),
  .CLK        (CLK),  // input
  .TEST       (TEST),  // input
  .NRST       (NRST),   // active low reset
  .P0         (P0[7:0]),
  .P1         (P1[7:0]),
  .SWDIO      (SWDIOTMS),
  .SWDCK      (SWCLKTCK)
  );
`else
  nanosoc_chip_pads
   u_nanosoc_chip_pads (
`ifdef POWER_PINS
  .VDDIO      (VDDIO),
  .VSSIO      (VSSIO),
  .VDD        (VDD),
  .VSS        (VSS),
  .VDDACC     (VDDACC),
`endif
  .SE         (1'b0),
  .CLK        (CLK),  // input
  .TEST       (TEST),  // input
  .NRST       (NRST),   // active low reset
  .P0         (P0[15:0]),
  .P1         (P1[15:0]),
  .SWDIO      (SWDIOTMS),
  .SWDCK      (SWCLKTCK)
  );
`endif

 // --------------------------------------------------------------------------------
 // Source for clock and reset
 // --------------------------------------------------------------------------------
 `ifndef COCOTB_SIM
  nanosoc_clkreset u_nanosoc_clkreset(
  .CLK       (CLK),
  .NRST      (NRST),
  .NRST_early(NRST_early),
  .NRST_late (NRST_late),
  .NRST_ext  (NRST_ext )
  );
  `endif

  assign TEST = 1'b0;

 // --------------------------------------------------------------------------------
 // GPIO pullups to suppress X-inputs
 // --------------------------------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : gen_p0_pullup
      pullup(P0[gi]);
    end
    for (gi = 0; gi < 7; gi = gi + 1) begin : gen_p1_pullup_lo
      pullup(P1[gi]);
    end
  endgenerate
  pulldown(P1[ 7]); // EXTIO mode (pullup for FT1248 mode)
  generate
    for (gi = 8; gi < 16; gi = gi + 1) begin : gen_p1_pullup_hi
      pullup(P1[gi]);
    end
  endgenerate

`ifdef FAST_SIM
  parameter FAST_LOAD = 1;
`else
  parameter FAST_LOAD = 0;
`endif

 // --------------------------------------------------------------------------------
 // HOSTIO4 stream interface
 // --------------------------------------------------------------------------------

  wire       axis_rx0_tready;
  wire       axis_rx0_tvalid;
  wire [7:0] axis_rx0_tdata8;
  wire       axis_rx1_tready;
  wire       axis_rx1_tvalid;
  wire [7:0] axis_rx1_tdata8;
  wire       axis_tx0_tready;
  wire       axis_tx0_tvalid;
  wire [7:0] axis_tx0_tdata8;
  wire       axis_tx1_tready;
  wire       axis_tx1_tvalid;
  wire [7:0] axis_tx1_tdata8;
  wire       ioreq1;
  wire       ioreq2;
  wire       ioack;
  wire       FT1248MODE;
  wire       test_done;

  wire end_sim = test_done & !FT1248MODE & !ioreq1 & !ioreq2 & !ioack;
  always @(posedge PCLK)
    if (end_sim) begin
      $stop;
    end

  nanosoc_tb_hostio4 u_nanosoc_tb_hostio4 (
    .CLK             (CLK),
    .NRST            (NRST),
    .TEST            (TEST),
    .P1              (P1[7:0]),
    .FT1248MODE      (FT1248MODE),
    .axis_rx0_tready (axis_rx0_tready),
    .axis_rx0_tvalid (axis_rx0_tvalid),
    .axis_rx0_tdata8 (axis_rx0_tdata8),
    .axis_rx1_tready (axis_rx1_tready),
    .axis_rx1_tvalid (axis_rx1_tvalid),
    .axis_rx1_tdata8 (axis_rx1_tdata8),
    .axis_tx0_tready (axis_tx0_tready),
    .axis_tx0_tvalid (axis_tx0_tvalid),
    .axis_tx0_tdata8 (axis_tx0_tdata8),
    .axis_tx1_tready (axis_tx1_tready),
    .axis_tx1_tvalid (axis_tx1_tvalid),
    .axis_tx1_tdata8 (axis_tx1_tdata8),
    .ioreq1          (ioreq1),
    .ioreq2          (ioreq2),
    .ioack           (ioack)
  );

 // --------------------------------------------------------------------------------
 // ADP stimulus and data I/O
 // --------------------------------------------------------------------------------

`ifndef COCOTB_SIM
  nanosoc_tb_adp_stimulus #(
    .ADP_FILENAME     (ADP_FILENAME),
    .DATA_IN_FILENAME (DATA_IN_FILENAME),
    .DATA_OUT_FILENAME(DATA_OUT_FILENAME),
    .FAST_LOAD        (FAST_LOAD),
    .TAG              ("[ADP]  ")
  ) u_nanosoc_tb_adp_stimulus (
    .CLK             (CLK),
    .NRST            (NRST),
    .axis_rx0_tready (axis_rx0_tready),
    .axis_rx0_tvalid (axis_rx0_tvalid),
    .axis_rx0_tdata8 (axis_rx0_tdata8),
    .axis_tx0_tready (axis_tx0_tready),
    .axis_tx0_tvalid (axis_tx0_tvalid),
    .axis_tx0_tdata8 (axis_tx0_tdata8),
    .axis_rx1_tready (axis_rx1_tready),
    .axis_rx1_tvalid (axis_rx1_tvalid),
    .axis_rx1_tdata8 (axis_rx1_tdata8),
    .axis_tx1_tready (axis_tx1_tready),
    .axis_tx1_tvalid (axis_tx1_tvalid),
    .axis_tx1_tdata8 (axis_tx1_tdata8),
    .test_done       (test_done),
    .debug_test_en   (debug_test_en3)
  );
`endif

 // --------------------------------------------------------------------------------
 // UART output capture with baud rate recovery
 // --------------------------------------------------------------------------------
`ifdef ARM_CMSDK_SLOWSPEED_PCLK
  assign PCLK = u_cmsdk_mcu.u_cmsdk_mcu.PCLK;
`else
  assign PCLK = CLK;
`endif

  nanosoc_tb_uart_baudpll #(
    .BAUDPROGDIV16 (389),
    .LOGFILENAME   ("logs/uart2.log"),
    .TAG           ("[UART] ")
  ) u_nanosoc_tb_uart_baudpll (
    .PCLK          (PCLK),
    .NRST          (NRST),
    .UARTXD_in     (P1[5]),
    .FT1248MODE    (FT1248MODE),
    .debug_test_en (debug_test_en1)
  );

 // --------------------------------------------------------------------------------
 // FT1248 interface
 // --------------------------------------------------------------------------------

  nanosoc_tb_ft1248 #(
    .ADP_FILENAME (ADP_FILENAME),
    .FAST_LOAD    (FAST_LOAD)
  ) u_nanosoc_tb_ft1248 (
    .CLK           (CLK),
    .NRST          (NRST),
    .FT1248MODE    (FT1248MODE),
    .P1_0          (P1[0]),
    .P1_1          (P1[1]),
    .P1_2          (P1[2]),
    .P1_3          (P1[3]),
    .P1_4          (P1[4]),
    .P1_5          (P1[5]),
    .debug_test_en (debug_test_en2)
  );

 // --------------------------------------------------------------------------------
 // Tracking CPU with Tarmac trace support
 // --------------------------------------------------------------------------------

`ifdef CORTEX_M0
`ifdef USE_TARMAC

`define ARM_CM0IK_PATH u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_ss_cpu.u_cpu_0.u_slcorem0_integration.u_cortexm0

  CORTEXM0 #(
    .ACG(1),
    .AHBSLV(0),
    .BE(0),
    .BKPT(4),
    .DBG(1),
    .NUMIRQ(32),
    .RAR(1),
    .SMUL(0),
    .SYST(1),
    .WIC(1),
    .WICLINES(34),
    .WPT(2)
  ) u_cortexm0_track (
    // Outputs
    .HADDR                          ( ),
    .HBURST                         ( ),
    .HMASTLOCK                      ( ),
    .HPROT                          ( ),
    .HSIZE                          ( ),
    .HTRANS                         ( ),
    .HWDATA                         ( ),
    .HWRITE                         ( ),
    .HMASTER                        ( ),
    .SLVRDATA                       ( ),
    .SLVREADY                       ( ),
    .SLVRESP                        ( ),
    .DBGRESTARTED                   ( ),
    .HALTED                         ( ),
    .TXEV                           ( ),
    .LOCKUP                         ( ),
    .SYSRESETREQ                    ( ),
    .CODENSEQ                       ( ),
    .CODEHINTDE                     ( ),
    .SPECHTRANS                     ( ),
    .SLEEPING                       ( ),
    .SLEEPDEEP                      ( ),
    .SLEEPHOLDACKn                  ( ),
    .WICDSACKn                      ( ),
    .WICMASKISR                     ( ),
    .WICMASKNMI                     ( ),
    .WICMASKRXEV                    ( ),
    .WICLOAD                        ( ),
    .WICCLEAR                       ( ),
    // Inputs
    .SCLK                           (`ARM_CM0IK_PATH.SCLK),
    .HCLK                           (`ARM_CM0IK_PATH.HCLK),
    .DCLK                           (`ARM_CM0IK_PATH.DCLK),
    .DBGRESETn                      (`ARM_CM0IK_PATH.DBGRESETn),
    .HRESETn                        (`ARM_CM0IK_PATH.HRESETn),
    .HRDATA                         (`ARM_CM0IK_PATH.HRDATA[31:0]),
    .HREADY                         (`ARM_CM0IK_PATH.HREADY),
    .HRESP                          (`ARM_CM0IK_PATH.HRESP),
    .SLVADDR                        (`ARM_CM0IK_PATH.SLVADDR[31:0]),
    .SLVSIZE                        (`ARM_CM0IK_PATH.SLVSIZE[1:0]),
    .SLVTRANS                       (`ARM_CM0IK_PATH.SLVTRANS[1:0]),
    .SLVWDATA                       (`ARM_CM0IK_PATH.SLVWDATA[31:0]),
    .SLVWRITE                       (`ARM_CM0IK_PATH.SLVWRITE),
    .DBGRESTART                     (`ARM_CM0IK_PATH.DBGRESTART),
    .EDBGRQ                         (`ARM_CM0IK_PATH.EDBGRQ),
    .NMI                            (`ARM_CM0IK_PATH.NMI),
    .IRQ                            (`ARM_CM0IK_PATH.IRQ[31:0]),
    .RXEV                           (`ARM_CM0IK_PATH.RXEV),
    .STCALIB                        (`ARM_CM0IK_PATH.STCALIB[25:0]),
    .STCLKEN                        (`ARM_CM0IK_PATH.STCLKEN),
    .IRQLATENCY                     (`ARM_CM0IK_PATH.IRQLATENCY[7:0]),
    .ECOREVNUM                      (`ARM_CM0IK_PATH.ECOREVNUM[19:0]),
    .SLEEPHOLDREQn                  (`ARM_CM0IK_PATH.SLEEPHOLDREQn),
    .WICDSREQn                      (`ARM_CM0IK_PATH.WICDSREQn),
    .SE                             (`ARM_CM0IK_PATH.SE)
  );

`define ARM_CM0IK_TRACK u_cortexm0_track
  cm0_tarmac #(
    .LOGFILENAME("logs/tarmac0.log")
  ) u_tarmac_track (
    .enable_i      (1'b1),

    .hclk_i        (`ARM_CM0IK_TRACK.HCLK),
    .hready_i      (`ARM_CM0IK_TRACK.HREADY),
    .haddr_i       (`ARM_CM0IK_TRACK.HADDR[31:0]),
    .hprot_i       (`ARM_CM0IK_TRACK.HPROT[3:0]),
    .hsize_i       (`ARM_CM0IK_TRACK.HSIZE[2:0]),
    .hwrite_i      (`ARM_CM0IK_TRACK.HWRITE),
    .htrans_i      (`ARM_CM0IK_TRACK.HTRANS[1:0]),
    .hresetn_i     (`ARM_CM0IK_TRACK.HRESETn),
    .hresp_i       (`ARM_CM0IK_TRACK.HRESP),
    .hrdata_i      (`ARM_CM0IK_TRACK.HRDATA[31:0]),
    .hwdata_i      (`ARM_CM0IK_TRACK.HWDATA[31:0]),
    .lockup_i      (`ARM_CM0IK_TRACK.LOCKUP),
    .halted_i      (`ARM_CM0IK_TRACK.HALTED),
    .codehintde_i  (`ARM_CM0IK_TRACK.CODEHINTDE[2:0]),
    .codenseq_i    (`ARM_CM0IK_TRACK.CODENSEQ),

    .hdf_req_i     (`ARM_CM0IK_TRACK.u_top.u_sys.ctl_hdf_request),
    .int_taken_i   (`ARM_CM0IK_TRACK.u_top.u_sys.dec_int_taken_o),
    .int_return_i  (`ARM_CM0IK_TRACK.u_top.u_sys.dec_int_return_o),
    .int_pend_i    (`ARM_CM0IK_TRACK.u_top.u_sys.nvm_int_pend),
    .pend_num_i    (`ARM_CM0IK_TRACK.u_top.u_sys.nvm_int_pend_num[5:0]),
    .ipsr_i        (`ARM_CM0IK_TRACK.u_top.u_sys.psr_ipsr[5:0]),

    .ex_last_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.ctl_ex_last),
    .iaex_en_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.ctl_iaex_en),
    .reg_waddr_i   (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.ctl_wr_addr[3:0]),
    .reg_write_i   (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.ctl_wr_en),
    .xpsr_en_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.ctl_xpsr_en),
    .fe_addr_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.pfu_fe_addr[30:0]),
    .int_delay_i   (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.pfu_int_delay),
    .special_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.pfu_op_special),
    .opcode_i      (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.pfu_opcode[15:0]),
    .reg_wdata_i   (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.psr_gpr_wdata[31:0]),

    .atomic_i      (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_ctl.atomic),
    .atomic_nxt_i  (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_ctl.atomic_nxt),
    .dabort_i      (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_ctl.data_abort),
    .ex_last_nxt_i (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_ctl.ex_last_nxt),
    .int_preempt_i (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_ctl.int_preempt),

    .psp_sel_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_gpr.psp_sel),
    .xpsr_i        (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_gpr.xpsr[31:0]),

    .iaex_i        (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_pfu.iaex[30:0]),
    .iaex_nxt_i    (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_pfu.iaex_nxt[30:0]),
    .opcode_nxt_i  (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_pfu.ibuf_de_nxt[15:0]),
    .delay_count_i (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_pfu.ibuf_lo[13:6]),
    .tbit_en_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_pfu.tbit_en),

    .cflag_en_i    (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_psr.cflag_ena),
    .ipsr_en_i     (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_psr.ipsr_ena),
    .nzflag_en_i   (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_psr.nzflag_ena),
    .vflag_en_i    (`ARM_CM0IK_TRACK.u_top.u_sys.u_core.u_psr.vflag_ena)
  );

`endif // USE_TARMAC
`endif // CORTEX_M0

 // --------------------------------------------------------------------------------
 // Tracking DMA logging support
 // --------------------------------------------------------------------------------
`ifdef DMAC_0_PL230
`define DMAC_PATH u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_ss_dma.gen_dmac_0.u_dmac.gen_pl230.u_dmac.u_pl230_udma

  pl230_udma u_track_pl230_udma (
    .hclk          (`DMAC_PATH.hclk),
    .hresetn       (`DMAC_PATH.hresetn),
    .dma_req       (`DMAC_PATH.dma_req),
    .dma_sreq      (`DMAC_PATH.dma_sreq),
    .dma_waitonreq (`DMAC_PATH.dma_waitonreq),
    .dma_stall     (`DMAC_PATH.dma_stall),
    .dma_active    ( ),
    .dma_done      ( ),
    .dma_err       ( ),
    .hready        (`DMAC_PATH.hready),
    .hresp         (`DMAC_PATH.hresp),
    .hrdata        (`DMAC_PATH.hrdata),
    .htrans        ( ),
    .hwrite        ( ),
    .haddr         ( ),
    .hsize         ( ),
    .hburst        ( ),
    .hmastlock     ( ),
    .hprot         ( ),
    .hwdata        ( ),
    .pclken        (`DMAC_PATH.pclken),
    .psel          (`DMAC_PATH.psel),
    .pen           (`DMAC_PATH.pen),
    .pwrite        (`DMAC_PATH.pwrite),
    .paddr         (`DMAC_PATH.paddr),
    .pwdata        (`DMAC_PATH.pwdata),
    .prdata        ( )
  );

`define DMAC_TRACK_PATH u_track_pl230_udma

`ifndef COCOTB_SIM
  nanosoc_dma_log_to_file #(.FILENAME("logs/dma230.log"),.NUM_CHNLS(4),.NUM_CHNL_BITS(2),.TIMESTAMP(1))
    u_nanosoc_dma_log_to_file (
    .hclk          (`DMAC_TRACK_PATH.hclk),
    .hresetn       (`DMAC_TRACK_PATH.hresetn),
    .hready        (`DMAC_TRACK_PATH.hready),
    .hresp         (`DMAC_TRACK_PATH.hresp),
    .hrdata        (`DMAC_TRACK_PATH.hrdata),
    .htrans        (`DMAC_TRACK_PATH.htrans),
    .hwrite        (`DMAC_TRACK_PATH.hwrite),
    .haddr         (`DMAC_TRACK_PATH.haddr),
    .hsize         (`DMAC_TRACK_PATH.hsize),
    .hburst        (`DMAC_TRACK_PATH.hburst),
    .hprot         (`DMAC_TRACK_PATH.hprot),
    .hwdata        (`DMAC_TRACK_PATH.hwdata),
    .pclken        (`DMAC_TRACK_PATH.pclken),
    .psel          (`DMAC_TRACK_PATH.psel),
    .pen           (`DMAC_TRACK_PATH.pen),
    .pwrite        (`DMAC_TRACK_PATH.pwrite),
    .paddr         (`DMAC_TRACK_PATH.paddr),
    .pwdata        (`DMAC_TRACK_PATH.pwdata),
    .prdata        (`DMAC_TRACK_PATH.prdata),
    .dma_req       (`DMAC_TRACK_PATH.dma_req),
    .dma_active    (`DMAC_TRACK_PATH.dma_active),
    .dma_done      (`DMAC_TRACK_PATH.dma_done),
    .dma_chnl      (`DMAC_TRACK_PATH.u_pl230_ahb_ctrl.current_chnl),
    .dma_ctrl_state(`DMAC_TRACK_PATH.u_pl230_ahb_ctrl.ctrl_state)
  );
  `endif
`endif

 // --------------------------------------------------------------------------------
 // Tracking Accelerator logging support
 // --------------------------------------------------------------------------------

 `define ACC_PATH u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_region_exp

`ifndef COCOTB_SIM
  nanosoc_accelerator_ss_logger #(
    .FILENAME("logs/acc_exp.log"),
    .TIMESTAMP(1)
  ) u_accelerator_ss_logger (
     .HCLK            (`ACC_PATH.HCLK          ),
     .HRESETn         (`ACC_PATH.HRESETn       ),
     .HSEL_i          (`ACC_PATH.HSEL          ),
     .HADDR_i         (`ACC_PATH.HADDR         ),
     .HTRANS_i        (`ACC_PATH.HTRANS        ),
     .HWRITE_i        (`ACC_PATH.HWRITE        ),
     .HSIZE_i         (`ACC_PATH.HSIZE         ),
     .HPROT_i         (`ACC_PATH.HPROT         ),
     .HWDATA_i        (`ACC_PATH.HWDATA        ),
     .HREADY_i        (`ACC_PATH.HREADY        ),
     .HRDATA_o        (`ACC_PATH.HRDATA        ),
     .HREADYOUT_o     (`ACC_PATH.HREADYOUT     ),
     .HRESP_o         (`ACC_PATH.HRESP         ),
     .exp_drq_ip_o    (`ACC_PATH.EXP_DRQ[0]    ),
     .exp_dlast_ip_i  (`ACC_PATH.EXP_DLAST[0]  ),
     .exp_drq_op_o    (`ACC_PATH.EXP_DRQ[1]    ),
     .exp_dlast_op_i  (`ACC_PATH.EXP_DLAST[1]  ),
     .exp_irq_o       (`ACC_PATH.EXP_IRQ       )
   );
`endif

 // --------------------------------------------------------------------------------
 // Debug tester connection
 // --------------------------------------------------------------------------------
  `ifdef ARM_CMSDK_INCLUDE_DEBUG_TESTER

  nanosoc_tb_debug_tester #(
    .BE(BE)
  ) u_nanosoc_tb_debug_tester (
    .CLK           (CLK),
    .NRST_ext      (NRST_ext),
    .debug_test_en (debug_test_en),
    .P0            (P0[7:0]),
    .nTRST         (nTRST),
    .TDI           (TDI),
    .TDO           (TDO),
    .SWDIOTMS      (SWDIOTMS),
    .SWCLKTCK      (SWCLKTCK)
  );
  `endif

 // --------------------------------------------------------------------------------
 // Misc
 // --------------------------------------------------------------------------------

  // Format for time reporting
  initial    $timeformat(-9, 0, " ns", 0);

  // Preload EXP rams
  localparam awt_sram_0 = ((1<<(14-2))-1);
  localparam awt_sram_1 = ((1<<(14-2))-1);

  reg [7:0] fileimage_l [((1<<14)-1):0];
  reg [7:0] fileimage_h [((1<<14)-1):0];
  integer i,j;

  initial begin
    $readmemh("sram_0.hex", fileimage_l);
    for (i=0;i<awt_sram_0;i=i+1) begin
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_0.u_sram.u_sram.BRAM0[i] = fileimage_l[ 4*i];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_0.u_sram.u_sram.BRAM1[i] = fileimage_l[(4*i)+1];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_0.u_sram.u_sram.BRAM2[i] = fileimage_l[(4*i)+2];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_0.u_sram.u_sram.BRAM3[i] = fileimage_l[(4*i)+3];
    end
    $readmemh("sram_1.hex", fileimage_h);
    for (i=0;i<awt_sram_1;i=i+1) begin
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_1.u_sram.u_sram.BRAM0[i] = fileimage_h[ 4*i];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_1.u_sram.u_sram.BRAM1[i] = fileimage_h[(4*i)+1];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_1.u_sram.u_sram.BRAM2[i] = fileimage_h[(4*i)+2];
      u_nanosoc_chip_pads.u_nanosoc_chip.u_system.u_nanosoc.u_region_sram_1.u_sram.u_sram.BRAM3[i] = fileimage_h[(4*i)+3];
    end
  end

  // Configuration checks
  initial begin
`ifdef CORTEX_M0DESIGNSTART
`ifdef CORTEX_M0
     $display("ERROR (nanosoc_tb.v) in CPU preprocessing directive : Both CORTEX_M0DESIGNSTART and CORTEX_M0 are set. Please use only one.");
     $stop;
`endif
`endif
`ifdef CORTEX_M0DESIGNSTART
`ifdef CORTEX_M0PLUS
     $display("ERROR (nanosoc_tb.v) in CPU preprocessing directive : Both CORTEX_M0DESIGNSTART and CORTEX_M0PLUS are set. Please use only one.");
     $stop;
`endif
`endif
`ifdef CORTEX_M0
`ifdef CORTEX_M0PLUS
     $display("ERROR (nanosoc_tb.v) in CPU preprocessing directive : Both CORTEX_M0 and CORTEX_M0PLUS are set. Please use only one.");
     $stop;
`endif
`endif
`ifdef CORTEX_M0DESIGNSTART
`ifdef CORTEX_M0
`ifdef CORTEX_M0PLUS
     $display("ERROR (nanosoc_tb.v) in CPU preprocessing directive : All of CORTEX_M0DESIGNSTART, CORTEX_M0 and CORTEX_M0PLUS are set. Please use only one.");
     $stop;
`endif
`endif
`endif
`ifdef CORTEX_M0
`else
`ifdef CORTEX_M0PLUS
`else
`ifdef CORTEX_M0DESIGNSTART
`else
     $display("ERROR (nanosoc_tb.v) in CPU preprocessing directive : None of CORTEX_M0DESIGNSTART, CORTEX_M0 and CORTEX_M0PLUS are set. Please select one.");
     $stop;
`endif
`endif
`endif

  end
endmodule
