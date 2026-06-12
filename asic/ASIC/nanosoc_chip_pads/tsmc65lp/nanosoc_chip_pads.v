//-----------------------------------------------------------------------------
// Top-Level Pad implementation for TSMC65nm
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
// Abstract : Top level for example Cortex-M0/Cortex-M0+ microcontroller
//-----------------------------------------------------------------------------
//

module nanosoc_chip_pads (
  input  wire           SE,
  input  wire           CLK, // input
  input  wire           TEST, // input
  input  wire           NRST,  // active low reset
  inout  wire           SWDIO,
  input  wire           SWDCK,

  inout  wire [3:0]     QSPI_IO,
  output wire           QSPI_SCLK,
  output wire           QSPI_nCS,

  inout  wire [6:0]     HOSTIO4_P1,

  input  wire           RMII_REF_CLK,
  output wire [1:0]     RMII_TXD,
  output wire           RMII_TX_EN,
  input  wire [1:0]     RMII_RXD,
  input  wire           RMII_CRS_DV,
  inout  wire           RMII_MDIO,
  output wire           RMII_MDC
);


//------------------------------------
// internal wires
wire     soc_sys_fclk;
wire     soc_sys_sysresetn;
wire     soc_sys_scanenable;
wire     soc_sys_testmode;
wire     soc_sys_sysresetreq;

// Serial Wire Debug port signals
wire     soc_dap_swclktck;
wire     soc_dap_swditms;
wire     soc_dap_swdo;
wire     soc_dap_swdoen;

// QSPI signals
wire       soc_qspi_sclk;
wire       soc_qspi_csn;
wire [3:0] soc_qspi_io_o;
wire [3:0] soc_qspi_io_i;
wire [3:0] soc_qspi_io_e;

// Host IO signals
wire [6:0] soc_hostio4_p1_in;
wire [6:0] soc_hostio4_p1_out;
wire [6:0] soc_hostio4_p1_outen;

// RMII interface
wire [1:0] soc_rmii_txd;
wire       soc_rmii_tx_en;
wire [1:0] soc_rmii_rxd;
wire       soc_rmii_crs_dv;
wire       soc_rmii_ref_clk;

wire       soc_md_pad_i;
wire       soc_mdc_pad_o;
wire       soc_md_pad_o;
wire       soc_md_padoe_o;


wire tielo = 1'b0;
wire tiehi = 1'b1;

