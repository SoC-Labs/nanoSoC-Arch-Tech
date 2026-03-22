//-----------------------------------------------------------------------------
// NanoSoC DMA Subsystem
// - Contains the DMAC_CTRL region (AHB-to-APB bridge + APB demux for DMA
//   controller configuration) and conditionally-generated DMA controller
//   instances (nanosoc_dma_wrapper).
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//
// Generate structure:
//   DMAC_0_TYPE > 0  => instantiate nanosoc_dma_wrapper as gen_dmac_0.u_dmac
//   DMAC_0_TYPE == 2 => DMA350 mode: secondary AHB port drives DMAC_1 bus,
//                       DMAC_1 APB slot used for DMA350 high config range
//   DMAC_1_TYPE > 0
//     && DMAC_0_TYPE != 2 => instantiate nanosoc_dma_wrapper as gen_dmac_1.u_dmac
//
// The DMAC_CTRL region handles APB routing internally based on DMAC_0_TYPE.
//
//-----------------------------------------------------------------------------

module nanosoc_ss_dma #(
    parameter    SYS_ADDR_W         = 32,
    parameter    SYS_DATA_W         = 32,
    parameter    APB_ADDR_W         = 12,
    parameter    APB_DATA_W         = 32,
    parameter    DMAC_0_TYPE        = 0,   // 0=None, 1=PL230, 2=DMA350
    parameter    DMAC_1_TYPE        = 0,   // 0=None, 1=PL230
    parameter    DMAC_0_CHANNEL_NUM = 4,
    parameter    DMAC_1_CHANNEL_NUM = 2
)(
    // System Clocks and Resets
    input  wire                            sys_hclk,
    input  wire                            sys_hresetn,
    input  wire                            sys_pclk,
    input  wire                            sys_pclkg,
    input  wire                            sys_presetn,
    input  wire                            sys_pclken,

    // -----------------------------------------------------------------------
    // DMAC 0 AHB Master Port — to system interconnect
    // -----------------------------------------------------------------------
    output wire          [SYS_ADDR_W-1:0] dmac_0_haddr,
    output wire                     [1:0] dmac_0_htrans,
    output wire                           dmac_0_hwrite,
    output wire                     [2:0] dmac_0_hsize,
    output wire                     [2:0] dmac_0_hburst,
    output wire                     [3:0] dmac_0_hprot,
    output wire          [SYS_DATA_W-1:0] dmac_0_hwdata,
    output wire                           dmac_0_hmastlock,
    input  wire          [SYS_DATA_W-1:0] dmac_0_hrdata,
    input  wire                           dmac_0_hready,
    input  wire                           dmac_0_hresp,

    // -----------------------------------------------------------------------
    // DMAC 1 AHB Master Port — to system interconnect
    // -----------------------------------------------------------------------
    output wire          [SYS_ADDR_W-1:0] dmac_1_haddr,
    output wire                     [1:0] dmac_1_htrans,
    output wire                           dmac_1_hwrite,
    output wire                     [2:0] dmac_1_hsize,
    output wire                     [2:0] dmac_1_hburst,
    output wire                     [3:0] dmac_1_hprot,
    output wire          [SYS_DATA_W-1:0] dmac_1_hwdata,
    output wire                           dmac_1_hmastlock,
    input  wire          [SYS_DATA_W-1:0] dmac_1_hrdata,
    input  wire                           dmac_1_hready,
    input  wire                           dmac_1_hresp,

    // -----------------------------------------------------------------------
    // DMAC_CTRL AHB Slave Port — from system interconnect
    // -----------------------------------------------------------------------
    input  wire                           dmac_ctrl_hsel,
    input  wire          [SYS_ADDR_W-1:0] dmac_ctrl_haddr,
    input  wire                     [2:0] dmac_ctrl_hburst,
    input  wire                           dmac_ctrl_hmastlock,
    input  wire                     [3:0] dmac_ctrl_hprot,
    input  wire                     [2:0] dmac_ctrl_hsize,
    input  wire                     [1:0] dmac_ctrl_htrans,
    input  wire          [SYS_DATA_W-1:0] dmac_ctrl_hwdata,
    input  wire                           dmac_ctrl_hwrite,
    input  wire                           dmac_ctrl_hready,
    output wire          [SYS_DATA_W-1:0] dmac_ctrl_hrdata,
    output wire                           dmac_ctrl_hresp,
    output wire                           dmac_ctrl_hreadyout,

    // -----------------------------------------------------------------------
    // DMA Streams 0-2 — to/from expansion subsystem (DMA350 only)
    // -----------------------------------------------------------------------
    // Stream 0: DMAC -> Expansion
    output wire                           dmac_str_out_0_tvalid,
    input  wire                           dmac_str_out_0_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_0_tdata,
    output wire                     [3:0] dmac_str_out_0_tstrb,
    output wire                           dmac_str_out_0_tlast,
    // Stream 0: Expansion -> DMAC
    input  wire                           dmac_str_in_0_tvalid,
    output wire                           dmac_str_in_0_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_0_tdata,
    input  wire                     [3:0] dmac_str_in_0_tstrb,
    input  wire                           dmac_str_in_0_tlast,
    output wire                           dmac_str_in_0_flush,

    // Stream 1: DMAC -> Expansion
    output wire                           dmac_str_out_1_tvalid,
    input  wire                           dmac_str_out_1_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_1_tdata,
    output wire                     [3:0] dmac_str_out_1_tstrb,
    output wire                           dmac_str_out_1_tlast,
    // Stream 1: Expansion -> DMAC
    input  wire                           dmac_str_in_1_tvalid,
    output wire                           dmac_str_in_1_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_1_tdata,
    input  wire                     [3:0] dmac_str_in_1_tstrb,
    input  wire                           dmac_str_in_1_tlast,
    output wire                           dmac_str_in_1_flush,

    // Stream 2: DMAC -> Expansion
    output wire                           dmac_str_out_2_tvalid,
    input  wire                           dmac_str_out_2_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_2_tdata,
    output wire                     [3:0] dmac_str_out_2_tstrb,
    output wire                           dmac_str_out_2_tlast,
    // Stream 2: Expansion -> DMAC
    input  wire                           dmac_str_in_2_tvalid,
    output wire                           dmac_str_in_2_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_2_tdata,
    input  wire                     [3:0] dmac_str_in_2_tstrb,
    input  wire                           dmac_str_in_2_tlast,
    output wire                           dmac_str_in_2_flush,

    // -----------------------------------------------------------------------
    // DMA Request/Status — to/from expansion subsystem
    // -----------------------------------------------------------------------
    input  wire   [DMAC_0_CHANNEL_NUM-1:0] dmac_0_dma_req,
    output wire   [DMAC_0_CHANNEL_NUM-1:0] dmac_0_dma_done,
    output wire                            dmac_0_dma_err,

    input  wire   [DMAC_1_CHANNEL_NUM-1:0] dmac_1_dma_req,
    output wire   [DMAC_1_CHANNEL_NUM-1:0] dmac_1_dma_done,
    output wire                            dmac_1_dma_err,

    // -----------------------------------------------------------------------
    // Combined DMA status — to CPU subsystem
    // -----------------------------------------------------------------------
    output wire                            dmac_any_done,
    output wire                            dmac_any_error
);

    // ========================================================================
    // Internal wiring — DMAC_CTRL region APB bus
    // ========================================================================
    wire  [APB_ADDR_W-1:0] i_dmac_ctrl_paddr;
    wire                   i_dmac_ctrl_penable;
    wire                   i_dmac_ctrl_pwrite;
    wire  [APB_DATA_W-1:0] i_dmac_ctrl_pwdata;

    // DMAC 0 APB config port (from dmac_ctrl to dma_wrapper_0)
    wire                   i_dmac_0_psel;
    wire                   i_dmac_0_psel_hi;
    wire  [APB_DATA_W-1:0] i_dmac_0_prdata;
    wire                   i_dmac_0_pready;
    wire                   i_dmac_0_pslverr;

    // DMAC 1 APB config port (from dmac_ctrl to dma_wrapper_1)
    wire                   i_dmac_1_psel;
    wire  [APB_DATA_W-1:0] i_dmac_1_prdata;
    wire                   i_dmac_1_pready;
    wire                   i_dmac_1_pslverr;

    // ========================================================================
    // Internal wiring — DMA350 secondary AHB port (used when DMAC_0_TYPE==2)
    // ========================================================================
    wire  [SYS_ADDR_W-1:0] i_dmac_0_sec_haddr;
    wire             [1:0] i_dmac_0_sec_htrans;
    wire                   i_dmac_0_sec_hwrite;
    wire             [2:0] i_dmac_0_sec_hsize;
    wire             [2:0] i_dmac_0_sec_hburst;
    wire             [3:0] i_dmac_0_sec_hprot;
    wire  [SYS_DATA_W-1:0] i_dmac_0_sec_hwdata;
    wire                   i_dmac_0_sec_hmastlock;

    // ========================================================================
    // Internal wiring — dma_wrapper_1 primary AHB port (used when DMAC_0_TYPE!=2)
    // ========================================================================
    wire  [SYS_ADDR_W-1:0] i_dmac_1_pri_haddr;
    wire             [1:0] i_dmac_1_pri_htrans;
    wire                   i_dmac_1_pri_hwrite;
    wire             [2:0] i_dmac_1_pri_hsize;
    wire             [2:0] i_dmac_1_pri_hburst;
    wire             [3:0] i_dmac_1_pri_hprot;
    wire  [SYS_DATA_W-1:0] i_dmac_1_pri_hwdata;
    wire                   i_dmac_1_pri_hmastlock;

    // ========================================================================
    // DMAC_CTRL Region — AHB-to-APB bridge + APB demux
    // ========================================================================
    nanosoc_region_dmac_ctrl #(
        .SYS_ADDR_W   (SYS_ADDR_W),
        .SYS_DATA_W   (SYS_DATA_W),
        .APB_ADDR_W   (APB_ADDR_W),
        .APB_DATA_W   (APB_DATA_W),
        .DMAC_0_TYPE  (DMAC_0_TYPE),
        .DMAC_1_TYPE  (DMAC_1_TYPE)
    ) u_region_dmac_ctrl (
        .HCLK         (sys_hclk),
        .HRESETn      (sys_hresetn),
        .HSEL         (dmac_ctrl_hsel),
        .HADDR        (dmac_ctrl_haddr),
        .HBURST       (dmac_ctrl_hburst),
        .HMASTLOCK    (dmac_ctrl_hmastlock),
        .HPROT        (dmac_ctrl_hprot),
        .HSIZE        (dmac_ctrl_hsize),
        .HTRANS       (dmac_ctrl_htrans),
        .HWDATA       (dmac_ctrl_hwdata),
        .HWRITE       (dmac_ctrl_hwrite),
        .HREADY       (dmac_ctrl_hready),
        .HRDATA       (dmac_ctrl_hrdata),
        .HRESP        (dmac_ctrl_hresp),
        .HREADYOUT    (dmac_ctrl_hreadyout),
        .PCLK         (sys_pclk),
        .PCLKG        (sys_pclkg),
        .PRESETn      (sys_presetn),
        .PCLKEN       (sys_pclken),
        .DMAC_PADDR   (i_dmac_ctrl_paddr),
        .DMAC_PENABLE (i_dmac_ctrl_penable),
        .DMAC_PWRITE  (i_dmac_ctrl_pwrite),
        .DMAC_PWDATA  (i_dmac_ctrl_pwdata),
        .DMAC_0_PSEL    (i_dmac_0_psel),
        .DMAC_0_PSEL_HI (i_dmac_0_psel_hi),
        .DMAC_0_PRDATA  (i_dmac_0_prdata),
        .DMAC_0_PREADY  (i_dmac_0_pready),
        .DMAC_0_PSLVERR (i_dmac_0_pslverr),
        .DMAC_1_PSEL    (i_dmac_1_psel),
        .DMAC_1_PRDATA  (i_dmac_1_prdata),
        .DMAC_1_PREADY  (i_dmac_1_pready),
        .DMAC_1_PSLVERR (i_dmac_1_pslverr)
    );

    // ========================================================================
    // DMAC 0 — conditional generation
    // ========================================================================
    generate
        if (DMAC_0_TYPE > 0) begin : gen_dmac_0

            nanosoc_dma_wrapper #(
                .SYS_ADDR_W      (SYS_ADDR_W),
                .SYS_DATA_W      (SYS_DATA_W),
                .DMAC_CFG_ADDR_W (APB_ADDR_W),
                .DMAC_CHANNEL_NUM(DMAC_0_CHANNEL_NUM),
                .DMAC_TYPE       (DMAC_0_TYPE)
            ) u_dmac (
                .sys_hclk    (sys_hclk),
                .sys_hresetn (sys_hresetn),
                .sys_pclken  (sys_pclken),
                .dmac_haddr    (dmac_0_haddr),
                .dmac_htrans   (dmac_0_htrans),
                .dmac_hwrite   (dmac_0_hwrite),
                .dmac_hsize    (dmac_0_hsize),
                .dmac_hburst   (dmac_0_hburst),
                .dmac_hprot    (dmac_0_hprot),
                .dmac_hwdata   (dmac_0_hwdata),
                .dmac_hmastlock(dmac_0_hmastlock),
                .dmac_hrdata   (dmac_0_hrdata),
                .dmac_hready   (dmac_0_hready),
                .dmac_hresp    (dmac_0_hresp),
                .dmac_haddr_1    (i_dmac_0_sec_haddr),
                .dmac_htrans_1   (i_dmac_0_sec_htrans),
                .dmac_hwrite_1   (i_dmac_0_sec_hwrite),
                .dmac_hsize_1    (i_dmac_0_sec_hsize),
                .dmac_hburst_1   (i_dmac_0_sec_hburst),
                .dmac_hprot_1    (i_dmac_0_sec_hprot),
                .dmac_hwdata_1   (i_dmac_0_sec_hwdata),
                .dmac_hmastlock_1(i_dmac_0_sec_hmastlock),
                .dmac_hrdata_1   (dmac_1_hrdata),
                .dmac_hready_1   (dmac_1_hready),
                .dmac_hresp_1    (dmac_1_hresp),
                .dmac_psel    (i_dmac_0_psel),
                .dmac_psel_hi (i_dmac_0_psel_hi),
                .dmac_pen     (i_dmac_ctrl_penable),
                .dmac_pwrite  (i_dmac_ctrl_pwrite),
                .dmac_paddr   (i_dmac_ctrl_paddr),
                .dmac_pwdata  (i_dmac_ctrl_pwdata),
                .dmac_prdata  (i_dmac_0_prdata),
                .dmac_pready  (i_dmac_0_pready),
                .dmac_pslverr (i_dmac_0_pslverr),
                .dmac_str_out_0_tvalid(dmac_str_out_0_tvalid),
                .dmac_str_out_0_tready(dmac_str_out_0_tready),
                .dmac_str_out_0_tdata (dmac_str_out_0_tdata),
                .dmac_str_out_0_tstrb (dmac_str_out_0_tstrb),
                .dmac_str_out_0_tlast (dmac_str_out_0_tlast),
                .dmac_str_in_0_tvalid (dmac_str_in_0_tvalid),
                .dmac_str_in_0_tready (dmac_str_in_0_tready),
                .dmac_str_in_0_tdata  (dmac_str_in_0_tdata),
                .dmac_str_in_0_tstrb  (dmac_str_in_0_tstrb),
                .dmac_str_in_0_tlast  (dmac_str_in_0_tlast),
                .dmac_str_in_0_flush  (dmac_str_in_0_flush),
                .dmac_str_out_1_tvalid(dmac_str_out_1_tvalid),
                .dmac_str_out_1_tready(dmac_str_out_1_tready),
                .dmac_str_out_1_tdata (dmac_str_out_1_tdata),
                .dmac_str_out_1_tstrb (dmac_str_out_1_tstrb),
                .dmac_str_out_1_tlast (dmac_str_out_1_tlast),
                .dmac_str_in_1_tvalid (dmac_str_in_1_tvalid),
                .dmac_str_in_1_tready (dmac_str_in_1_tready),
                .dmac_str_in_1_tdata  (dmac_str_in_1_tdata),
                .dmac_str_in_1_tstrb  (dmac_str_in_1_tstrb),
                .dmac_str_in_1_tlast  (dmac_str_in_1_tlast),
                .dmac_str_in_1_flush  (dmac_str_in_1_flush),
                .dmac_str_out_2_tvalid(dmac_str_out_2_tvalid),
                .dmac_str_out_2_tready(dmac_str_out_2_tready),
                .dmac_str_out_2_tdata (dmac_str_out_2_tdata),
                .dmac_str_out_2_tstrb (dmac_str_out_2_tstrb),
                .dmac_str_out_2_tlast (dmac_str_out_2_tlast),
                .dmac_str_in_2_tvalid (dmac_str_in_2_tvalid),
                .dmac_str_in_2_tready (dmac_str_in_2_tready),
                .dmac_str_in_2_tdata  (dmac_str_in_2_tdata),
                .dmac_str_in_2_tstrb  (dmac_str_in_2_tstrb),
                .dmac_str_in_2_tlast  (dmac_str_in_2_tlast),
                .dmac_str_in_2_flush  (dmac_str_in_2_flush),
                .dmac_dma_req  (dmac_0_dma_req),
                .dmac_dma_done (dmac_0_dma_done),
                .dmac_dma_err  (dmac_0_dma_err)
            );

        end else begin : gen_no_dmac_0
            assign dmac_0_haddr     = {SYS_ADDR_W{1'b0}};
            assign dmac_0_htrans    = 2'b0;
            assign dmac_0_hwrite    = 1'b0;
            assign dmac_0_hsize     = 3'b0;
            assign dmac_0_hburst    = 3'b0;
            assign dmac_0_hprot     = 4'b0;
            assign dmac_0_hwdata    = {SYS_DATA_W{1'b0}};
            assign dmac_0_hmastlock = 1'b0;
            assign i_dmac_0_sec_haddr     = {SYS_ADDR_W{1'b0}};
            assign i_dmac_0_sec_htrans    = 2'b0;
            assign i_dmac_0_sec_hwrite    = 1'b0;
            assign i_dmac_0_sec_hsize     = 3'b0;
            assign i_dmac_0_sec_hburst    = 3'b0;
            assign i_dmac_0_sec_hprot     = 4'b0;
            assign i_dmac_0_sec_hwdata    = {SYS_DATA_W{1'b0}};
            assign i_dmac_0_sec_hmastlock = 1'b0;
            assign i_dmac_0_prdata  = {APB_DATA_W{1'b0}};
            assign i_dmac_0_pready  = 1'b1;
            assign i_dmac_0_pslverr = 1'b1;
            assign dmac_0_dma_done = {DMAC_0_CHANNEL_NUM{1'b0}};
            assign dmac_0_dma_err  = 1'b0;
            assign dmac_str_out_0_tvalid = 1'b0;
            assign dmac_str_out_0_tdata  = {SYS_DATA_W{1'b0}};
            assign dmac_str_out_0_tstrb  = 4'b0;
            assign dmac_str_out_0_tlast  = 1'b0;
            assign dmac_str_in_0_tready  = 1'b0;
            assign dmac_str_in_0_flush   = 1'b0;
            assign dmac_str_out_1_tvalid = 1'b0;
            assign dmac_str_out_1_tdata  = {SYS_DATA_W{1'b0}};
            assign dmac_str_out_1_tstrb  = 4'b0;
            assign dmac_str_out_1_tlast  = 1'b0;
            assign dmac_str_in_1_tready  = 1'b0;
            assign dmac_str_in_1_flush   = 1'b0;
            assign dmac_str_out_2_tvalid = 1'b0;
            assign dmac_str_out_2_tdata  = {SYS_DATA_W{1'b0}};
            assign dmac_str_out_2_tstrb  = 4'b0;
            assign dmac_str_out_2_tlast  = 1'b0;
            assign dmac_str_in_2_tready  = 1'b0;
            assign dmac_str_in_2_flush   = 1'b0;
        end
    endgenerate

    // ========================================================================
    // DMAC 1 AHB bus routing
    // ========================================================================
    generate
        if (DMAC_0_TYPE == 2) begin : gen_dmac_1_from_dma350
            assign dmac_1_haddr     = i_dmac_0_sec_haddr;
            assign dmac_1_htrans    = i_dmac_0_sec_htrans;
            assign dmac_1_hwrite    = i_dmac_0_sec_hwrite;
            assign dmac_1_hsize     = i_dmac_0_sec_hsize;
            assign dmac_1_hburst    = i_dmac_0_sec_hburst;
            assign dmac_1_hprot     = i_dmac_0_sec_hprot;
            assign dmac_1_hwdata    = i_dmac_0_sec_hwdata;
            assign dmac_1_hmastlock = i_dmac_0_sec_hmastlock;
            assign i_dmac_1_prdata  = {APB_DATA_W{1'b0}};
            assign i_dmac_1_pready  = 1'b1;
            assign i_dmac_1_pslverr = 1'b1;
            assign dmac_1_dma_done = {DMAC_1_CHANNEL_NUM{1'b0}};
            assign dmac_1_dma_err  = 1'b0;

        end else if (DMAC_1_TYPE > 0) begin : gen_dmac_1

            nanosoc_dma_wrapper #(
                .SYS_ADDR_W      (SYS_ADDR_W),
                .SYS_DATA_W      (SYS_DATA_W),
                .DMAC_CFG_ADDR_W (APB_ADDR_W),
                .DMAC_CHANNEL_NUM(DMAC_1_CHANNEL_NUM),
                .DMAC_TYPE       (DMAC_1_TYPE)
            ) u_dmac (
                .sys_hclk    (sys_hclk),
                .sys_hresetn (sys_hresetn),
                .sys_pclken  (sys_pclken),
                .dmac_haddr    (i_dmac_1_pri_haddr),
                .dmac_htrans   (i_dmac_1_pri_htrans),
                .dmac_hwrite   (i_dmac_1_pri_hwrite),
                .dmac_hsize    (i_dmac_1_pri_hsize),
                .dmac_hburst   (i_dmac_1_pri_hburst),
                .dmac_hprot    (i_dmac_1_pri_hprot),
                .dmac_hwdata   (i_dmac_1_pri_hwdata),
                .dmac_hmastlock(i_dmac_1_pri_hmastlock),
                .dmac_hrdata   (dmac_1_hrdata),
                .dmac_hready   (dmac_1_hready),
                .dmac_hresp    (dmac_1_hresp),
                .dmac_haddr_1    (),
                .dmac_htrans_1   (),
                .dmac_hwrite_1   (),
                .dmac_hsize_1    (),
                .dmac_hburst_1   (),
                .dmac_hprot_1    (),
                .dmac_hwdata_1   (),
                .dmac_hmastlock_1(),
                .dmac_hrdata_1   ({SYS_DATA_W{1'b0}}),
                .dmac_hready_1   (1'b1),
                .dmac_hresp_1    (1'b0),
                .dmac_psel    (i_dmac_1_psel),
                .dmac_psel_hi (1'b0),
                .dmac_pen     (i_dmac_ctrl_penable),
                .dmac_pwrite  (i_dmac_ctrl_pwrite),
                .dmac_paddr   (i_dmac_ctrl_paddr),
                .dmac_pwdata  (i_dmac_ctrl_pwdata),
                .dmac_prdata  (i_dmac_1_prdata),
                .dmac_pready  (i_dmac_1_pready),
                .dmac_pslverr (i_dmac_1_pslverr),
                .dmac_str_out_0_tvalid(),  .dmac_str_out_0_tready(1'b0),
                .dmac_str_out_0_tdata (), .dmac_str_out_0_tstrb (), .dmac_str_out_0_tlast (),
                .dmac_str_in_0_tvalid (1'b0), .dmac_str_in_0_tready (),
                .dmac_str_in_0_tdata  ({SYS_DATA_W{1'b0}}), .dmac_str_in_0_tstrb  (4'b0),
                .dmac_str_in_0_tlast  (1'b0), .dmac_str_in_0_flush  (),
                .dmac_str_out_1_tvalid(), .dmac_str_out_1_tready(1'b0),
                .dmac_str_out_1_tdata (), .dmac_str_out_1_tstrb (), .dmac_str_out_1_tlast (),
                .dmac_str_in_1_tvalid (1'b0), .dmac_str_in_1_tready (),
                .dmac_str_in_1_tdata  ({SYS_DATA_W{1'b0}}), .dmac_str_in_1_tstrb  (4'b0),
                .dmac_str_in_1_tlast  (1'b0), .dmac_str_in_1_flush  (),
                .dmac_str_out_2_tvalid(), .dmac_str_out_2_tready(1'b0),
                .dmac_str_out_2_tdata (), .dmac_str_out_2_tstrb (), .dmac_str_out_2_tlast (),
                .dmac_str_in_2_tvalid (1'b0), .dmac_str_in_2_tready (),
                .dmac_str_in_2_tdata  ({SYS_DATA_W{1'b0}}), .dmac_str_in_2_tstrb  (4'b0),
                .dmac_str_in_2_tlast  (1'b0), .dmac_str_in_2_flush  (),
                .dmac_dma_req  (dmac_1_dma_req),
                .dmac_dma_done (dmac_1_dma_done),
                .dmac_dma_err  (dmac_1_dma_err)
            );
            assign dmac_1_haddr     = i_dmac_1_pri_haddr;
            assign dmac_1_htrans    = i_dmac_1_pri_htrans;
            assign dmac_1_hwrite    = i_dmac_1_pri_hwrite;
            assign dmac_1_hsize     = i_dmac_1_pri_hsize;
            assign dmac_1_hburst    = i_dmac_1_pri_hburst;
            assign dmac_1_hprot     = i_dmac_1_pri_hprot;
            assign dmac_1_hwdata    = i_dmac_1_pri_hwdata;
            assign dmac_1_hmastlock = i_dmac_1_pri_hmastlock;

        end else begin : gen_no_dmac_1
            assign dmac_1_haddr     = {SYS_ADDR_W{1'b0}};
            assign dmac_1_htrans    = 2'b0;
            assign dmac_1_hwrite    = 1'b0;
            assign dmac_1_hsize     = 3'b0;
            assign dmac_1_hburst    = 3'b0;
            assign dmac_1_hprot     = 4'b0;
            assign dmac_1_hwdata    = {SYS_DATA_W{1'b0}};
            assign dmac_1_hmastlock = 1'b0;
            assign i_dmac_1_prdata  = {APB_DATA_W{1'b0}};
            assign i_dmac_1_pready  = 1'b1;
            assign i_dmac_1_pslverr = 1'b1;
            assign dmac_1_dma_done = {DMAC_1_CHANNEL_NUM{1'b0}};
            assign dmac_1_dma_err  = 1'b0;
        end
    endgenerate

    // ========================================================================
    // Combined DMA status
    // ========================================================================
    assign dmac_any_done  = (|dmac_0_dma_done) | (|dmac_1_dma_done);
    assign dmac_any_error = dmac_0_dma_err | dmac_1_dma_err;

endmodule
