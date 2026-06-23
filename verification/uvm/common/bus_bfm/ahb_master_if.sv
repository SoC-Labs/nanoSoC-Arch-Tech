//-----------------------------------------------------------------------------
// ahb_master_if.sv -- AHB-Lite master interface + procedural BFM tasks.
//
// Shared by the UVM environments under uvm/{soc_top,ethmac_integration,
// qspi_boot} to avoid reimplementing the same procedural master in each
// tb_top.sv. The tasks live on the interface so a tb that instantiates
// `ahb_master_if u_ahb(...)` can drive transactions as `u_ahb.ahb_read(...)`,
// `u_ahb.ahb_write(...)`, without threading a virtual handle through a
// UVM component stack. When we need proper sequences / scoreboarding, a
// real UVM agent can wrap this interface without changing the tb.
//
// Driving style (non-obvious, preserves prior bring-up):
//   - Address/control lines are driven with blocking assignment at #1 after
//     the positive clock edge. NBA scheduling would let the slave sample
//     stale values on the same edge.
//   - HREADYOUT is sampled on the data-phase edge (one clock after the
//     address-phase edge), not the address-phase edge. Sampling too early
//     returns data from the *previous* transfer.
//   - Between transactions we park HTRANS=IDLE + HSEL=0; the master
//     never holds the bus.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

interface ahb_master_if #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32
) (
    input logic hclk,
    input logic hresetn
);

    logic              hsel;
    logic [ADDR_W-1:0] haddr;
    logic [1:0]        htrans;
    logic              hwrite;
    logic [2:0]        hsize;
    logic [2:0]        hburst;
    logic [3:0]        hprot;
    logic [DATA_W-1:0] hwdata;
    logic              hmastlock;
    logic              hready;      // master-driven input to slave
    logic [DATA_W-1:0] hrdata;
    logic              hresp;
    logic              hreadyout;

    // Park the bus at IDLE out of reset.
    initial begin
        hsel      = 1'b0;
        haddr     = '0;
        htrans    = 2'b00;
        hwrite    = 1'b0;
        hsize     = 3'b010;
        hburst    = 3'b000;
        hprot     = 4'h0;
        hwdata    = '0;
        hmastlock = 1'b0;
        hready    = 1'b1;
    end

    // ── One-word read ─────────────────────────────────────────────────────
    task automatic ahb_read_word(input logic [ADDR_W-1:0] addr,
                                  output logic [DATA_W-1:0] data);
        @(posedge hclk);
        while (hreadyout !== 1'b1) @(posedge hclk);

        // ADDRESS PHASE
        #1;
        hsel      = 1'b1;
        haddr     = addr;
        htrans    = 2'b10;   // NONSEQ
        hwrite    = 1'b0;
        hsize     = 3'b010;  // word
        hburst    = 3'b000;
        hprot     = 4'b0011;
        hmastlock = 1'b0;

        @(posedge hclk);

        // DATA PHASE
        #1;
        hsel   = 1'b0;
        htrans = 2'b00;      // IDLE — no follow-up transfer

        @(posedge hclk);
        while (hreadyout !== 1'b1) @(posedge hclk);
        data = hrdata;
    endtask

    // ── One-word write ────────────────────────────────────────────────────
    task automatic ahb_write_word(input logic [ADDR_W-1:0] addr,
                                   input logic [DATA_W-1:0] data);
        @(posedge hclk);
        while (hreadyout !== 1'b1) @(posedge hclk);

        // ADDRESS PHASE
        #1;
        hsel      = 1'b1;
        haddr     = addr;
        htrans    = 2'b10;
        hwrite    = 1'b1;
        hsize     = 3'b010;
        hburst    = 3'b000;
        hprot     = 4'b0011;
        hmastlock = 1'b0;

        @(posedge hclk);

        // DATA PHASE — HWDATA is valid with the data-phase edge.
        #1;
        hsel   = 1'b0;
        htrans = 2'b00;
        hwdata = data;

        @(posedge hclk);
        while (hreadyout !== 1'b1) @(posedge hclk);
    endtask

endinterface : ahb_master_if
