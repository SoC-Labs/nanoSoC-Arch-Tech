//-----------------------------------------------------------------------------
// SoC Labs Cortex-M4 AHB-Lite Wrapper (cortexm4_ahb_wrap)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Wraps the Arm CORTEXM4INTEGRATION IP (sourced READ-ONLY from
// /research/AAA/ip_library/Cortex-M4 via the flist — NOT copied/edited here) and
// presents the boundary described by sys_desc/slcorem4.yaml so nanosoc_gen can
// instantiate it like any core block.
//
// v1 (single-master): merges the M4's three native master buses
//   - I-Code  (HADDRI..., fetch-only)
//   - D-Code  (HADDRD..., +HWDATAD, exclusives)
//   - System  (HADDRS..., +HMASTLOCKS, exclusives)
// into ONE standard AHB-Lite master {HADDR,HTRANS,HWRITE,HSIZE,HBURST,HPROT,
// HWDATA,HMASTLOCK,HRDATA,HREADY,HRESP} via the cm4_ahb_merge3 sub-block, which
// also adapts HRESP[1:0]->[0], drops MEMATTR, and terminates exclusives.
//
// Clock/reset: CONSUMER — SYS_HCLK/SYS_HRESETn/SYS_PORESETn are inputs (driven
// by the SoC manager core). FPU+MPU enabled; trace/ETM excluded (TRACE_LVL=1,
// no ARM_CM4_ETM_LICENSE). The M4's own SWJ-DP is bonded at the SoC top; the
// DBGAHB_SLV* wrapper ports are a v1 stub (debug handled by a top-level 2nd AP
// or the M4 SW-DP — see docs/M4_STRUCTURED_BUS_GENERATOR_DESIGN.md / the system
// structure doc).
//
//  !!! ELABORATION/SIM STATUS: authored against the M4 integration interface +
//  !!! standard AHB-Lite patterns; MUST be elaborated and simulated on the EDA
//  !!! host against the real M4 IP (and the cm4_ahb_merge3 arbiter verified, or
//  !!! replaced by a known-good AHB-Lite layer-mux) before trust. The
//  !!! CORTEXM4INTEGRATION instantiation below is exact per the IP boundary.
//-----------------------------------------------------------------------------
`include "cm4_lic_defs.v"   // from $CM4_IP_DIR/cm4_lic_defs (read-only IP)

module cortexm4_ahb_wrap #(
    parameter FPU_PRESENT     = 1,
    parameter MPU_PRESENT     = 1,
    parameter NUM_IRQ         = 64,
    parameter LVL_WIDTH       = 4,
    parameter TRACE_LVL       = 1,
    parameter DEBUG_LVL       = 3,
    parameter WIC_PRESENT     = 0,
    parameter BB_PRESENT      = 1,
    parameter CLKGATE_PRESENT = 0,
    parameter RESET_ALL_REGS  = 0,
    parameter BE              = 0
) (
    // Clock / reset INPUTS (consumer)
    input  wire        SYS_FCLK,
    input  wire        SYS_HCLK,
    input  wire        SYS_PORESETn,
    input  wire        SYS_HRESETn,
    input  wire        SYS_SYSRESETn,
    input  wire        SYS_SCANENABLE,
    input  wire        SYS_TESTMODE,

    // Single merged AHB-Lite master (bare-uppercase, generator convention)
    output wire [31:0] HADDR,
    output wire [1:0]  HTRANS,
    output wire        HWRITE,
    output wire [2:0]  HSIZE,
    output wire [2:0]  HBURST,
    output wire [3:0]  HPROT,
    output wire [31:0] HWDATA,
    output wire        HMASTLOCK,
    input  wire [31:0] HRDATA,
    input  wire        HREADY,
    input  wire        HRESP,        // 1-bit AHB-Lite (adapted from M4 2-bit)

    // CPU sideband
    input  wire             CORE_NMI,
    input  wire [NUM_IRQ-1:0] CORE_IRQ,
    output wire             CORE_TXEV,
    input  wire             CORE_RXEV,
    output wire             CORE_LOCKUP,
    output wire             CORE_SYSRESETREQ,
    output wire             CORE_SLEEPING,
    output wire             CORE_SLEEPDEEP,
    output wire [5:0]       CORE_FPU_FLAGS,   // {IXC,OFC,UFC,IOC,DZC,IDC}

    // Debug AHB-AP slave bus — v1 STUB (see header)
    input  wire [31:0] DBGAHB_SLVADDR,
    input  wire [31:0] DBGAHB_SLVWDATA,
    input  wire [1:0]  DBGAHB_SLVTRANS,
    input  wire        DBGAHB_SLVWRITE,
    input  wire [1:0]  DBGAHB_SLVSIZE,
    output wire [31:0] DBGAHB_SLVRDATA,
    output wire        DBGAHB_SLVREADY,
    output wire        DBGAHB_SLVRESP
);

  // --- M4 native master buses (between the IP and the merge block) ----------
  // I-Code (fetch-only)
  wire [1:0]  htransi; wire [2:0] hsizei; wire [31:0] haddri; wire [2:0] hbursti;
  wire [3:0]  hproti;  wire [1:0] memattri; wire iflush;
  wire        hreadyi = HREADY;  wire [31:0] hrdatai = HRDATA; wire [1:0] hrespi = {1'b0, HRESP};
  // D-Code
  wire [1:0]  hmasterd; wire [1:0] htransd; wire [2:0] hsized; wire [31:0] haddrd;
  wire [2:0]  hburstd; wire [3:0] hprotd; wire [1:0] memattrd; wire exreqd;
  wire        hwrited; wire [31:0] hwdatad;
  wire        hreadyd = HREADY; wire [31:0] hrdatad = HRDATA; wire [1:0] hrespd = {1'b0, HRESP};
  // System
  wire [1:0]  hmasters; wire [1:0] htranss; wire hwrites; wire [2:0] hsizes;
  wire        hmastlocks; wire [31:0] haddrs; wire [31:0] hwdatas; wire [2:0] hbursts;
  wire [3:0]  hprots; wire [1:0] memattrs; wire exreqs;
  wire        hreadys = HREADY; wire [31:0] hrdatas = HRDATA; wire [1:0] hresps = {1'b0, HRESP};

  // --- 3:1 AHB-Lite merge (I+D code-mux + System) -> single master ----------
  // NOTE: reference arbiter — verify/replace on EDA host (see header banner).
  cm4_ahb_merge3 u_merge (
    .HCLK(SYS_HCLK), .HRESETn(SYS_HRESETn),
    // I-Code (read-only)
    .i_htrans(htransi), .i_haddr(haddri), .i_hsize(hsizei), .i_hburst(hbursti), .i_hprot(hproti),
    // D-Code
    .d_htrans(htransd), .d_haddr(haddrd), .d_hwrite(hwrited), .d_hsize(hsized),
    .d_hburst(hburstd), .d_hprot(hprotd), .d_hwdata(hwdatad),
    // System
    .s_htrans(htranss), .s_haddr(haddrs), .s_hwrite(hwrites), .s_hsize(hsizes),
    .s_hburst(hbursts), .s_hprot(hprots), .s_hwdata(hwdatas), .s_hmastlock(hmastlocks),
    // merged downstream master
    .m_haddr(HADDR), .m_htrans(HTRANS), .m_hwrite(HWRITE), .m_hsize(HSIZE),
    .m_hburst(HBURST), .m_hprot(HPROT), .m_hwdata(HWDATA), .m_hmastlock(HMASTLOCK),
    .m_hrdata(HRDATA), .m_hready(HREADY), .m_hresp(HRESP)
  );

  // --- DBGAHB v1 stub (OKAY, no data) ---------------------------------------
  assign DBGAHB_SLVRDATA = 32'h0;
  assign DBGAHB_SLVREADY = 1'b1;
  assign DBGAHB_SLVRESP  = 1'b0;

  // --- IRQ packing: NUM_IRQ lines -> the M4's architectural [239:0] ----------
  wire [239:0] intisr = {{(240-NUM_IRQ){1'b0}}, CORE_IRQ};

  // --- FPU exception flags bundle -------------------------------------------
  wire fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc;
  assign CORE_FPU_FLAGS = {fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc};

  // --- the Arm Cortex-M4 integration IP (exact boundary) --------------------
  CORTEXM4INTEGRATION #(
    .MPU_PRESENT(MPU_PRESENT), .NUM_IRQ(NUM_IRQ), .LVL_WIDTH(LVL_WIDTH),
    .TRACE_LVL(TRACE_LVL), .DEBUG_LVL(DEBUG_LVL), .JTAG_PRESENT(1),
    .CLKGATE_PRESENT(CLKGATE_PRESENT), .RESET_ALL_REGS(RESET_ALL_REGS),
    .WIC_PRESENT(WIC_PRESENT), .WIC_LINES(3), .BB_PRESENT(BB_PRESENT),
    .CONST_AHB_CTRL(0), .FPU_PRESENT(FPU_PRESENT)
  ) u_cm4 (
    // power / config straps
    .ISOLATEn(1'b1), .RETAINn(1'b1), .CGBYPASS(1'b0), .RSTBYPASS(1'b0), .SE(SYS_SCANENABLE),
    .BIGEND(BE[0]), .AUXFAULT(32'b0), .MPUDISABLE(1'b0), .FPUDISABLE(1'b0), .FIXMASTERTYPE(1'b0),
    // clocks / resets
    .FCLK(SYS_FCLK), .HCLK(SYS_HCLK), .TRACECLKIN(1'b0), .STCLK(1'b0), .STCALIB(26'h0),
    .PORESETn(SYS_PORESETn), .SYSRESETn(SYS_SYSRESETn), .nTRST(1'b1),
    // interrupts
    .INTISR(intisr), .INTNMI(CORE_NMI),
    // I-Code bus (fetch)
    .HADDRI(haddri), .HTRANSI(htransi), .HSIZEI(hsizei), .HBURSTI(hbursti), .HPROTI(hproti),
    .MEMATTRI(memattri), .HRDATAI(hrdatai), .HREADYI(hreadyi), .HRESPI(hrespi), .IFLUSH(iflush),
    // D-Code bus
    .HADDRD(haddrd), .HTRANSD(htransd), .HSIZED(hsized), .HBURSTD(hburstd), .HPROTD(hprotd),
    .MEMATTRD(memattrd), .HMASTERD(hmasterd), .HWRITED(hwrited), .HWDATAD(hwdatad), .EXREQD(exreqd),
    .HRDATAD(hrdatad), .HREADYD(hreadyd), .HRESPD(hrespd), .EXRESPD(1'b0),
    // System bus
    .HADDRS(haddrs), .HTRANSS(htranss), .HSIZES(hsizes), .HBURSTS(hbursts), .HPROTS(hprots),
    .MEMATTRS(memattrs), .HMASTERS(hmasters), .HMASTLOCKS(hmastlocks), .HWRITES(hwrites),
    .HWDATAS(hwdatas), .EXREQS(exreqs), .HRDATAS(hrdatas), .HREADYS(hreadys), .HRESPS(hresps),
    .EXRESPS(1'b0),
    // sleep / events
    .RXEV(CORE_RXEV), .TXEV(CORE_TXEV), .SLEEPHOLDREQn(1'b1), .SLEEPHOLDACKn(),
    .SLEEPING(CORE_SLEEPING), .SLEEPDEEP(CORE_SLEEPDEEP), .GATEHCLK(), .WICENREQ(1'b0),
    .WICENACK(), .WAKEUP(),
    // SWJ-DP (bonded at SoC top; tie inactive here, DBGAHB stub above)
    .SWCLKTCK(1'b0), .SWDITMS(1'b1), .TDI(1'b1),
    .TDO(), .nTDOEN(), .SWDO(), .SWDOEN(), .JTAGNSW(),
    .DBGEN(1'b1), .EDBGRQ(1'b0), .DBGRESTART(1'b0), .DBGRESTARTED(), .HALTED(),
    .CDBGPWRUPACK(1'b1), .CDBGPWRUPREQ(),
    // trace (TRACE_LVL=1 -> ports tie internally; leave open)
    .SWV(), .TRACECLK(), .TRACEDATA(), .ETMINTNUM(), .ETMINTSTAT(),
    .HTMDHADDR(), .HTMDHTRANS(), .HTMDHSIZE(), .HTMDHBURST(), .HTMDHPROT(),
    .HTMDHWDATA(), .HTMDHWRITE(), .HTMDHRDATA(), .HTMDHREADY(), .HTMDHRESP(),
    // timestamp
    .TSVALUEB(48'h0), .TSCLKCHANGE(1'b0),
    // status / misc
    .BRCHSTAT(), .CURRPRI(), .LOCKUP(CORE_LOCKUP), .SYSRESETREQ(CORE_SYSRESETREQ),
    // FPU flags
    .FPIXC(fpixc), .FPOFC(fpofc), .FPUFC(fpufc), .FPIOC(fpioc), .FPDZC(fpdzc), .FPIDC(fpidc)
  );

endmodule
