//-----------------------------------------------------------------------------
// NanoSoC DMA Wrapper - Contains a single DMA Controller
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// Daniel Newbrook (d.newbrook@soton.ac.uk)
//
// Copyright 2021-6, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module nanosoc_dma_wrapper #(
    parameter    SYS_ADDR_W       = 32,  // System Address Width
    parameter    SYS_DATA_W       = 32,  // System Data Width
    parameter    DMAC_CFG_ADDR_W  = 12,  // DMAC Configuration Port Address Width
    parameter    DMAC_CHANNEL_NUM = 2,   // DMAC Number of DMA Channels
    // Controller type: 0=none, 1=PL230, 2=DMA350 (dual-port, uses secondary AHB master)
    parameter    DMAC_TYPE        = 0
)(
    // System AHB Clocks and Resets
    input  wire                            sys_hclk,
    input  wire                            sys_hresetn,
    input  wire                            sys_pclken,           // APB clock enable

    // Primary AHB Master Port
    output wire          [SYS_ADDR_W-1:0] dmac_haddr,
    output wire                     [1:0] dmac_htrans,
    output wire                           dmac_hwrite,
    output wire                     [2:0] dmac_hsize,
    output wire                     [2:0] dmac_hburst,
    output wire                     [3:0] dmac_hprot,
    output wire          [SYS_DATA_W-1:0] dmac_hwdata,
    output wire                           dmac_hmastlock,
    input  wire          [SYS_DATA_W-1:0] dmac_hrdata,
    input  wire                           dmac_hready,
    input  wire                           dmac_hresp,

    // Secondary AHB Master Port (DMA350 only)
    output wire          [SYS_ADDR_W-1:0] dmac_haddr_1,
    output wire                     [1:0] dmac_htrans_1,
    output wire                           dmac_hwrite_1,
    output wire                     [2:0] dmac_hsize_1,
    output wire                     [2:0] dmac_hburst_1,
    output wire                     [3:0] dmac_hprot_1,
    output wire          [SYS_DATA_W-1:0] dmac_hwdata_1,
    output wire                           dmac_hmastlock_1,
    input  wire          [SYS_DATA_W-1:0] dmac_hrdata_1,
    input  wire                           dmac_hready_1,
    input  wire                           dmac_hresp_1,

    // APB Configuration Port
    input  wire                           dmac_psel,
    input  wire                           dmac_psel_hi,
    input  wire                           dmac_pen,
    input  wire                           dmac_pwrite,
    input  wire   [DMAC_CFG_ADDR_W-1:0]  dmac_paddr,
    input  wire          [SYS_DATA_W-1:0] dmac_pwdata,
    output wire          [SYS_DATA_W-1:0] dmac_prdata,
    output wire                           dmac_pready,
    output wire                           dmac_pslverr,

    // AXI Stream 0 (DMA350 only)
    output wire                           dmac_str_out_0_tvalid,
    input  wire                           dmac_str_out_0_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_0_tdata,
    output wire                     [3:0] dmac_str_out_0_tstrb,
    output wire                           dmac_str_out_0_tlast,
    input  wire                           dmac_str_in_0_tvalid,
    output wire                           dmac_str_in_0_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_0_tdata,
    input  wire                     [3:0] dmac_str_in_0_tstrb,
    input  wire                           dmac_str_in_0_tlast,
    output wire                           dmac_str_in_0_flush,

    // AXI Stream 1 (DMA350 only)
    output wire                           dmac_str_out_1_tvalid,
    input  wire                           dmac_str_out_1_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_1_tdata,
    output wire                     [3:0] dmac_str_out_1_tstrb,
    output wire                           dmac_str_out_1_tlast,
    input  wire                           dmac_str_in_1_tvalid,
    output wire                           dmac_str_in_1_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_1_tdata,
    input  wire                     [3:0] dmac_str_in_1_tstrb,
    input  wire                           dmac_str_in_1_tlast,
    output wire                           dmac_str_in_1_flush,

    // AXI Stream 2 (DMA350 only)
    output wire                           dmac_str_out_2_tvalid,
    input  wire                           dmac_str_out_2_tready,
    output wire          [SYS_DATA_W-1:0] dmac_str_out_2_tdata,
    output wire                     [3:0] dmac_str_out_2_tstrb,
    output wire                           dmac_str_out_2_tlast,
    input  wire                           dmac_str_in_2_tvalid,
    output wire                           dmac_str_in_2_tready,
    input  wire          [SYS_DATA_W-1:0] dmac_str_in_2_tdata,
    input  wire                     [3:0] dmac_str_in_2_tstrb,
    input  wire                           dmac_str_in_2_tlast,
    output wire                           dmac_str_in_2_flush,

    // DMA Request and Status Port
    input  wire   [DMAC_CHANNEL_NUM-1:0] dmac_dma_req,
    output wire   [DMAC_CHANNEL_NUM-1:0] dmac_dma_done,
    output wire                          dmac_dma_err
);

    generate

    // =========================================================================
    // DMAC_TYPE == 2 : DMA350 - dual-port, uses primary and secondary AHB
    // =========================================================================
    if (DMAC_TYPE == 2) begin : gen_dma350

        wire dmac_psel_in;
        assign dmac_psel_in = dmac_psel | dmac_psel_hi;

        sldma350_ahb #(
            .SYS_ADDR_W  (SYS_ADDR_W),
            .SYS_DATA_W  (SYS_DATA_W),
            .CFG_ADDR_W  (13),
            .CHANNEL_NUM (DMAC_CHANNEL_NUM)
        ) u_dmac (
            .HCLK            (sys_hclk),
            .HRESETn         (sys_hresetn),
            // Primary AHB master port
            .HADDR_0         (dmac_haddr),
            .HTRANS_0        (dmac_htrans),
            .HWRITE_0        (dmac_hwrite),
            .HSIZE_0         (dmac_hsize),
            .HBURST_0        (dmac_hburst),
            .HPROT_0         (dmac_hprot),
            .HWDATA_0        (dmac_hwdata),
            .HMASTLOCK_0     (dmac_hmastlock),
            .HRDATA_0        (dmac_hrdata),
            .HREADY_0        (dmac_hready),
            .HRESP_0         (dmac_hresp),
            // Secondary AHB master port
            .HADDR_1         (dmac_haddr_1),
            .HTRANS_1        (dmac_htrans_1),
            .HWRITE_1        (dmac_hwrite_1),
            .HSIZE_1         (dmac_hsize_1),
            .HBURST_1        (dmac_hburst_1),
            .HPROT_1         (dmac_hprot_1),
            .HWDATA_1        (dmac_hwdata_1),
            .HMASTLOCK_1     (dmac_hmastlock_1),
            .HRDATA_1        (dmac_hrdata_1),
            .HREADY_1        (dmac_hready_1),
            .HRESP_1         (dmac_hresp_1),
            // APB configuration
            .PCLKEN          (sys_pclken),
            .PSEL            (dmac_psel_in),
            .PEN             (dmac_pen),
            .PWRITE          (dmac_pwrite),
            .PADDR           ({dmac_psel_hi, dmac_paddr}),
            .PWDATA          (dmac_pwdata),
            .PRDATA          (dmac_prdata),
            .PREADY          (dmac_pready),
            .PSLVERR         (dmac_pslverr),
            // AXI stream 0
            .DMAC_STR_OUT_0_TVALID (dmac_str_out_0_tvalid),
            .DMAC_STR_OUT_0_TREADY (dmac_str_out_0_tready),
            .DMAC_STR_OUT_0_TDATA  (dmac_str_out_0_tdata),
            .DMAC_STR_OUT_0_TSTRB  (dmac_str_out_0_tstrb),
            .DMAC_STR_OUT_0_TLAST  (dmac_str_out_0_tlast),
            .DMAC_STR_IN_0_TVALID  (dmac_str_in_0_tvalid),
            .DMAC_STR_IN_0_TREADY  (dmac_str_in_0_tready),
            .DMAC_STR_IN_0_TDATA   (dmac_str_in_0_tdata),
            .DMAC_STR_IN_0_TSTRB   (dmac_str_in_0_tstrb),
            .DMAC_STR_IN_0_TLAST   (dmac_str_in_0_tlast),
            .DMAC_STR_IN_0_FLUSH   (dmac_str_in_0_flush),
            // AXI stream 1
            .DMAC_STR_OUT_1_TVALID (dmac_str_out_1_tvalid),
            .DMAC_STR_OUT_1_TREADY (dmac_str_out_1_tready),
            .DMAC_STR_OUT_1_TDATA  (dmac_str_out_1_tdata),
            .DMAC_STR_OUT_1_TSTRB  (dmac_str_out_1_tstrb),
            .DMAC_STR_OUT_1_TLAST  (dmac_str_out_1_tlast),
            .DMAC_STR_IN_1_TVALID  (dmac_str_in_1_tvalid),
            .DMAC_STR_IN_1_TREADY  (dmac_str_in_1_tready),
            .DMAC_STR_IN_1_TDATA   (dmac_str_in_1_tdata),
            .DMAC_STR_IN_1_TSTRB   (dmac_str_in_1_tstrb),
            .DMAC_STR_IN_1_TLAST   (dmac_str_in_1_tlast),
            .DMAC_STR_IN_1_FLUSH   (dmac_str_in_1_flush),
            // AXI stream 2
            .DMAC_STR_OUT_2_TVALID (dmac_str_out_2_tvalid),
            .DMAC_STR_OUT_2_TREADY (dmac_str_out_2_tready),
            .DMAC_STR_OUT_2_TDATA  (dmac_str_out_2_tdata),
            .DMAC_STR_OUT_2_TSTRB  (dmac_str_out_2_tstrb),
            .DMAC_STR_OUT_2_TLAST  (dmac_str_out_2_tlast),
            .DMAC_STR_IN_2_TVALID  (dmac_str_in_2_tvalid),
            .DMAC_STR_IN_2_TREADY  (dmac_str_in_2_tready),
            .DMAC_STR_IN_2_TDATA   (dmac_str_in_2_tdata),
            .DMAC_STR_IN_2_TSTRB   (dmac_str_in_2_tstrb),
            .DMAC_STR_IN_2_TLAST   (dmac_str_in_2_tlast),
            .DMAC_STR_IN_2_FLUSH   (dmac_str_in_2_flush),
            // DMA channel control
            .DMA_REQ             (dmac_dma_req),
            .DMA_DONE            (dmac_dma_done),
            .DMA_ERR             (dmac_dma_err)
        );

    // =========================================================================
    // DMAC_TYPE == 1 : PL230
    // =========================================================================
    end else if (DMAC_TYPE == 1) begin : gen_pl230

        sldma230 #(
            .SYS_ADDR_W  (SYS_ADDR_W),
            .SYS_DATA_W  (SYS_DATA_W),
            .CFG_ADDR_W  (DMAC_CFG_ADDR_W),
            .CHANNEL_NUM (DMAC_CHANNEL_NUM)
        ) u_dmac (
            .HCLK      (sys_hclk),
            .HRESETn   (sys_hresetn),
            .HADDR     (dmac_haddr),
            .HTRANS    (dmac_htrans),
            .HWRITE    (dmac_hwrite),
            .HSIZE     (dmac_hsize),
            .HBURST    (dmac_hburst),
            .HPROT     (dmac_hprot),
            .HWDATA    (dmac_hwdata),
            .HMASTLOCK (dmac_hmastlock),
            .HRDATA    (dmac_hrdata),
            .HREADY    (dmac_hready),
            .HRESP     (dmac_hresp),
            .PCLKEN    (sys_pclken),
            .PSEL      (dmac_psel),
            .PEN       (dmac_pen),
            .PWRITE    (dmac_pwrite),
            .PADDR     (dmac_paddr),
            .PWDATA    (dmac_pwdata),
            .PRDATA    (dmac_prdata),
            .DMA_REQ   (dmac_dma_req),
            .DMA_DONE  (dmac_dma_done),
            .DMA_ERR   (dmac_dma_err)
        );
        assign dmac_pready  = 1'b1;
        assign dmac_pslverr = 1'b0;

        // Secondary AHB tie-off
        assign dmac_haddr_1     = {SYS_ADDR_W{1'b0}};
        assign dmac_htrans_1    = 2'b0;
        assign dmac_hwrite_1    = 1'b0;
        assign dmac_hsize_1     = 3'b0;
        assign dmac_hburst_1    = 3'b0;
        assign dmac_hprot_1     = 4'b0;
        assign dmac_hwdata_1    = {SYS_DATA_W{1'b0}};
        assign dmac_hmastlock_1 = 1'b0;

        // AXI stream tie-off
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

    // =========================================================================
    // DMAC_TYPE == 0 : Not instantiated
    // =========================================================================
    end else begin : gen_none

        // Primary AHB tie-off
        assign dmac_haddr     = {SYS_ADDR_W{1'b0}};
        assign dmac_htrans    = 2'b0;
        assign dmac_hwrite    = 1'b0;
        assign dmac_hsize     = 3'b0;
        assign dmac_hburst    = 3'b0;
        assign dmac_hprot     = 4'b0;
        assign dmac_hwdata    = {SYS_DATA_W{1'b0}};
        assign dmac_hmastlock = 1'b0;
        assign dmac_pready    = 1'b1;
        assign dmac_pslverr   = 1'b1;
        assign dmac_prdata    = {SYS_DATA_W{1'b0}};
        assign dmac_dma_done  = {DMAC_CHANNEL_NUM{1'b0}};
        assign dmac_dma_err   = 1'b0;

        // Secondary AHB tie-off
        assign dmac_haddr_1     = {SYS_ADDR_W{1'b0}};
        assign dmac_htrans_1    = 2'b0;
        assign dmac_hwrite_1    = 1'b0;
        assign dmac_hsize_1     = 3'b0;
        assign dmac_hburst_1    = 3'b0;
        assign dmac_hprot_1     = 4'b0;
        assign dmac_hwdata_1    = {SYS_DATA_W{1'b0}};
        assign dmac_hmastlock_1 = 1'b0;

        // AXI stream tie-off
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

    end // generate

    endgenerate

endmodule
