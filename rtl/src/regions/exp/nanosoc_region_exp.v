//-----------------------------------------------------------------------------
// Nanosoc Expansion Region
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
module nanosoc_region_exp #(
    parameter    SYS_ADDR_W            = 32,  // System Address Width
    parameter    SYS_DATA_W            = 32,  // System Data Width
    parameter    ACCELERATOR_SUBSYSTEM = 0    // Enable Accelerator Subsystem
)(
    input  wire                     HCLK,       // Clock
    input  wire                     HRESETn,    // Reset

    // AHB Subortinate Port
    input  wire                     HSEL,
    input  wire  [SYS_ADDR_W-1:0]   HADDR,
    input  wire             [1:0]   HTRANS,
    input  wire             [2:0]   HSIZE,
    input  wire             [3:0]   HPROT,
    input  wire                     HWRITE,
    input  wire                     HREADY,
    input  wire  [SYS_DATA_W-1:0]   HWDATA,

    output wire                     HREADYOUT,
    output wire                     HRESP,
    output wire  [SYS_DATA_W-1:0]   HRDATA,
    // DMAC Stream interfaces
    input  wire                     EXP_STR_IN_0_TVALID,
    output wire                     EXP_STR_IN_0_TREADY,
    input  wire  [SYS_DATA_W-1:0]   EXP_STR_IN_0_TDATA,
    input  wire             [3:0]   EXP_STR_IN_0_TSTRB,
    input  wire                     EXP_STR_IN_0_TLAST,

    output wire                     EXP_STR_OUT_0_TVALID,
    input  wire                     EXP_STR_OUT_0_TREADY,
    output wire [SYS_DATA_W-1:0]    EXP_STR_OUT_0_TDATA,
    output wire            [3:0]    EXP_STR_OUT_0_TSTRB,
    output wire                     EXP_STR_OUT_0_TLAST,
    input  wire                     EXP_STR_OUT_0_FLUSH,

    input  wire                     EXP_STR_IN_1_TVALID,
    output wire                     EXP_STR_IN_1_TREADY,
    input  wire  [SYS_DATA_W-1:0]   EXP_STR_IN_1_TDATA,
    input  wire             [3:0]   EXP_STR_IN_1_TSTRB,
    input  wire                     EXP_STR_IN_1_TLAST,

    output wire                     EXP_STR_OUT_1_TVALID,
    input  wire                     EXP_STR_OUT_1_TREADY,
    output wire [SYS_DATA_W-1:0]    EXP_STR_OUT_1_TDATA,
    output wire            [3:0]    EXP_STR_OUT_1_TSTRB,
    output wire                     EXP_STR_OUT_1_TLAST,
    input  wire                     EXP_STR_OUT_1_FLUSH,

    input  wire                     EXP_STR_IN_2_TVALID,
    output wire                     EXP_STR_IN_2_TREADY,
    input  wire  [SYS_DATA_W-1:0]   EXP_STR_IN_2_TDATA,
    input  wire             [3:0]   EXP_STR_IN_2_TSTRB,
    input  wire                     EXP_STR_IN_2_TLAST,

    output wire                     EXP_STR_OUT_2_TVALID,
    input  wire                     EXP_STR_OUT_2_TREADY,
    output wire  [SYS_DATA_W-1:0]   EXP_STR_OUT_2_TDATA,
    output wire             [3:0]   EXP_STR_OUT_2_TSTRB,
    output wire                     EXP_STR_OUT_2_TLAST,
    input  wire                     EXP_STR_OUT_2_FLUSH,

    // Interrupt and DMAC Connections
    output wire             [3:0] EXP_IRQ,
    output wire             [1:0] EXP_DRQ,
    input  wire             [1:0] EXP_DLAST
);

  // Effective accelerator select.
  // Two switches reach this point: the ACCELERATOR_SUBSYSTEM parameter (the
  // generated system's config, default 0) and the ACCELERATOR_SUBSYSTEM
  // macro that 'make ... ACCELERATOR=yes' adds (+define+ACCELERATOR_SUBSYSTEM,
  // makefile) and gen_defines.v repeats. The macro used to be read by nothing,
  // so ACCELERATOR=yes built the default slave. Either switch now selects the
  // accelerator; with neither, the default slave is generated exactly as
  // before. The macro is tested for presence: the generated
  // nanosoc_soc_config.vh defines it with the value 0 and is not compiled by
  // any flow; do not add it to a filelist without revisiting this.
`ifdef ACCELERATOR_SUBSYSTEM
  localparam ACCELERATOR_SUBSYSTEM_SEL = 1;
`else
  localparam ACCELERATOR_SUBSYSTEM_SEL = ACCELERATOR_SUBSYSTEM;
