//-----------------------------------------------------------------------------
// Nanosoc Bootrom Region
// - Generic, parameterisable boot ROM region
// - Read-only memory containing boot code (no reset port)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2021-6, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module nanosoc_region_bootrom #(
    parameter    SYS_ADDR_W  = 32,  // System Address Width
    parameter    SYS_DATA_W  = 32,  // System Data Width
    parameter    ROM_ADDR_W  = 11   // Size of Bootrom (Based on Address Width) - Default 2KB
)(
    input  wire                   HCLK,       // Clock

    // AHB connection to Initiator
    input  wire                   HSEL,
    input  wire  [SYS_ADDR_W-1:0] HADDR,
    input  wire             [1:0] HTRANS,
    input  wire             [2:0] HSIZE,
    input  wire             [3:0] HPROT,
    input  wire                   HWRITE,
    input  wire                   HREADY,
    input  wire  [SYS_DATA_W-1:0] HWDATA,

    output wire                   HREADYOUT,
    output wire                   HRESP,
    output wire  [SYS_DATA_W-1:0] HRDATA
);

    // Address remapping - extract lower bits for ROM access
    wire [ROM_ADDR_W-1:0] bootrom_addr;
    assign                bootrom_addr = HADDR[ROM_ADDR_W-1:0];

    nanosoc_bootrom_cpu_0 #(
        .SYS_DATA_W     (SYS_DATA_W),
        .BOOTROM_ADDR_W (ROM_ADDR_W)
    ) u_bootrom (
        .HCLK            (HCLK),
        .HSEL            (HSEL),
        .HADDR           (bootrom_addr),
        .HTRANS          (HTRANS),
        .HSIZE           (HSIZE),
        .HWRITE          (HWRITE),
        .HWDATA          (HWDATA),
        .HREADY          (HREADY),
        .HREADYOUT       (HREADYOUT),
        .HRDATA          (HRDATA),
        .HRESP           (HRESP)
    );

endmodule
