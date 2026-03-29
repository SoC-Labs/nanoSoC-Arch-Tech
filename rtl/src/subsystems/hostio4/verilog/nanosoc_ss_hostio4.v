//-----------------------------------------------------------------------------
// NanoSoC HOSTIO4 Subsystem
// Encapsulates FT1248/HOSTIO4 stream muxing, hostio4_controller instance,
// and P1[6:0] GPIO pad muxing.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2023, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
module nanosoc_ss_hostio4 (
    // System Clocks and Resets
    input  wire        SYS_HCLK,
    input  wire        SYS_HRESETn,
    input  wire        SYS_TESTMODE,

    // Mode select: high = FT1248/UART2, low = EXTIO (driven by P1_IN[7])
    input  wire        FT1248MODE,

    // ADP stream - to/from debug subsystem
    input  wire        ADP_RXD_TVALID,
    input  wire  [7:0] ADP_RXD_TDATA,
    output wire        ADP_RXD_TREADY,
    output wire        ADP_TXD_TVALID,
    output wire  [7:0] ADP_TXD_TDATA,
    input  wire        ADP_TXD_TREADY,

    // FT1248 ADP stream - to/from FT1248 controller
    output wire        FT_ADP_RXD_TVALID,
    output wire  [7:0] FT_ADP_RXD_TDATA,
    input  wire        FT_ADP_RXD_TREADY,
    input  wire        FT_ADP_TXD_TVALID,
    input  wire  [7:0] FT_ADP_TXD_TDATA,
    output wire        FT_ADP_TXD_TREADY,

    // USRT0 stream - to/from peripheral subsystem
    input  wire        USRT0_TXD_TVALID,
    input  wire  [7:0] USRT0_TXD_TDATA,
    output wire        USRT0_TXD_TREADY,
    output wire        USRT0_RXD_TVALID,
    output wire  [7:0] USRT0_RXD_TDATA,
    input  wire        USRT0_RXD_TREADY,

    // USRT1 stream - to/from peripheral subsystem
    input  wire        USRT1_TXD_TVALID,
    input  wire  [7:0] USRT1_TXD_TDATA,
    output wire        USRT1_TXD_TREADY,
    output wire        USRT1_RXD_TVALID,
    output wire  [7:0] USRT1_RXD_TDATA,
    input  wire        USRT1_RXD_TREADY,

    // EXT DAT DMA trigger outputs (for DMAC_0_DMA_REQ[3:2] in parent)
    output wire        EXT_DAT_RXD_TREADY,
    output wire        EXT_DAT_TXD_TVALID,

    // FT1248 physical signals - from FT1248 controller
    input  wire        FT_CLK_O,
    input  wire        FT_SSN_O,
    input  wire        FT_MIOSIO_O,
    input  wire        FT_MIOSIO_E,
    // FT1248 physical signals - to FT1248 controller
    output wire        FT_MISO_I,
    output wire        FT_MIOSIO_I,

    // P1[6:0] physical GPIO pads
    input  wire  [6:0] P1_IN,
    output wire  [6:0] P1_OUT,
    output wire  [6:0] P1_OUTEN,

    // P1[6:0] GPIO - to system control subsystem
    output wire  [6:0] SYS_P1_IN,
    // P1[6:4] altfunc - from system control subsystem
    input  wire  [6:4] SYS_P1_OUT_MUX,
    input  wire  [6:4] SYS_P1_OUT_EN_MUX
);

    // -------------------------------------------------------------------------
    // Internal AXI stream wires for hostio4_controller
    // -------------------------------------------------------------------------
    wire        EXT_ADP_RXD_TVALID;
    wire  [7:0] EXT_ADP_RXD_TDATA;
    wire        EXT_ADP_RXD_TREADY;
    wire        EXT_ADP_TXD_TVALID;
    wire  [7:0] EXT_ADP_TXD_TDATA;
    wire        EXT_ADP_TXD_TREADY;

    wire        EXT_DAT_RXD_TVALID;
    wire  [7:0] EXT_DAT_RXD_TDATA;
    wire  [7:0] EXT_DAT_TXD_TDATA;
    wire        EXT_DAT_TXD_TREADY;

    // -------------------------------------------------------------------------
    // External I/O physical interface wires
    // -------------------------------------------------------------------------
    wire  [3:0] iodata4_i;
    wire  [3:0] iodata4_o;
    wire  [3:0] iodata4_e;
    wire  [3:0] iodata4_t;
    wire        ioreq1_o;
    wire        ioreq2_o;
    wire        ioack_i;

    // -------------------------------------------------------------------------
    // ADP stream routing - selects between FT1248 and EXTIO paths
    // -------------------------------------------------------------------------

    // ADP input routing (select ready/valid/data from active path)
    assign ADP_RXD_TREADY = (FT1248MODE) ? FT_ADP_RXD_TREADY : EXT_ADP_RXD_TREADY;
    assign ADP_TXD_TVALID = (FT1248MODE) ? FT_ADP_TXD_TVALID : EXT_ADP_TXD_TVALID;
    assign ADP_TXD_TDATA  = (FT1248MODE) ? FT_ADP_TXD_TDATA  : EXT_ADP_TXD_TDATA;

    // FT1248 ADP output routing (gate off when not in FT1248 mode)
    assign FT_ADP_RXD_TVALID = (FT1248MODE) ? ADP_RXD_TVALID : 1'b0;
    assign FT_ADP_RXD_TDATA  = (FT1248MODE) ? ADP_RXD_TDATA  : 8'b00000000;
    assign FT_ADP_TXD_TREADY = (FT1248MODE) ? ADP_TXD_TREADY : 1'b0;

    // EXTIO ADP output routing (gate off when in FT1248 mode)
    assign EXT_ADP_RXD_TVALID = (FT1248MODE) ? 1'b0        : ADP_RXD_TVALID;
    assign EXT_ADP_RXD_TDATA  = (FT1248MODE) ? 8'b00000000 : ADP_RXD_TDATA;
    assign EXT_ADP_TXD_TREADY = (FT1248MODE) ? 1'b0        : ADP_TXD_TREADY;

    // -------------------------------------------------------------------------
    // USRT stream routing - loopback (FT1248 mode) or EXTIO DAT (EXTIO mode)
    // -------------------------------------------------------------------------

    // USRT0 loopback (FT1248 mode) or disable (EXTIO mode)
    assign USRT0_RXD_TVALID = (FT1248MODE) ? USRT1_TXD_TVALID : 1'b0;
    assign USRT0_RXD_TDATA  = (FT1248MODE) ? USRT1_TXD_TDATA  : 8'b00000000;
    assign USRT0_TXD_TREADY = (FT1248MODE) ? USRT1_RXD_TREADY : 1'b0;

    // USRT1 loopback (FT1248 mode) or EXT DAT (EXTIO mode)
    assign USRT1_RXD_TVALID = (FT1248MODE) ? USRT0_TXD_TVALID : EXT_DAT_TXD_TVALID;
    assign USRT1_RXD_TDATA  = (FT1248MODE) ? USRT0_TXD_TDATA  : EXT_DAT_TXD_TDATA;
    assign USRT1_TXD_TREADY = (FT1248MODE) ? USRT0_RXD_TREADY : EXT_DAT_RXD_TREADY;

    // EXT DAT RXD routing (gate off in FT1248 mode)
    assign EXT_DAT_RXD_TVALID = (FT1248MODE) ? 1'b0        : USRT1_TXD_TVALID;
    assign EXT_DAT_RXD_TDATA  = (FT1248MODE) ? 8'b00000000 : USRT1_TXD_TDATA;
    assign EXT_DAT_TXD_TREADY = (FT1248MODE) ? 1'b0        : USRT1_RXD_TREADY;

    // -------------------------------------------------------------------------
    // hostio4_controller instantiation
    // -------------------------------------------------------------------------
    hostio4_controller u_hostio4_controller (
        .clk              (SYS_HCLK),
        .resetn           (SYS_HRESETn),
        .testmode         (SYS_TESTMODE),
        // RX 4-channel AXIS interface (data from system out to external device)
        .axis_rx0_tvalid  (EXT_ADP_RXD_TVALID),
        .axis_rx0_tdata8  (EXT_ADP_RXD_TDATA),
        .axis_rx0_tready  (EXT_ADP_RXD_TREADY),
        .axis_rx1_tvalid  (EXT_DAT_RXD_TVALID),
        .axis_rx1_tdata8  (EXT_DAT_RXD_TDATA),
        .axis_rx1_tready  (EXT_DAT_RXD_TREADY),
        // TX 4-channel AXIS interface (data from external device into system)
        .axis_tx0_tvalid  (EXT_ADP_TXD_TVALID),
        .axis_tx0_tdata8  (EXT_ADP_TXD_TDATA),
        .axis_tx0_tready  (EXT_ADP_TXD_TREADY),
        .axis_tx1_tvalid  (EXT_DAT_TXD_TVALID),
        .axis_tx1_tdata8  (EXT_DAT_TXD_TDATA),
        .axis_tx1_tready  (EXT_DAT_TXD_TREADY),
        // External I/O physical interface
        .iodata4_a        (iodata4_i),
        .iodata4_o        (iodata4_o),
        .iodata4_e        (iodata4_e),
        .iodata4_t        (iodata4_t),
        .ioreq1_o         (ioreq1_o),
        .ioreq2_o         (ioreq2_o),
        .ioack_a          (ioack_i)
    );

    // -------------------------------------------------------------------------
    // P1[6:0] pad muxing: FT1248 vs EXTIO
    //
    //   P1[0] - ft_miso_in    / ioreq1_o
    //   P1[1] - ft_clk_out    / ioreq2_o
    //   P1[2] - ft_miosio_io  / ioack_i
    //   P1[3] - ft_ssn_out    / iodata[0]
    //   P1[4] - uart2_rxd     / iodata[1]
    //   P1[5] - uart2_txd     / iodata[2]
    //   P1[6] - reserved      / iodata[3]
    // -------------------------------------------------------------------------

    // P1[0]: FT_MISO input / IOREQ1 output
    assign FT_MISO_I    = (FT1248MODE) ? P1_IN[0] : 1'b0;
    assign P1_OUTEN[0]  = (FT1248MODE) ? 1'b0     : 1'b1;
    assign P1_OUT[0]    = (FT1248MODE) ? 1'b0     : ioreq1_o;
    assign SYS_P1_IN[0] = (FT1248MODE) ? 1'b0     : ioreq1_o;

    // P1[1]: FT_CLK output / IOREQ2 output
    assign P1_OUT[1]    = (FT1248MODE) ? FT_CLK_O : ioreq2_o;
    assign P1_OUTEN[1]  = 1'b1;
    assign SYS_P1_IN[1] = (FT1248MODE) ? 1'b0     : ioreq2_o;

    // P1[2]: FT_MIOSIO inout / IOACK input
    assign FT_MIOSIO_I  = (FT1248MODE) ? P1_IN[2]    : 1'b0;
    assign P1_OUT[2]    = (FT1248MODE) ? FT_MIOSIO_O : 1'b0;
    assign P1_OUTEN[2]  = (FT1248MODE) ? FT_MIOSIO_E : 1'b0;
    assign SYS_P1_IN[2] = (FT1248MODE) ? 1'b0        : P1_IN[2];
    assign ioack_i      = (FT1248MODE) ? 1'b1         : P1_IN[2];

    // P1[3]: FT_SSN output / IODATA[0]
    assign P1_OUT[3]    = (FT1248MODE) ? FT_SSN_O    : iodata4_o[0];
    assign P1_OUTEN[3]  = (FT1248MODE) ? 1'b1        : iodata4_e[0];
    assign SYS_P1_IN[3] = (FT1248MODE) ? 1'b1        : P1_IN[3];
    assign iodata4_i[0] = (FT1248MODE) ? 1'b1        : P1_IN[3];

    // P1[4]: UART2 RXD / IODATA[1]
    assign P1_OUT[4]    = (FT1248MODE) ? SYS_P1_OUT_MUX[4]    : iodata4_o[1];
    assign P1_OUTEN[4]  = (FT1248MODE) ? SYS_P1_OUT_EN_MUX[4] : iodata4_e[1];
    assign SYS_P1_IN[4] = (FT1248MODE) ? P1_IN[4]             : SYS_P1_OUT_MUX[5];
    assign iodata4_i[1] = (FT1248MODE) ? 1'b1                 : P1_IN[4];

    // P1[5]: UART2 TXD / IODATA[2]
    assign P1_OUT[5]    = (FT1248MODE) ? SYS_P1_OUT_MUX[5]    : iodata4_o[2];
    assign P1_OUTEN[5]  = (FT1248MODE) ? SYS_P1_OUT_EN_MUX[5] : iodata4_e[2];
    assign SYS_P1_IN[5] = P1_IN[5];
    assign iodata4_i[2] = (FT1248MODE) ? 1'b1                 : P1_IN[5];

    // P1[6]: Reserved / IODATA[3]
    assign P1_OUT[6]    = (FT1248MODE) ? SYS_P1_OUT_MUX[6]    : iodata4_o[3];
    assign P1_OUTEN[6]  = (FT1248MODE) ? SYS_P1_OUT_EN_MUX[6] : iodata4_e[3];
    assign SYS_P1_IN[6] = P1_IN[6];
    assign iodata4_i[3] = (FT1248MODE) ? 1'b1                 : P1_IN[6];

endmodule
