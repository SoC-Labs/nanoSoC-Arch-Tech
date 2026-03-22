//-----------------------------------------------------------------------------
// NanoSoC DMA Controller Configuration Region (DMAC_CTRL)
// - Region Mapped to: 0x50000000
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//
// Contains an AHB-to-APB bridge and APB slave demultiplexer for DMA controller
// configuration ports. A generate block controlled by DMAC_0_TYPE determines
// how APB slots are routed to the DMA subsystems:
//
//   DMAC_0_TYPE == 2 (DMA350):
//     Slot 0 -> DMAC_0_PSEL    (DMA350 low config range)
//     Slot 1 -> DMAC_0_PSEL_HI (DMA350 high config range)
//     DMAC_1_PSEL tied low     (DMA350 subsumes dmac_1 controller)
//
//   DMAC_0_TYPE != 2 (PL230 or None):
//     Slot 0 -> DMAC_0_PSEL    (DMAC 0 config)
//     Slot 1 -> DMAC_1_PSEL    (DMAC 1 config)
//     DMAC_0_PSEL_HI tied low
//
// This region should only be connected to the debug controller and CPU
// initiators in the system interconnect. DMA controllers must not have
// access to their own configuration space via this path.
//
//-----------------------------------------------------------------------------

module nanosoc_region_dmac_ctrl #(
    parameter    SYS_ADDR_W    = 32,  // System Address Width
    parameter    SYS_DATA_W    = 32,  // System Data Width
    parameter    APB_ADDR_W    = 12,  // APB Peripheral Address Width
    parameter    APB_DATA_W    = 32,  // APB Peripheral Data Width
    parameter    DMAC_0_TYPE   = 0,   // DMAC 0 Controller Type: 0=None, 1=PL230, 2=DMA350
    parameter    DMAC_1_TYPE   = 0    // DMAC 1 Controller Type: 0=None, 1=PL230
)(
    // AHB interface
    input  wire                   HCLK,
    input  wire                   HRESETn,
    input  wire                   HSEL,
    input  wire  [SYS_ADDR_W-1:0] HADDR,
    input  wire            [ 2:0] HBURST,
    input  wire                   HMASTLOCK,
    input  wire            [ 3:0] HPROT,
    input  wire            [ 2:0] HSIZE,
    input  wire            [ 1:0] HTRANS,
    input  wire  [SYS_DATA_W-1:0] HWDATA,
    input  wire                   HWRITE,
    input  wire                   HREADY,
    output wire  [SYS_DATA_W-1:0] HRDATA,
    output wire                   HRESP,
    output wire                   HREADYOUT,

    // APB clocking control
    input  wire                   PCLK,
    input  wire                   PCLKG,
    input  wire                   PRESETn,
    input  wire                   PCLKEN,

    // Shared APB bus to DMA subsystems
    output wire  [APB_ADDR_W-1:0] DMAC_PADDR,
    output wire                   DMAC_PENABLE,
    output wire                   DMAC_PWRITE,
    output wire  [APB_DATA_W-1:0] DMAC_PWDATA,

    // DMAC 0 APB config port
    output wire                   DMAC_0_PSEL,
    output wire                   DMAC_0_PSEL_HI,
    input  wire  [APB_DATA_W-1:0] DMAC_0_PRDATA,
    input  wire                   DMAC_0_PREADY,
    input  wire                   DMAC_0_PSLVERR,

    // DMAC 1 APB config port
    output wire                   DMAC_1_PSEL,
    input  wire  [APB_DATA_W-1:0] DMAC_1_PRDATA,
    input  wire                   DMAC_1_PREADY,
    input  wire                   DMAC_1_PSLVERR
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

  // APB slave mux to bridge return path
  wire             i_pready_mux;
  wire     [31:0]  i_prdata_mux;
  wire             i_pslverr_mux;

  // Per-slot PSEL outputs from mux
  wire             slot0_psel;
  wire             slot1_psel;

  // Per-slot return signals to mux (directly driven by generate block)
  wire     [31:0]  slot0_prdata;
  wire             slot0_pready;
  wire             slot0_pslverr;

  wire     [31:0]  slot1_prdata;
  wire             slot1_pready;
  wire             slot1_pslverr;

  // --------------------------------------------------------------------------
  // AHB to APB bridge
  // --------------------------------------------------------------------------
  cmsdk_ahb_to_apb #(
    .ADDRWIDTH      (16),
    .REGISTER_RDATA (1),
    .REGISTER_WDATA (0)
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

    .HREADYOUT  (HREADYOUT),
    .HRDATA     (HRDATA),
    .HRESP      (HRESP),

    // APB side
    .PADDR      (i_paddr[15:0]),
    .PSEL       (i_psel),
    .PENABLE    (i_penable),
    .PSTRB      (i_pstrb),
    .PPROT      (i_pprot),
    .PWRITE     (i_pwrite),
    .PWDATA     (i_pwdata),

    .APBACTIVE  (),
    .PCLKEN     (PCLKEN),

    .PRDATA     (i_prdata_mux),
    .PREADY     (i_pready_mux),
    .PSLVERR    (i_pslverr_mux)
  );

  // --------------------------------------------------------------------------
  // APB slave demultiplexer
  // --------------------------------------------------------------------------
  cmsdk_apb_slave_mux #(
    .PORT0_ENABLE  (1),  // DMAC 0 config (or DMA350 low)
    .PORT1_ENABLE  (1),  // DMAC 1 config (or DMA350 high)
    .PORT2_ENABLE  (0),
    .PORT3_ENABLE  (0),
    .PORT4_ENABLE  (0),
    .PORT5_ENABLE  (0),
    .PORT6_ENABLE  (0),
    .PORT7_ENABLE  (0),
    .PORT8_ENABLE  (0),
    .PORT9_ENABLE  (0),
    .PORT10_ENABLE (0),
    .PORT11_ENABLE (0),
    .PORT12_ENABLE (0),
    .PORT13_ENABLE (0),
    .PORT14_ENABLE (0),
    .PORT15_ENABLE (0)
  ) u_apb_slave_mux (
    .DECODE4BIT (i_paddr[15:12]),
    .PSEL       (i_psel),

    // Slot 0: DMAC 0 config (or DMA350 low)
    .PSEL0      (slot0_psel),
    .PREADY0    (slot0_pready),
    .PRDATA0    (slot0_prdata),
    .PSLVERR0   (slot0_pslverr),

    // Slot 1: DMAC 1 config (or DMA350 high)
    .PSEL1      (slot1_psel),
    .PREADY1    (slot1_pready),
    .PRDATA1    (slot1_prdata),
    .PSLVERR1   (slot1_pslverr),

    // Unused ports
    .PSEL2      (),  .PREADY2  (1'b1), .PRDATA2  (32'h0), .PSLVERR2 (1'b0),
    .PSEL3      (),  .PREADY3  (1'b1), .PRDATA3  (32'h0), .PSLVERR3 (1'b0),
    .PSEL4      (),  .PREADY4  (1'b1), .PRDATA4  (32'h0), .PSLVERR4 (1'b0),
    .PSEL5      (),  .PREADY5  (1'b1), .PRDATA5  (32'h0), .PSLVERR5 (1'b0),
    .PSEL6      (),  .PREADY6  (1'b1), .PRDATA6  (32'h0), .PSLVERR6 (1'b0),
    .PSEL7      (),  .PREADY7  (1'b1), .PRDATA7  (32'h0), .PSLVERR7 (1'b0),
    .PSEL8      (),  .PREADY8  (1'b1), .PRDATA8  (32'h0), .PSLVERR8 (1'b0),
    .PSEL9      (),  .PREADY9  (1'b1), .PRDATA9  (32'h0), .PSLVERR9 (1'b0),
    .PSEL10     (),  .PREADY10 (1'b1), .PRDATA10 (32'h0), .PSLVERR10(1'b0),
    .PSEL11     (),  .PREADY11 (1'b1), .PRDATA11 (32'h0), .PSLVERR11(1'b0),
    .PSEL12     (),  .PREADY12 (1'b1), .PRDATA12 (32'h0), .PSLVERR12(1'b0),
    .PSEL13     (),  .PREADY13 (1'b1), .PRDATA13 (32'h0), .PSLVERR13(1'b0),
    .PSEL14     (),  .PREADY14 (1'b1), .PRDATA14 (32'h0), .PSLVERR14(1'b0),
    .PSEL15     (),  .PREADY15 (1'b1), .PRDATA15 (32'h0), .PSLVERR15(1'b0),

    // Muxed output
    .PREADY     (i_pready_mux),
    .PRDATA     (i_prdata_mux),
    .PSLVERR    (i_pslverr_mux)
  );

  // --------------------------------------------------------------------------
  // Shared APB bus output to DMA subsystems
  // --------------------------------------------------------------------------
  assign DMAC_PADDR   = i_paddr[APB_ADDR_W-1:0];
  assign DMAC_PENABLE = i_penable;
  assign DMAC_PWRITE  = i_pwrite;
  assign DMAC_PWDATA  = i_pwdata;

  // --------------------------------------------------------------------------
  // DMA type-dependent APB routing
  //
  // When DMAC_0_TYPE == 2 (DMA350):
  //   The DMA350 requires two APB address ranges (low and high config).
  //   Slot 0 drives DMAC_0_PSEL (low range), slot 1 drives DMAC_0_PSEL_HI
  //   (high range). Both slots return data from the DMA350 (DMAC_0).
  //   DMAC_1 is subsumed by the DMA350 and its PSEL is tied low.
  //
  // When DMAC_0_TYPE != 2 (PL230/None):
  //   Slot 0 drives DMAC_0_PSEL, slot 1 drives DMAC_1_PSEL.
  //   Each controller uses its own return data path.
  //   DMAC_0_PSEL_HI is tied low (not needed for PL230).
  // --------------------------------------------------------------------------
  generate
    if (DMAC_0_TYPE == 2) begin : gen_dma350_apb
      // DMA350: slot 0 = config low, slot 1 = config high
      assign DMAC_0_PSEL    = slot0_psel;
      assign DMAC_0_PSEL_HI = slot1_psel;
      assign DMAC_1_PSEL    = 1'b0;

      // Both slots return data from the DMA350
      assign slot0_prdata   = DMAC_0_PRDATA;
      assign slot0_pready   = DMAC_0_PREADY;
      assign slot0_pslverr  = DMAC_0_PSLVERR;
      assign slot1_prdata   = DMAC_0_PRDATA;
      assign slot1_pready   = DMAC_0_PREADY;
      assign slot1_pslverr  = DMAC_0_PSLVERR;

    end else begin : gen_separate_apb
      // Separate controllers: slot 0 = DMAC_0, slot 1 = DMAC_1
      assign DMAC_0_PSEL    = slot0_psel;
      assign DMAC_0_PSEL_HI = 1'b0;
      assign DMAC_1_PSEL    = slot1_psel;

      assign slot0_prdata   = DMAC_0_PRDATA;
      assign slot0_pready   = DMAC_0_PREADY;
      assign slot0_pslverr  = DMAC_0_PSLVERR;
      assign slot1_prdata   = DMAC_1_PRDATA;
      assign slot1_pready   = DMAC_1_PREADY;
      assign slot1_pslverr  = DMAC_1_PSLVERR;

    end
  endgenerate

endmodule
