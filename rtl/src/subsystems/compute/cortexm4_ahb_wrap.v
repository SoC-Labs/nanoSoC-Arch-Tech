//-----------------------------------------------------------------------------
// SoC Labs Cortex-M4 AHB-Lite Wrapper (slcorem4)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// v2 — re-integrated at the CORTEXM4 level so the core's OWN AHB-AP can be
// attached to the system CoreSight SoC-400 DP.
//
// WHY THIS IS NOT CORTEXM4INTEGRATION ANY MORE
// --------------------------------------------
// CORTEXM4INTEGRATION hardcodes its own `DAPSWJDP` (upstream :1174) onto the
// core's DAP bus, so the only debug ingress it offers is a dedicated 2-wire SWD
// port. CORTEXM4 itself exposes that DAP bus as ports
// (DAPSEL/DAPENABLE/DAPWRITE/DAPABORT/DAPADDR/DAPWDATA ->
// DAPREADY/DAPSLVERR/DAPRDATA, upstream CORTEXM4.v:125-159, :261-263) — a
// standard CoreSight AP-slave interface, signal-for-signal what `cxdapahbap`
// presents to `cxdapswjdp`. Attaching it to a spare APSEL on the system DP
// therefore gives bus-side access to the M4's PPB (DHCSR, DWT, FPB, NVIC) with
// NO new IP, NO new pads and NO Arm source edits.
//
// The M4 has no AHB/APB debug SLAVE port, so the DBGAHB_SLV* scheme copied from
// the Cortex-M0+ (which really does expose SLV*, CORTEXM0PLUS.v:145-154) can
// never work here. Those ports are GONE; do not re-add them.
//
// This mirrors `slcorem0p`'s EXTERNAL_DAP parameter one hierarchy level deeper:
//   EXTERNAL_DAP = 1 (default) — no internal DP; the DAP_* ports are the core's
//                                AP, driven by the SoC-400 DP at a spare APSEL.
//   EXTERNAL_DAP = 0           — instantiate DAPSWJDP and expose SWD/JTAG pins,
//                                i.e. the pre-v2 topology, as a bring-up fallback.
//
// WHAT WAS DROPPED FROM THE INTEGRATION LEVEL, AND WHY
// ----------------------------------------------------
//  - DAPSWJDP            : replaced by the external DP (EXTERNAL_DAP=1).
//  - nTRST synchroniser  : clocked by SWCLKTCK and consumed ONLY by DAPSWJDP.
//                          Removing it removes the SWCLKTCK clock domain from
//                          this block entirely when EXTERNAL_DAP=1.
//  - cm4_wic             : WIC_PRESENT=0 makes every cm4_wic output a constant
//                          (upstream cm4_wic.v:94-99). Replaced by those
//                          constants.
//  - 4x cm4_clk_gate     : CLKGATE_PRESENT=0 makes all four pass-throughs
//                          (upstream :1069-1075). Replaced by direct assigns.
//  - cm4_tpiu            : the die ties TRACECLKIN low, so the upstream
//                          TRACECLKIN-domain reset synchroniser never clocks and
//                          t_reset_n is stuck asserted — the TPIU is already
//                          held in permanent reset on silicon. SWV, TRACECLK and
//                          TRACEDATA are unbonded, so no trace can leave the die
//                          regardless. Its PPB reads return 0 (see g_no_tpiu).
//  - CM4ETM              : ARM_CM4_ETM_LICENSE is not defined in this delivery.
//  - GATEHCLK / ISOLATEn / RETAINn / CGBYPASS / RSTBYPASS:
//                          RETAINn is declared and never used upstream; the
//                          other three were tied to constants by the v1 wrapper,
//                          and with the clock gates gone they had no remaining
//                          consumer except GATEHCLK, which was left open.
//  - ARM_TestBench block : TBENCHINPUTS/TBENCHOUTPUTS, the PPB TrickBox and the
//                          testbench DAP override. Never compiled in this flow.
//  - DAP bus slave mux   : upstream :1424-1443 decodes APSEL in DAPADDR[31:24]
//                          and null-responds otherwise. `nanosoc_dap_ss` already
//                          does exactly that at the DP, so it is redundant here.
//
// KEPT, deliberately: both FCLK reset synchronisers, the 256-HCLK cold-start
// release (a real 2026-06-29 bring-up fix, see below), the two cm4_sync CDC
// cells on the debug power-up / DBGEN inputs, and cm4_rom_table (a debugger
// walks it to discover SCS/DWT/FPB — without it the target looks empty).
//
//  !!! ELABORATION/SIM STATUS: authored against the CORTEXM4 and
//  !!! CORTEXM4INTEGRATION boundaries read from the read-only IP. NOT yet
//  !!! elaborated or simulated. Bring-up order: (1) elaborate, (2) cocotb read
//  !!! of DHCSR/CPUID through the DAP port, (3) full SoC.
//-----------------------------------------------------------------------------
`include "cm4_lic_defs.v"   // from $CM4_IP_DIR/cm4_lic_defs (read-only IP)

module slcorem4 #(
    parameter FPU_PRESENT     = 1,
    parameter MPU_PRESENT     = 1,
    parameter NUM_IRQ         = 64,
    parameter LVL_WIDTH       = 4,
    // Trace level passed through to CORTEXM4 unchanged. The TPIU is not
    // instantiated at any setting (see header); TRACE_LVL>0 still keeps the ITM
    // and the DWT trace path inside the core. TRACE_LVL=0 removes those too and
    // is a further area saving — the DWT comparators and register file are gated
    // by DEBUG_LVL, not TRACE_LVL (cm4_dwt.v:51-54, :215, :585-586), so
    // watchpoints survive it. Left at 1 here so v2 changes debug ingress ONLY.
    parameter TRACE_LVL       = 1,
    parameter DEBUG_LVL       = 3,
    parameter BB_PRESENT      = 1,
    parameter RESET_ALL_REGS  = 0,
    parameter BE              = 0,
    // 1 = core AP attaches to the system SoC-400 DP via the DAP_* ports.
    // 0 = instantiate DAPSWJDP and use the SWD/JTAG pins (pre-v2 fallback).
    parameter EXTERNAL_DAP    = 1
) (
    // Clock / reset INPUTS (consumer)
    input  wire        SYS_FCLK,
    input  wire        SYS_HCLK,
    input  wire        SYS_PORESETn,
    input  wire        SYS_HRESETn,
    input  wire        SYS_SYSRESETn,
    input  wire        SYS_SCANENABLE,
    input  wire        SYS_TESTMODE,

    // Three AHB-Lite masters (I-Code, D-Code, System) exposed DIRECTLY — the
    // generated compute_ss busmatrix arbitrates them via its proven input/output
    // stages. HRESP adapted M4 2-bit -> 1.
    // -- I-Code (fetch-only: HWRITE/HWDATA tied) --
    output wire [31:0] mst_i_haddr,
    output wire [1:0]  mst_i_htrans,
    output wire        mst_i_hwrite,
    output wire [2:0]  mst_i_hsize,
    output wire [2:0]  mst_i_hburst,
    output wire [3:0]  mst_i_hprot,
    output wire [31:0] mst_i_hwdata,
    output wire        mst_i_hmastlock,
    input  wire [31:0] mst_i_hrdata,
    input  wire        mst_i_hready,
    input  wire        mst_i_hresp,
    // -- D-Code --
    output wire [31:0] mst_d_haddr,
    output wire [1:0]  mst_d_htrans,
    output wire        mst_d_hwrite,
    output wire [2:0]  mst_d_hsize,
    output wire [2:0]  mst_d_hburst,
    output wire [3:0]  mst_d_hprot,
    output wire [31:0] mst_d_hwdata,
    output wire        mst_d_hmastlock,
    input  wire [31:0] mst_d_hrdata,
    input  wire        mst_d_hready,
    input  wire        mst_d_hresp,
    // -- System --
    output wire [31:0] mst_s_haddr,
    output wire [1:0]  mst_s_htrans,
    output wire        mst_s_hwrite,
    output wire [2:0]  mst_s_hsize,
    output wire [2:0]  mst_s_hburst,
    output wire [3:0]  mst_s_hprot,
    output wire [31:0] mst_s_hwdata,
    output wire        mst_s_hmastlock,
    input  wire [31:0] mst_s_hrdata,
    input  wire        mst_s_hready,
    input  wire        mst_s_hresp,

    // CPU sideband
    input  wire               CORE_NMI,
    input  wire [NUM_IRQ-1:0] CORE_IRQ,
    output wire               CORE_TXEV,
    input  wire               CORE_RXEV,
    output wire               CORE_LOCKUP,
    output wire               CORE_SYSRESETREQ,
    output wire               CORE_SLEEPING,
    output wire               CORE_SLEEPDEEP,
    output wire [5:0]         CORE_FPU_FLAGS,   // {IXC,OFC,UFC,IOC,DZC,IDC}

    // ---- CoreSight AP-slave bus: the core's OWN AHB-AP ----------------------
    // Drive from a spare APSEL on nanosoc_dap_ss. Signal-for-signal the bundle
    // that wrapper already fans out to its cxdapahbap instances. Active when
    // EXTERNAL_DAP=1; ignored (and safely tied) when EXTERNAL_DAP=0.
    input  wire        DAP_CLK,       // <- dapclk
    input  wire        DAP_CLKEN,     // <- dapclken
    input  wire        DAP_RESETn,    // <- dapresetn
    input  wire        DAP_SEL,       // <- dapsel   (this AP's decoded select)
    input  wire        DAP_ENABLE,    // <- dapenable
    input  wire        DAP_WRITE,     // <- dapwrite
    input  wire        DAP_ABORT,     // <- dapabort
    input  wire [7:2]  DAP_ADDR,      // <- dapcaddr (AP register address)
    input  wire [31:0] DAP_WDATA,     // <- dapwdata
    output wire        DAP_READY,     // -> dapready
    output wire        DAP_SLVERR,    // -> dapslverr
    output wire [31:0] DAP_RDATA,     // -> daprdata

    // Debug authentication / power-up. DBG_PWRUP is the CDBGPWRUPACK-equivalent
    // from whoever answers the DP's power-up request (tie 1'b1 if the DAP
    // subsystem acks unconditionally, as nanosoc_dap_ss does today).
    input  wire        DBG_EN,
    input  wire        DBG_PWRUP,

    // Debug sideband. EDBGRQ was tied 1'b0 in v1, which closed the external-halt
    // route; it is a port now so a cross-trigger or the DAP subsystem can drive it.
    input  wire        CORE_EDBGRQ,
    input  wire        CORE_DBGRESTART,
    output wire        CORE_DBGRESTARTED,
    output wire        CORE_HALTED,

    // ---- SWJ-DP pins: used ONLY when EXTERNAL_DAP=0 -------------------------
    input  wire        CORE_nTRST,
    input  wire        CORE_SWCLKTCK,
    input  wire        CORE_SWDITMS,
    input  wire        CORE_TDI,
    output wire        CORE_TDO,
    output wire        CORE_nTDOEN,
    output wire        CORE_SWDO,
    output wire        CORE_SWDOEN,
    output wire        CORE_JTAGNSW
);

  // --- cold-start reset delay (KEPT from v1) ---------------------------------
  // Hold the M4 in reset 256 HCLKs after the AHB reset deasserts so the
  // compute_ss busmatrix decode/arbitration pipeline is settled before the M4's
  // first (vector) fetch. Without it, the first read (reset SP @0x0) returns the
  // matrix cold default 0 -> SP=0 -> the reset handler's stack push faults ->
  // HardFault lockup. Widened 8->256 on 2026-06-29 after the M4 died before
  // first-fetch on z2_04 silicon.
  reg [7:0] m4_rdly;
  always @(posedge SYS_HCLK or negedge SYS_HRESETn)
    if (!SYS_HRESETn)      m4_rdly <= 8'h0;
    else if (~m4_rdly[7])  m4_rdly <= m4_rdly + 8'h1;
  wire m4_rst_rel   = m4_rdly[7];                 // 1 after 256 HCLKs post-HRESETn
  wire m4_poresetn  = SYS_PORESETn  & m4_rst_rel;
  wire m4_sysresetn = SYS_SYSRESETn & m4_rst_rel;

  // ===========================================================================
  // Reset synchronisers (upstream CORTEXM4INTEGRATION.v:744-778, RSTBYPASS=0)
  // ===========================================================================
  reg  poreset_n_q,  poreset_n_qq;
  reg  sysreset_n_q, sysreset_n_qq;

  always @ (posedge SYS_FCLK or negedge m4_poresetn)
    if (!m4_poresetn) begin poreset_n_q <= 1'b0; poreset_n_qq <= 1'b0; end
    else              begin poreset_n_q <= 1'b1; poreset_n_qq <= poreset_n_q; end

  always @ (posedge SYS_FCLK or negedge m4_sysresetn)
    if (!m4_sysresetn) begin sysreset_n_q <= 1'b0; sysreset_n_qq <= 1'b0; end
    else               begin sysreset_n_q <= 1'b1; sysreset_n_qq <= sysreset_n_q; end

  wire int_poreset_n  = poreset_n_qq;
  wire int_sysreset_n = sysreset_n_qq;

  // ===========================================================================
  // Clocking. CLKGATE_PRESENT is fixed 0 here, so all four upstream
  // cm4_clk_gate instances collapse to wires (upstream :1069-1075).
  // ===========================================================================
  wire cclk   = SYS_FCLK;   // upstream: cclk   = FCLK  when CLKGATE_PRESENT=0
  // dclk_g (= HCLK) and trace_clk_in_g fed only the TPIU, which is gone.

  // ===========================================================================
  // Debug power-up / authentication CDC. Two cm4_sync cells kept from upstream
  // (:861-877): DBG_PWRUP and DBG_EN are asynchronous to the DAP clock.
  // The third upstream sync (c_sys_power_up -> int_gate_hclk) is gone with
  // GATEHCLK and the TPIU enable.
  // ===========================================================================
  wire dap_clk_src  = EXTERNAL_DAP ? DAP_CLK    : SYS_FCLK;
  wire dap_reset_n  = EXTERNAL_DAP ? DAP_RESETn : int_poreset_n;
  wire dbg_pwrup_sync;
  wire dbg_en_sync;

  cm4_sync #(1) u_cm4_sync_dappwrup (
      .clk(dap_clk_src), .reset_n(dap_reset_n), .d_async_i(DBG_PWRUP),
      .q_o(dbg_pwrup_sync));

  cm4_sync #(1) u_cm4_sync_dbgen (
      .clk(dap_clk_src), .reset_n(dap_reset_n), .d_async_i(DBG_EN),
      .q_o(dbg_en_sync));

  wire dap_en     = dbg_pwrup_sync & dbg_en_sync;   // upstream :878
  wire dap_clk_en = EXTERNAL_DAP ? DAP_CLKEN : dbg_pwrup_sync;

  // ===========================================================================
  // DAP bus into the core's AHB-AP
  // ===========================================================================
  wire        dap_sel;
  wire        dap_enable;
  wire        dap_write;
  wire        dap_abort;
  wire [31:0] dap_addr;
  wire [31:0] dap_wdata;
  wire        dap_ready_core;
  wire        dap_slverr_core;
  wire [31:0] dap_rdata_core;

  generate
  if (EXTERNAL_DAP != 0) begin : g_external_dap

    // The DP owns APSEL decode, so DAP_SEL is already this AP's select and the
    // upstream DAPADDR[31:24]==8'h00 test is satisfied by construction. Upstream
    // forms the core address the same way: dap_addr = {24'h0, dap_addr_mux[7:0]}
    // (CORTEXM4INTEGRATION.v:1259).
    assign dap_sel    = DAP_SEL;
    assign dap_enable = DAP_ENABLE;
    assign dap_write  = DAP_WRITE;
    assign dap_abort  = DAP_ABORT;
    assign dap_addr   = {24'h000000, DAP_ADDR[7:2], 2'b00};
    assign dap_wdata  = DAP_WDATA;

    assign DAP_READY  = dap_ready_core;
    assign DAP_SLVERR = dap_slverr_core;
    assign DAP_RDATA  = dap_rdata_core;

    // SWJ pins unused in this mode.
    assign CORE_TDO     = 1'b0;
    assign CORE_nTDOEN  = 1'b1;
    assign CORE_SWDO    = 1'b0;
    assign CORE_SWDOEN  = 1'b0;
    assign CORE_JTAGNSW = 1'b0;

  end else begin : g_internal_dp

    // Pre-v2 fallback: the core's own SWJ-DP on dedicated pins.
    // nTRST synchroniser (upstream :770-778) — SWCLKTCK domain, needed only here.
    reg po_trst_n_q, po_trst_n_qq;
    always @ (posedge CORE_SWCLKTCK or negedge m4_poresetn)
      if (!m4_poresetn) begin po_trst_n_q <= 1'b0; po_trst_n_qq <= 1'b0; end
      else              begin po_trst_n_q <= 1'b1; po_trst_n_qq <= po_trst_n_q; end

    DAPSWJDP #((DEBUG_LVL > 0) ? 1 : 0, 1, RESET_ALL_REGS) uDAPSWJDP (
        .nPOTRST      (po_trst_n_qq),
        .nTRST        (CORE_nTRST),
        .SWCLKTCK     (CORE_SWCLKTCK),
        .SWDITMS      (CORE_SWDITMS),
        .TDI          (CORE_TDI),
        .DAPRESETn    (dap_reset_n),
        .DAPCLK       (dap_clk_src),
        .DAPCLKEN     (dap_clk_en),
        .DAPRDATA     (dap_rdata_core),
        .DAPREADY     (dap_ready_core),
        .DAPSLVERR    (dap_slverr_core),
        .nCDBGPWRDN   (1'b1),
        .CDBGPWRUPACK (DBG_PWRUP),
        .CSYSPWRUPACK (DBG_PWRUP),
        .CDBGRSTACK   (1'b0),
        .TDO          (CORE_TDO),
        .nTDOEN       (CORE_nTDOEN),
        .DAPSEL       (dap_sel),
        .DAPENABLE    (dap_enable),
        .DAPWRITE     (dap_write),
        .DAPABORT     (dap_abort),
        .DAPADDR      (dap_addr),
        .DAPWDATA     (dap_wdata),
        .CDBGPWRUPREQ (),
        .CSYSPWRUPREQ (),
        .CDBGRSTREQ   (),
        .SWDO         (CORE_SWDO),
        .SWDOEN       (CORE_SWDOEN),
        .JTAGNSW      (CORE_JTAGNSW),
        .JTAGTOP      ()
      );

    // AP-slave port idle in this mode.
    assign DAP_READY  = 1'b1;
    assign DAP_SLVERR = 1'b0;
    assign DAP_RDATA  = 32'h0;

  end
  endgenerate

  // ===========================================================================
  // M4 native master buses -> three AHB-Lite master ports
  // ===========================================================================
  // I-Code (fetch-only) — M4 outputs
  wire [1:0]  htransi; wire [2:0] hsizei; wire [31:0] haddri; wire [2:0] hbursti;
  wire [3:0]  hproti;  wire [1:0] memattri;
  // IFLUSH is an M4 INPUT (I-Code buffer flush). Undriven -> X -> the fetch
  // buffer perpetually flushes and the PC never advances past the reset vector.
  wire iflush = 1'b0;
  // D-Code — M4 outputs
  wire [1:0]  hmasterd; wire [1:0] htransd; wire [2:0] hsized; wire [31:0] haddrd;
  wire [2:0]  hburstd; wire [3:0] hprotd; wire [1:0] memattrd; wire exreqd;
  wire        hwrited; wire [31:0] hwdatad;
  // System — M4 outputs
  wire [1:0]  hmasters; wire [1:0] htranss; wire hwrites; wire [2:0] hsizes;
  wire        hmastlocks; wire [31:0] haddrs; wire [31:0] hwdatas; wire [2:0] hbursts;
  wire [3:0]  hprots; wire [1:0] memattrs; wire exreqs;

  assign mst_i_haddr=haddri; assign mst_i_htrans=htransi; assign mst_i_hwrite=1'b0;
  assign mst_i_hsize=hsizei; assign mst_i_hburst=hbursti; assign mst_i_hprot=hproti;
  assign mst_i_hwdata=32'b0; assign mst_i_hmastlock=1'b0;
  wire [31:0] hrdatai = mst_i_hrdata; wire hreadyi = mst_i_hready;
  wire [1:0]  hrespi  = {1'b0, mst_i_hresp};

  assign mst_d_haddr=haddrd; assign mst_d_htrans=htransd; assign mst_d_hwrite=hwrited;
  assign mst_d_hsize=hsized; assign mst_d_hburst=hburstd; assign mst_d_hprot=hprotd;
  assign mst_d_hwdata=hwdatad; assign mst_d_hmastlock=1'b0;
  wire [31:0] hrdatad = mst_d_hrdata; wire hreadyd = mst_d_hready;
  wire [1:0]  hrespd  = {1'b0, mst_d_hresp};

  assign mst_s_haddr=haddrs; assign mst_s_htrans=htranss; assign mst_s_hwrite=hwrites;
  assign mst_s_hsize=hsizes; assign mst_s_hburst=hbursts; assign mst_s_hprot=hprots;
  assign mst_s_hwdata=hwdatas; assign mst_s_hmastlock=hmastlocks;
  wire [31:0] hrdatas = mst_s_hrdata; wire hreadys = mst_s_hready;
  wire [1:0]  hresps  = {1'b0, mst_s_hresp};

  // --- IRQ packing: NUM_IRQ lines -> the M4's architectural [239:0] ----------
  // WIC_PRESENT=0, so the upstream WIC-pend OR terms (:1157-1160) are all zero.
  wire [239:0] intisr = {{(240-NUM_IRQ){1'b0}}, CORE_IRQ};

  // --- FPU exception flags bundle -------------------------------------------
  wire fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc;
  assign CORE_FPU_FLAGS = {fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc};

  // ===========================================================================
  // External PPB (APB) segment. Upstream decode at :1466-1475:
  //   paddr[19:12] == 8'h40 -> TPIU      (not instantiated, reads 0)
  //   paddr[19:12] == 8'h41 -> ETM       (unlicensed, reads 0)
  //   paddr[19:12] == 8'hFF -> ROM table (KEPT — debugger discovery)
  // ===========================================================================
  wire        ppb_psel;
  wire [19:2] ppb_paddr;
  wire        ppb_penable;
  wire        ppb_pwrite;
  wire [31:0] ppb_pwdata;

  wire        ppb_psel_rom = ppb_psel & (ppb_paddr[19:12] == 8'hFF);
  wire [31:0] int_prdata_rom;

  cm4_rom_table #(DEBUG_LVL, TRACE_LVL) u_cm4_rom_table (
      .PCLK    (SYS_HCLK),
      .PRESETn (int_poreset_n),
      .PSEL    (ppb_psel_rom),
      .PENABLE (ppb_penable),
      .PADDR   (ppb_paddr[11:2]),
      .PWRITE  (ppb_pwrite),
      .PRDATA  (int_prdata_rom)
    );

  wire [31:0] ppb_prdata  = ppb_psel_rom ? int_prdata_rom : 32'h0;
  wire        ppb_pready  = 1'b1;   // ROM table has no wait states
  wire        ppb_pslverr = 1'b0;

  // ===========================================================================
  // TPIU removal terms (upstream :1409-1416 with TRACE_LVL forced to 0).
  // See header: the TPIU is already held in permanent reset on this die.
  // ===========================================================================
  wire tpiu_active = 1'b0;
  wire tpiu_baud   = 1'b0;
  wire at_ready    = 1'b1;   // upstream atb_ready_port1 default when trace absent

  // --- ETM removal terms (upstream :1337-1340) ------------------------------
  wire etm_power_up  = 1'b0;
  wire etm_fifo_full = 1'b0;

  // ===========================================================================
  // The Arm Cortex-M4 core
  // ===========================================================================
  CORTEXM4 #(
      .MPU_PRESENT(MPU_PRESENT), .NUM_IRQ(NUM_IRQ), .LVL_WIDTH(LVL_WIDTH),
      .TRACE_LVL(TRACE_LVL), .DEBUG_LVL(DEBUG_LVL),
      .CLKGATE_PRESENT(0), .RESET_ALL_REGS(RESET_ALL_REGS),
      .WIC_PRESENT(0), .WIC_LINES(3),
      .BB_PRESENT(BB_PRESENT), .CONST_AHB_CTRL(0), .FPU_PRESENT(FPU_PRESENT)
  ) uCORTEXM4 (
      // clocks / resets
      .PORESETn      (int_poreset_n),
      .SYSRESETn     (int_sysreset_n),
      .RSTBYPASS     (1'b0),
      .CGBYPASS      (1'b0),
      .FCLK          (cclk),
      .HCLK          (SYS_HCLK),
      .STCLK         (1'b0),
      .STCALIB       (26'h0),
      // config straps
      .AUXFAULT      (32'b0),
      .BIGEND        (BE[0]),
      .MPUDISABLE    (1'b0),
      .FPUDISABLE    (1'b0),
      .FIXMASTERTYPE (1'b0),
      .SE            (SYS_SCANENABLE),
      .DNOTITRANS    (1'b0),        // upstream ARM_CODEMUX not defined
      .STKALIGNINIT  (1'b1),        // upstream :1629 — note: 1, not 0
      .PPBLOCK       (6'b000000),   // upstream :1632
      .VECTADDR      (10'b0),       // upstream :1633
      .VECTADDREN    (1'b0),        // upstream :1634
      .TSVALUEB      (48'h0),
      .TSCLKCHANGE   (1'b0),
      // interrupts / events
      .INTISR        (intisr),
      .INTNMI        (CORE_NMI),
      .RXEV          (CORE_RXEV),
      .TXEV          (CORE_TXEV),
      .SLEEPHOLDREQn (1'b1),
      .SLEEPHOLDACKn (),
      .SLEEPING      (CORE_SLEEPING),
      .SLEEPDEEP     (CORE_SLEEPDEEP),
      // WIC absent — upstream cm4_wic outputs with WIC_PRESENT=0
      .WICDSREQn     (1'b1),
      .WICDSACKn     (), .WICLOAD  (), .WICCLEAR (),
      .WICMASKISR    (), .WICMASKMON(), .WICMASKNMI(), .WICMASKRXEV(),
      // I-Code bus
      .HADDRI(haddri), .HTRANSI(htransi), .HSIZEI(hsizei), .HBURSTI(hbursti),
      .HPROTI(hproti), .MEMATTRI(memattri),
      .HRDATAI(hrdatai), .HREADYI(hreadyi), .HRESPI(hrespi), .IFLUSH(iflush),
      // D-Code bus
      .HADDRD(haddrd), .HTRANSD(htransd), .HSIZED(hsized), .HBURSTD(hburstd),
      .HPROTD(hprotd), .MEMATTRD(memattrd), .HMASTERD(hmasterd),
      .HWRITED(hwrited), .HWDATAD(hwdatad), .EXREQD(exreqd),
      .HRDATAD(hrdatad), .HREADYD(hreadyd), .HRESPD(hrespd), .EXRESPD(1'b0),
      // System bus
      .HADDRS(haddrs), .HTRANSS(htranss), .HSIZES(hsizes), .HBURSTS(hbursts),
      .HPROTS(hprots), .MEMATTRS(memattrs), .HMASTERS(hmasters),
      .HMASTLOCKS(hmastlocks), .HWRITES(hwrites), .HWDATAS(hwdatas),
      .EXREQS(exreqs),
      .HRDATAS(hrdatas), .HREADYS(hreadys), .HRESPS(hresps), .EXRESPS(1'b0),
      // External PPB (APB)
      .PSEL(ppb_psel), .PADDR31(), .PADDR(ppb_paddr), .PENABLE(ppb_penable),
      .PWRITE(ppb_pwrite), .PWDATA(ppb_pwdata),
      .PRDATA(ppb_prdata), .PREADY(ppb_pready), .PSLVERR(ppb_pslverr),
      // DAP bus — the core's own AHB-AP
      .DAPEN     (dap_en),
      .DAPCLK    (dap_clk_src),
      .DAPCLKEN  (dap_clk_en),
      .DAPRESETn (dap_reset_n),
      .DAPSEL    (dap_sel),
      .DAPENABLE (dap_enable),
      .DAPWRITE  (dap_write),
      .DAPABORT  (dap_abort),
      .DAPADDR   (dap_addr),
      .DAPWDATA  (dap_wdata),
      .DAPREADY  (dap_ready_core),
      .DAPSLVERR (dap_slverr_core),
      .DAPRDATA  (dap_rdata_core),
      // debug sideband
      .DBGEN         (DBG_EN),
      .EDBGRQ        (CORE_EDBGRQ),
      .DBGRESTART    (CORE_DBGRESTART),
      .DBGRESTARTED  (CORE_DBGRESTARTED),
      .HALTED        (CORE_HALTED),
      // trace: TPIU/ETM not instantiated
      .ETMPWRUP      (etm_power_up),
      .ETMFIFOFULL   (etm_fifo_full),
      .TPIUACTV      (tpiu_active),
      .TPIUBAUD      (tpiu_baud),
      .ATREADY       (at_ready),
      .ATVALID(), .AFREADY(), .ATDATA(), .ATIDITM(), .TRCENA(), .DSYNC(),
      .ETMTRIGGER(), .ETMTRIGINOTD(), .ETMIVALID(), .ETMISTALL(), .ETMDVALID(),
      .ETMFOLD(), .ETMCANCEL(), .ETMIA(), .ETMICCFAIL(), .ETMIBRANCH(),
      .ETMIINDBR(), .ETMISB(), .ETMINTSTAT(), .ETMINTNUM(), .ETMFLUSH(),
      .ETMFINDBR(),
      // HTM data port — TRACE_LVL<=2 so opt_htm_en=0 inside the core
      .HTMDHADDR(), .HTMDHTRANS(), .HTMDHSIZE(), .HTMDHBURST(), .HTMDHPROT(),
      .HTMDHWDATA(), .HTMDHRDATA(), .HTMDHWRITE(), .HTMDHREADY(), .HTMDHRESP(),
      // status
      .BRCHSTAT(), .CURRPRI(),
      .LOCKUP(CORE_LOCKUP), .SYSRESETREQ(CORE_SYSRESETREQ),
      // FPU flags
      .FPIXC(fpixc), .FPOFC(fpofc), .FPUFC(fpufc),
      .FPIOC(fpioc), .FPDZC(fpdzc), .FPIDC(fpidc)
    );

endmodule
