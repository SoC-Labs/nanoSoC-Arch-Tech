//-----------------------------------------------------------------------------
// apb_master_if.sv -- APB master interface + procedural BFM tasks.
//
// Companion to ahb_master_if.sv. Two-phase transfers: SETUP (psel=1,
// penable=0) drives address + wdata, ACCESS (psel=1, penable=1) waits
// on pready. Drives with blocking assignments at #1 after each posedge;
// samples prdata at the edge where pready is observed high.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

interface apb_master_if #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 32
) (
    input logic pclk,
    input logic presetn
);

    logic [ADDR_W-1:0] paddr;
    logic [2:0]        pprot;
    logic              psel;
    logic              penable;
    logic              pwrite;
    logic [DATA_W-1:0] pwdata;
    logic [3:0]        pstrb;
    logic [DATA_W-1:0] prdata;
    logic              pready;
    logic              pslverr;

    initial begin
        paddr   = '0;
        pprot   = 3'h0;
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
        pwdata  = '0;
        pstrb   = 4'hF;
    end

    task automatic apb_write(input logic [ADDR_W-1:0] addr,
                              input logic [DATA_W-1:0] data);
        @(posedge pclk);
        #1;
        psel    = 1'b1;
        penable = 1'b0;
        pwrite  = 1'b1;
        paddr   = addr;
        pwdata  = data;
        pstrb   = 4'hF;

        @(posedge pclk);
        #1;
        penable = 1'b1;

        do @(posedge pclk); while (pready !== 1'b1);

        #1;
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
    endtask

    task automatic apb_read(input  logic [ADDR_W-1:0] addr,
                             output logic [DATA_W-1:0] data);
        @(posedge pclk);
        #1;
        psel    = 1'b1;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = addr;

        @(posedge pclk);
        #1;
        penable = 1'b1;

        do @(posedge pclk); while (pready !== 1'b1);
        data = prdata;

        #1;
        psel    = 1'b0;
        penable = 1'b0;
    endtask

endinterface : apb_master_if