`endif

  generate
    if (ACCELERATOR_SUBSYSTEM_SEL) begin : gen_accelerator_subsystem
      // Instantiate Accelerator Subsystem
      accelerator_subsystem #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
      ) u_ss_accelerator (
        .HCLK(HCLK),
        .HRESETn(HRESETn),
        
        .HSEL(HSEL),
        .HADDR(HADDR),
        .HTRANS(HTRANS),
        .HSIZE(HSIZE),
        .HPROT(HPROT),
        .HWRITE(HWRITE),
        .HREADY(HREADY),
        .HWDATA(HWDATA),
        .HREADYOUT(HREADYOUT),
        .HRESP(HRESP),
        .HRDATA(HRDATA),
        
        .EXP_STR_IN_0_TVALID(EXP_STR_IN_0_TVALID),
        .EXP_STR_IN_0_TREADY(EXP_STR_IN_0_TREADY),
        .EXP_STR_IN_0_TDATA(EXP_STR_IN_0_TDATA),
        .EXP_STR_IN_0_TSTRB(EXP_STR_IN_0_TSTRB),
        .EXP_STR_IN_0_TLAST(EXP_STR_IN_0_TLAST),

        .EXP_STR_OUT_0_TVALID(EXP_STR_OUT_0_TVALID),
        .EXP_STR_OUT_0_TREADY(EXP_STR_OUT_0_TREADY),
        .EXP_STR_OUT_0_TDATA(EXP_STR_OUT_0_TDATA),
        .EXP_STR_OUT_0_TSTRB(EXP_STR_OUT_0_TSTRB),
        .EXP_STR_OUT_0_TLAST(EXP_STR_OUT_0_TLAST),
        .EXP_STR_OUT_0_FLUSH(EXP_STR_OUT_0_FLUSH),

        .EXP_STR_IN_1_TVALID(EXP_STR_IN_1_TVALID),
        .EXP_STR_IN_1_TREADY(EXP_STR_IN_1_TREADY),
        .EXP_STR_IN_1_TDATA(EXP_STR_IN_1_TDATA),
        .EXP_STR_IN_1_TSTRB(EXP_STR_IN_1_TSTRB),
        .EXP_STR_IN_1_TLAST(EXP_STR_IN_1_TLAST),

        .EXP_STR_OUT_1_TVALID(EXP_STR_OUT_1_TVALID),
        .EXP_STR_OUT_1_TREADY(EXP_STR_OUT_1_TREADY),
        .EXP_STR_OUT_1_TDATA(EXP_STR_OUT_1_TDATA),
        .EXP_STR_OUT_1_TSTRB(EXP_STR_OUT_1_TSTRB),
        .EXP_STR_OUT_1_TLAST(EXP_STR_OUT_1_TLAST),
        .EXP_STR_OUT_1_FLUSH(EXP_STR_OUT_1_FLUSH),

        .EXP_STR_IN_2_TVALID(EXP_STR_IN_2_TVALID),
        .EXP_STR_IN_2_TREADY(EXP_STR_IN_2_TREADY),
        .EXP_STR_IN_2_TDATA(EXP_STR_IN_2_TDATA),
        .EXP_STR_IN_2_TSTRB(EXP_STR_IN_2_TSTRB),
        .EXP_STR_IN_2_TLAST(EXP_STR_IN_2_TLAST),

        .EXP_STR_OUT_2_TVALID(EXP_STR_OUT_2_TVALID),
        .EXP_STR_OUT_2_TREADY(EXP_STR_OUT_2_TREADY),
        .EXP_STR_OUT_2_TDATA(EXP_STR_OUT_2_TDATA),
        .EXP_STR_OUT_2_TSTRB(EXP_STR_OUT_2_TSTRB),
        .EXP_STR_OUT_2_TLAST(EXP_STR_OUT_2_TLAST),
        .EXP_STR_OUT_2_FLUSH(EXP_STR_OUT_2_FLUSH),

        .EXP_IRQ(EXP_IRQ),
        .EXP_DRQ(EXP_DRQ),
        .EXP_DLAST(EXP_DLAST)
      );
    end else begin : gen_default_slave
      // Default slave - if no expansion region
      cmsdk_ahb_default_slave u_ss_accelerator_default (
        .HCLK         (HCLK),
        .HRESETn      (HRESETn),
        .HSEL         (HSEL),
        .HTRANS       (HTRANS),
        .HREADY       (HREADY),
        .HREADYOUT    (HREADYOUT),
        .HRESP        (HRESP)
      );

      assign   HRDATA              = 32'heaedeaed;
      assign   EXP_IRQ             = 4'd0;
      assign   EXP_DRQ             = 2'd0;
      // Tie off stream outputs (no accelerator to consume/produce data)
      assign   EXP_STR_IN_0_TREADY  = 1'b0;
      assign   EXP_STR_OUT_0_TVALID = 1'b0;
      assign   EXP_STR_OUT_0_TDATA  = {SYS_DATA_W{1'b0}};
      assign   EXP_STR_OUT_0_TSTRB  = 4'd0;
      assign   EXP_STR_OUT_0_TLAST  = 1'b0;
      assign   EXP_STR_IN_1_TREADY  = 1'b0;
      assign   EXP_STR_OUT_1_TVALID = 1'b0;
      assign   EXP_STR_OUT_1_TDATA  = {SYS_DATA_W{1'b0}};
      assign   EXP_STR_OUT_1_TSTRB  = 4'd0;
      assign   EXP_STR_OUT_1_TLAST  = 1'b0;
      assign   EXP_STR_IN_2_TREADY  = 1'b0;
      assign   EXP_STR_OUT_2_TVALID = 1'b0;
      assign   EXP_STR_OUT_2_TDATA  = {SYS_DATA_W{1'b0}};
      assign   EXP_STR_OUT_2_TSTRB  = 4'd0;
      assign   EXP_STR_OUT_2_TLAST  = 1'b0;
    end
  endgenerate

endmodule