nanosoc_multicore_soc u_nanosoc_multicore_soc (
    .sys_fclk(soc_sys_fclk),
    .sys_sysresetn(soc_sys_sysresetn),
    .sys_poresetn(),
    .sys_hclk(),
    .sys_hresetn(),
    .sys_scanenable(soc_sys_scanenable),
    .sys_testmode(soc_sys_testmode),
    .sys_sysresetreq(1'b0),

    .eth_ss_0_haddr(32'd0),
    .eth_ss_0_htrans(2'b00),
    .eth_ss_0_hwrite(1'b0),
    .eth_ss_0_hsize(3'd0),
    .eth_ss_0_hburst(3'd0),
    .eth_ss_0_hprot(4'd0),
    .eth_ss_0_hwdata(32'd0),
    .eth_ss_0_hmastlock(1'b0),
    .eth_ss_0_hrdata(),
    .eth_ss_0_hready(),
    .eth_ss_0_hresp(),

    .cpu_0_pmuenable(1'b0),
    .cpu_1_pmuenable(1'b0),
    .cpu_0_nmi(1'b0),
    .cpu_0_txev(),
    .cpu_0_rxev(1'b0),
    .cpu_0_lockup(),
    .cpu_0_sysresetreq(),
    .cpu_0_sleeping(),
    .cpu_0_sleepdeep(),
  
    .cpu_1_nmi(1'b0),
    .cpu_1_txev(),
    .cpu_1_rxev(1'b0),
    .cpu_1_lockup(),
    .cpu_1_sysresetreq(),
    .cpu_1_sleeping(),
    .cpu_1_sleepdeep(),

    .dap_swclktck(soc_dap_swclktck),
    .dap_swditms(soc_dap_swditms),
    .dap_swdo(soc_dap_swdo),
    .dap_swdoen(soc_dap_swdoen),
    .dap_tdi(1'b0),
    .dap_tdo(),
    .dap_ntdoen(),
    .dap_ntrst(soc_sys_sysresetn),
    .dap_npotrst(soc_sys_sysresetn),
    .dap_swj_enable(1'b1),

    .rmii_ref_clk(soc_rmii_ref_clk),
    .rmii_txd(soc_rmii_txd),
    .rmii_tx_en(soc_rmii_tx_en),
    .rmii_rxd(soc_rmii_rxd),
    .rmii_crs_dv(soc_rmii_crs_dv),

    .md_pad_i(soc_md_pad_i),
    .mdc_pad_o(soc_mdc_pad_o),
    .md_pad_o(soc_md_pad_o),
    .md_padoe_o(soc_md_padoe_o),

    .uart_rxd(),
    .uart_txd(),

    .cpu1_uart_rxd(),
    .cpu1_uart_txd(),
    .cpu1_wdog_reset(),

    .rtc_clk(),
    .rtc_time_ptp_ns(),
    .rtc_time_ptp_sec(),
    .rtc_time_one_pps(),

    .eth_irq(),
    .phc_pps_out(),
    .phc_pps_irq(),
    .phc_alarm_irq(),

    .qspi_sclk(soc_qspi_sclk),
    .qspi_csn(soc_qspi_csn),
    .qspi_io_o(soc_qspi_io_o),
    .qspi_io_i(soc_qspi_io_i),
    .qspi_io_e(soc_qspi_io_e),

    .hostio4_p1_in(soc_hostio4_p1_in),
    .hostio4_p1_out(soc_hostio4_p1_out),
    .hostio4_p1_outen(soc_hostio4_p1_outen)
);

 // --------------------------------------------------------------------------------
 // IO pad (TSMC 65nm specific Library napping)
 // --------------------------------------------------------------------------------

// Power Pads
// Top
PVDD2POC_G uPAD_VDDIO_T_0();
PVDD2DGZ_G uPAD_VDDIO_T_1();
PVDD2DGZ_G uPAD_VDDIO_T_2();
PVSS2DGZ_G uPAD_VSSIO_T_0();
PVSS2DGZ_G uPAD_VSSIO_T_1();
PVSS2DGZ_G uPAD_VSSIO_T_2();
PVDD1DGZ_G uPAD_VDD_T_0();
PVDD1DGZ_G uPAD_VDD_T_1();
PVDD1DGZ_G uPAD_VDD_T_2();
PVSS1DGZ_G uPAD_VSS_T_0();
PVSS1DGZ_G uPAD_VSS_T_1();

// Bottom
PVDD2POC_G uPAD_VDDIO_B_0();
PVDD2DGZ_G uPAD_VDDIO_B_1();
PVDD2DGZ_G uPAD_VDDIO_B_2();
PVSS2DGZ_G uPAD_VSSIO_B_0();
PVSS2DGZ_G uPAD_VSSIO_B_1();
PVSS2DGZ_G uPAD_VSSIO_B_2();
PVDD1DGZ_G uPAD_VDD_B_0();
PVDD1DGZ_G uPAD_VDD_B_1();
PVDD1DGZ_G uPAD_VDD_B_2();
PVSS1DGZ_G uPAD_VSS_B_0();
PVSS1DGZ_G uPAD_VSS_B_1();

// Left
PVDD2POC_G uPAD_VDDIO_L_0();
PVDD2DGZ_G uPAD_VDDIO_L_1();
PVDD2DGZ_G uPAD_VDDIO_L_2();
PVSS2DGZ_G uPAD_VSSIO_L_0();
PVSS2DGZ_G uPAD_VSSIO_L_1();
PVSS2DGZ_G uPAD_VSSIO_L_2();

// Right
PVDD2POC_G uPAD_VDDIO_R_0();
PVDD2DGZ_G uPAD_VDDIO_R_1();
PVDD2DGZ_G uPAD_VDDIO_R_2();
PVSS2DGZ_G uPAD_VSSIO_R_0();
PVSS2DGZ_G uPAD_VSSIO_R_1();
PVSS2DGZ_G uPAD_VSSIO_R_2();


// Clock, Reset and Serial Wire Debug ports

PDDW04DGZ_G  uPAD_SE_I (
    .C(soc_sys_scanenable),
    .REN(tielo),
    .I(tielo),
    .OEN(tiehi),
    .PAD(SE)
   );

PDDW04DGZ_G  uPAD_CLK_I (
    .C(soc_sys_fclk),
    .REN(tiehi),
    .I(tielo),
    .OEN(tiehi),
    .PAD(CLK)
   );

PDDW04DGZ_G  uPAD_TEST_I (
    .C(soc_sys_testmode),
    .REN(tielo),
    .I(tielo),
    .OEN(tiehi),
    .PAD(TEST)
   );

PDDW04DGZ_G  uPAD_NRST_I (
    .C(soc_sys_sysresetn),
    .REN(tiehi),
    .I(tielo),
    .OEN(tiehi),
    .PAD(NRST)
   );

PDUW08DGZ_G  uPAD_SWDIO_IO (
    .C(soc_dap_swditms),
    .REN(tielo),
    .I(soc_dap_swdo),
    .OEN(~soc_dap_swdoen),
    .PAD(SWDIO)
   );

PDDW04DGZ_G  uPAD_SWDCK_I (
    .C(soc_dap_swclktck),
    .REN(tielo),
    .I(tielo),
    .OEN(tiehi),
    .PAD(SWDCK)
   );

// QSPI Pads
PDDW16DGZ_G uPAD_QSPI_SCLK (
  .C(),
  .REN(tiehi),
  .I(soc_qspi_sclk),
  .OEN(tielo),
  .PAD(QSPI_SCLK)
);
PDDW16DGZ_G uPAD_QSPI_nCS (
  .C(),
  .REN(tiehi),
  .I(soc_qspi_csn),
  .OEN(tielo),
  .PAD(QSPI_nCS)
);
PDDW16DGZ_G uPAD_QSPI_IO_0(
  .C(soc_qspi_io_i[0]),
  .REN(tiehi),
  .I(soc_qspi_io_o[0]),
  .OEN(~soc_qspi_io_e[0]),
  .PAD(QSPI_IO[0])
);
PDDW16DGZ_G uPAD_QSPI_IO_1(
  .C(soc_qspi_io_i[1]),
  .REN(tiehi),
  .I(soc_qspi_io_o[1]),
  .OEN(~soc_qspi_io_e[1]),
  .PAD(QSPI_IO[1])
);
PDDW16DGZ_G uPAD_QSPI_IO_2(
  .C(soc_qspi_io_i[2]),
  .REN(tiehi),
  .I(soc_qspi_io_o[2]),
  .OEN(~soc_qspi_io_e[2]),
  .PAD(QSPI_IO[2])
);
PDDW16DGZ_G uPAD_QSPI_IO_3(
  .C(soc_qspi_io_i[3]),
  .REN(tiehi),
  .I(soc_qspi_io_o[3]),
  .OEN(~soc_qspi_io_e[3]),
  .PAD(QSPI_IO[3])
);

PDDW16DGZ_G uPAD_HOST_IO_0(
  .C(soc_hostio4_p1_in[0]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[0]),
  .OEN(~soc_hostio4_p1_outen[0]),
  .PAD(HOSTIO4_P1[0])
);

PDDW16DGZ_G uPAD_HOST_IO_1(
  .C(soc_hostio4_p1_in[1]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[1]),
  .OEN(~soc_hostio4_p1_outen[1]),
  .PAD(HOSTIO4_P1[1])
);

PDDW16DGZ_G uPAD_HOST_IO_2(
  .C(soc_hostio4_p1_in[2]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[2]),
  .OEN(~soc_hostio4_p1_outen[2]),
  .PAD(HOSTIO4_P1[2])
);

PDDW16DGZ_G uPAD_HOST_IO_3(
  .C(soc_hostio4_p1_in[3]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[3]),
  .OEN(~soc_hostio4_p1_outen[3]),
  .PAD(HOSTIO4_P1[3])
);

PDDW16DGZ_G uPAD_HOST_IO_4(
  .C(soc_hostio4_p1_in[4]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[4]),
  .OEN(~soc_hostio4_p1_outen[4]),
  .PAD(HOSTIO4_P1[4])
);

PDDW16DGZ_G uPAD_HOST_IO_5(
  .C(soc_hostio4_p1_in[5]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[5]),
  .OEN(~soc_hostio4_p1_outen[5]),
  .PAD(HOSTIO4_P1[5])
);

PDDW16DGZ_G uPAD_HOST_IO_6(
  .C(soc_hostio4_p1_in[6]),
  .REN(tiehi),
  .I(soc_hostio4_p1_out[6]),
  .OEN(~soc_hostio4_p1_outen[6]),
  .PAD(HOSTIO4_P1[6])
);

PDDW04DGZ_G uPAD_RMII_REF_CLK(
  .C(soc_rmii_ref_clk),
  .REN(tiehi),
  .I(tielo),
  .OEN(tiehi),
  .PAD(RMII_REF_CLK)
);

PDDW16DGZ_G uPAD_RMII_TXD0(
  .C(),
  .REN(tiehi),
  .I(soc_rmii_txd[0]),
  .OEN(tielo),
  .PAD(RMII_TXD[0])
);

PDDW16DGZ_G uPAD_RMII_TXD1(
  .C(),
  .REN(tiehi),
  .I(soc_rmii_txd[1]),
  .OEN(tielo),
  .PAD(RMII_TXD[1])
);

PDDW16DGZ_G uPAD_RMII_TX_EN(
  .C(),
  .REN(tiehi),
  .I(soc_rmii_tx_en),
  .OEN(tielo),
  .PAD(RMII_TX_EN)
);

PDDW04DGZ_G uPAD_RMII_RXD0(
  .C(soc_rmii_rxd[0]),
  .REN(tielo),
  .I(tielo),
  .OEN(tiehi),
  .PAD(RMII_RXD[0])
);

PDDW04DGZ_G uPAD_RMII_RXD1(
  .C(soc_rmii_rxd[1]),
  .REN(tielo),
  .I(tielo),
  .OEN(tiehi),
  .PAD(RMII_RXD[1])
);

PDDW04DGZ_G uPAD_RMII_CRS_DV(
  .C(soc_rmii_crs_dv),
  .REN(tielo),
  .I(tielo),
  .OEN(tiehi),
  .PAD(RMII_CRS_DV)
);

PDD16DGZ_G uPAD_RMII_MDIO(
  .C(soc_md_pad_i),
  .REN(tiehi),
  .I(soc_md_pad_o),
  .OEN(~soc_md_padoe_o),
  .PAD(RMII_MDIO)
);

PDD16DGZ_G uPAD_RMII_MDC(
  .C(),
  .REN(tiehi),
  .I(soc_mdc_pad_o),
  .OEN(tielo),
  .PAD(RMII_MDC)
);

endmodule
