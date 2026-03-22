//-----------------------------------------------------------------------------
// Nanosoc System ROM Table Region (SYSTABLE)
// - Region Mapped to: 0xF0000000-0xF0003FFF
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// David Flynn    (d.w.flynn@soton.ac.uk)
//
// Copyright 2021-3, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module nanosoc_region_systable #(
    parameter SYS_ADDR_W         = 32,
    parameter SYS_DATA_W         = 32,
    parameter SYSTABLE_BASE      = 32'hf000_0000,
    parameter SOCLABS_JEPID      = 7'd0,
    parameter NANOSOC_PARTNUMBER = 12'd0,
    parameter NANOSOC_REVISION   = 4'h3
) (
    input  wire                   HCLK,
    input  wire                   HSEL,
    input  wire  [SYS_ADDR_W-1:0] HADDR,
    input  wire          [ 2:0]   HBURST,
    input  wire                   HMASTLOCK,
    input  wire          [ 3:0]   HPROT,
    input  wire          [ 2:0]   HSIZE,
    input  wire          [ 1:0]   HTRANS,
    input  wire  [SYS_DATA_W-1:0] HWDATA,
    input  wire                   HWRITE,
    input  wire                   HREADY,
    output wire  [SYS_DATA_W-1:0] HRDATA,
    output wire                   HRESP,
    output wire                   HREADYOUT
);

    nanosoc_coresight_systable #(
        .BASE           (SYSTABLE_BASE),
        .JEPID          (SOCLABS_JEPID),
        .PARTNUMBER     (NANOSOC_PARTNUMBER),
        .REVISION       (NANOSOC_REVISION),
        .ENTRY0BASEADDR (32'hE00FF000),
        .ENTRY0PRESENT  (1'b1),
        .ENTRY1BASEADDR (32'hF0200000),
        .ENTRY1PRESENT  (1'b0)
    ) u_system_rom_table (
        .ECOREVNUM  (4'h0),
        .HCLK       (HCLK),
        .HSEL       (HSEL),
        .HADDR      (HADDR),
        .HBURST     (HBURST),
        .HMASTLOCK  (HMASTLOCK),
        .HPROT      (HPROT),
        .HSIZE      (HSIZE),
        .HTRANS     (HTRANS),
        .HWDATA     (HWDATA),
        .HWRITE     (HWRITE),
        .HREADY     (HREADY),
        .HRDATA     (HRDATA),
        .HREADYOUT  (HREADYOUT),
        .HRESP      (HRESP)
    );
endmodule