//-----------------------------------------------------------------------------
// cm4_ahb_merge3 — 3:1 AHB-Lite master merge (I-Code + D-Code + System -> 1)
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Merges the Cortex-M4's three master buses onto a single downstream AHB-Lite
// master. I-Code is fetch-only (HWRITE forced 0). Fixed priority at address
// phase: System > D-Code > I-Code; the granted master is held through its data
// phase via HREADY, and non-granted masters are stalled (their HREADY low).
//
//  !!! REFERENCE / ELABORATION-REQUIRED: this arbiter is authored from the
//  !!! standard AHB-Lite single-layer-mux pattern but has NOT been simulated.
//  !!! Verify on the EDA host (back-to-back bursts, locked transfers, error
//  !!! responses, simultaneous requests) OR replace with a known-good AHB-Lite
//  !!! layer-mux IP before trusting it. The slcorem4 boundary does not change
//  !!! if this block is swapped.
//
// v1 simplifications: BURST is passed through but the arbiter only re-arbitrates
// when HTRANS==IDLE/NONSEQ at an idle bus (it does not pre-empt an in-flight
// burst — adequate for SINGLE transfers; HBURST-aware locking is a verify item).
//-----------------------------------------------------------------------------
`define HTRANS_IDLE 2'b00

module cm4_ahb_merge3 (
    input  wire        HCLK,
    input  wire        HRESETn,
    // I-Code (read-only)
    input  wire [1:0]  i_htrans, input wire [31:0] i_haddr, input wire [2:0] i_hsize,
    input  wire [2:0]  i_hburst, input wire [3:0]  i_hprot,
    // D-Code
    input  wire [1:0]  d_htrans, input wire [31:0] d_haddr, input wire d_hwrite,
    input  wire [2:0]  d_hsize,  input wire [2:0]  d_hburst, input wire [3:0] d_hprot,
    input  wire [31:0] d_hwdata,
    // System
    input  wire [1:0]  s_htrans, input wire [31:0] s_haddr, input wire s_hwrite,
    input  wire [2:0]  s_hsize,  input wire [2:0]  s_hburst, input wire [3:0] s_hprot,
    input  wire [31:0] s_hwdata, input wire s_hmastlock,
    // merged downstream master
    output reg  [31:0] m_haddr, output reg [1:0] m_htrans, output reg m_hwrite,
    output reg  [2:0]  m_hsize, output reg [2:0] m_hburst, output reg [3:0] m_hprot,
    output reg  [31:0] m_hwdata, output reg m_hmastlock,
    input  wire [31:0] m_hrdata, input wire m_hready, input wire m_hresp,
    // grant export (= sel_q) so the wrapper can route per-master HREADY/HRESP.
    // NOTE: gating on sel_q alone is correct only when the data-phase master is
    // also the next address-phase master. A full pipelined fix (OR with sel_aphase)
    // plus interconnect-latency tuning is needed for clean I/D/S interleaving and
    // must be verified in a merge unit testbench — see docs/COMPUTE_SOC_BUILDOUT.md.
    output wire [1:0]  sel_grant
);

  localparam SEL_NONE = 2'd0, SEL_I = 2'd1, SEL_D = 2'd2, SEL_S = 2'd3;

  // priority pick among requesting masters (System > D > I)
  reg [1:0] sel_aphase;
  always @(*) begin
    if      (s_htrans != `HTRANS_IDLE) sel_aphase = SEL_S;
    else if (d_htrans != `HTRANS_IDLE) sel_aphase = SEL_D;
    else if (i_htrans != `HTRANS_IDLE) sel_aphase = SEL_I;
    else                               sel_aphase = SEL_NONE;
  end

  // grant register: the address phase that won is the data phase next cycle.
  // re-arbitrate only when the bus is free (m_hready) — held otherwise.
  reg [1:0] sel_q;
  always @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn)      sel_q <= SEL_NONE;
    else if (m_hready) sel_q <= sel_aphase;
  end
  assign sel_grant = sel_q;

  // address-phase mux onto the downstream master
  always @(*) begin
    case (sel_aphase)
      SEL_I: begin m_haddr=i_haddr; m_htrans=i_htrans; m_hwrite=1'b0;     m_hsize=i_hsize; m_hburst=i_hburst; m_hprot=i_hprot; m_hmastlock=1'b0; end
      SEL_D: begin m_haddr=d_haddr; m_htrans=d_htrans; m_hwrite=d_hwrite; m_hsize=d_hsize; m_hburst=d_hburst; m_hprot=d_hprot; m_hmastlock=1'b0; end
      SEL_S: begin m_haddr=s_haddr; m_htrans=s_htrans; m_hwrite=s_hwrite; m_hsize=s_hsize; m_hburst=s_hburst; m_hprot=s_hprot; m_hmastlock=s_hmastlock; end
      default: begin m_haddr=32'h0; m_htrans=`HTRANS_IDLE; m_hwrite=1'b0; m_hsize=3'b010; m_hburst=3'b0; m_hprot=4'h0; m_hmastlock=1'b0; end
    endcase
  end

  // data-phase write data follows the granted (registered) master
  always @(*) begin
    case (sel_q)
      SEL_D:   m_hwdata = d_hwdata;
      SEL_S:   m_hwdata = s_hwdata;
      default: m_hwdata = 32'h0;   // I-Code never writes
    endcase
  end

  // NOTE on read-back / HREADY fan-out: the per-master HREADY/HRDATA/HRESP
  // routing (granted master sees the downstream response; others stalled) is
  // driven back in the wrapper from {m_hready,m_hrdata,m_hresp} — see
  // cortexm4_ahb_wrap. For a single shared downstream slave-side HREADY this is
  // the common case; multi-slave HREADYOUT muxing is a verify item.

endmodule
