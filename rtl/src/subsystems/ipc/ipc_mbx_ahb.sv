//-----------------------------------------------------------------------------
// nanosoc-multicore-system — ipc_mailbox_ahb compatibility wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// The inter-processor-communications-ahb submodule declares its AHB
// wrapper as `ipc_mailbox_ahb` with lowercase `ahbs_*` AHB port names and
// a truncated (APB_ADDR_W-wide) haddr. The nanosoc_gen SoC top emits an
// AHB slave with the standard CMSDK-convention uppercase port set
// (HSEL, HADDR, HTRANS, HWRITE, HSIZE, HBURST, HPROT, HWDATA,
// HMASTLOCK, HREADY, HRDATA, HRESP, HREADYOUT) and a SYS_ADDR_W-wide
// HADDR. This shim adapts naming and address truncation so both sides
// link up without modifying the submodule.
//-----------------------------------------------------------------------------

module ipc_mbx_ahb #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter SLOT_DEPTH = 4,
    parameter [SYS_DATA_W-1:0] PERIPH_ID = 32'hC0DE_0001
)(
    // Clock / Reset
    input  wire                     HCLK,
    input  wire                     HRESETn,

    // AHB Slave — mailbox register access
    input  wire                     HSEL,
    input  wire  [SYS_ADDR_W-1:0]   HADDR,
    input  wire              [1:0]  HTRANS,
    input  wire                     HWRITE,
    input  wire              [2:0]  HSIZE,
    input  wire              [2:0]  HBURST,
    input  wire              [3:0]  HPROT,
    input  wire  [SYS_DATA_W-1:0]   HWDATA,
    input  wire                     HMASTLOCK,
    input  wire                     HREADY,
    output wire  [SYS_DATA_W-1:0]   HRDATA,
    output wire                     HRESP,
    output wire                     HREADYOUT,

    // Per-CPU interrupt outputs
    output wire                     cpu0_irq,
    output wire                     cpu1_irq
);

    ipc_mailbox_ahb #(
        .SYS_DATA_W (SYS_DATA_W),
        .APB_ADDR_W (APB_ADDR_W),
        .SLOT_DEPTH (SLOT_DEPTH),
        .PERIPH_ID  (PERIPH_ID)
    ) u_ipc_mailbox_ahb (
        .hclk           (HCLK),
        .hresetn        (HRESETn),

        .ahbs_hsel      (HSEL),
        .ahbs_hready    (HREADY),
        .ahbs_htrans    (HTRANS),
        .ahbs_hsize     (HSIZE),
        .ahbs_hwrite    (HWRITE),
        .ahbs_haddr     (HADDR[APB_ADDR_W-1:0]),
        .ahbs_hwdata    (HWDATA),
        .ahbs_hreadyout (HREADYOUT),
        .ahbs_hresp     (HRESP),
        .ahbs_hrdata    (HRDATA),

        .cpu0_irq       (cpu0_irq),
        .cpu1_irq       (cpu1_irq)
    );

endmodule
