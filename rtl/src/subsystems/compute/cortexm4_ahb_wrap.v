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

// Module is named `slcorem4` to match the slcorem4 sys_desc core block (the
// generator binds instances by the YAML `name`, mirroring slcorem0p ->
// slcorem0p_tech). The file keeps its cortexm4_ahb_wrap.v name.
module slcorem4 #(
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

    // Three AHB-Lite masters (I-Code, D-Code, System) exposed DIRECTLY — the
    // generated compute_ss busmatrix arbitrates them (with cpu_ss) via its proven
    // input/output stages. No custom merge. Generator names these from the
    // slcorem4.yaml interface names mst_i/mst_d/mst_s (subsystem backend expands a
    // non-`ahb_master` ahb interface to {name}_<sig>). HRESP adapted M4 2-bit->1.
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

  // --- M4 native master buses -> three AHB-Lite master ports -----------------
  // The M4's I-Code/D-Code/System masters are exposed DIRECTLY to the compute_ss
  // busmatrix (no merge); the matrix's proven CMSDK input/output stages arbitrate
  // them with cpu_ss. Below: M4 OUTPUT buses are wired to the master ports; the
  // master response (HRDATA/HREADY/HRESP) is wired back to the M4 inputs (HRESP
  // zero-extended M4 2-bit). MEMATTR/HMASTER/EXREQ are dropped; exclusives tied.
  // I-Code (fetch-only) — M4 outputs
  wire [1:0]  htransi; wire [2:0] hsizei; wire [31:0] haddri; wire [2:0] hbursti;
  wire [3:0]  hproti;  wire [1:0] memattri;
  // IFLUSH is an M4 INPUT (ICode-bus buffer flush). Undriven -> floating X -> the
  // fetch buffer perpetually flushes and the PC never advances past the reset
  // vector (combinational input, so RESET_ALL_REGS cannot mask it). Tie inactive.
  wire iflush = 1'b0;
  // D-Code — M4 outputs
  wire [1:0]  hmasterd; wire [1:0] htransd; wire [2:0] hsized; wire [31:0] haddrd;
  wire [2:0]  hburstd; wire [3:0] hprotd; wire [1:0] memattrd; wire exreqd;
  wire        hwrited; wire [31:0] hwdatad;
  // System — M4 outputs
  wire [1:0]  hmasters; wire [1:0] htranss; wire hwrites; wire [2:0] hsizes;
  wire        hmastlocks; wire [31:0] haddrs; wire [31:0] hwdatas; wire [2:0] hbursts;
  wire [3:0]  hprots; wire [1:0] memattrs; wire exreqs;

  // I-Code master port (read-only: HWRITE/HWDATA tied)
  assign mst_i_haddr=haddri; assign mst_i_htrans=htransi; assign mst_i_hwrite=1'b0;
  assign mst_i_hsize=hsizei; assign mst_i_hburst=hbursti; assign mst_i_hprot=hproti;
  assign mst_i_hwdata=32'b0; assign mst_i_hmastlock=1'b0;
  wire [31:0] hrdatai = mst_i_hrdata; wire hreadyi = mst_i_hready;
  wire [1:0]  hrespi  = {1'b0, mst_i_hresp};
  // D-Code master port
  assign mst_d_haddr=haddrd; assign mst_d_htrans=htransd; assign mst_d_hwrite=hwrited;
  assign mst_d_hsize=hsized; assign mst_d_hburst=hburstd; assign mst_d_hprot=hprotd;
  assign mst_d_hwdata=hwdatad; assign mst_d_hmastlock=1'b0;
  wire [31:0] hrdatad = mst_d_hrdata; wire hreadyd = mst_d_hready;
  wire [1:0]  hrespd  = {1'b0, mst_d_hresp};
  // System master port
  assign mst_s_haddr=haddrs; assign mst_s_htrans=htranss; assign mst_s_hwrite=hwrites;
  assign mst_s_hsize=hsizes; assign mst_s_hburst=hbursts; assign mst_s_hprot=hprots;
  assign mst_s_hwdata=hwdatas; assign mst_s_hmastlock=hmastlocks;
  wire [31:0] hrdatas = mst_s_hrdata; wire hreadys = mst_s_hready;
  wire [1:0]  hresps  = {1'b0, mst_s_hresp};

  // --- DBGAHB v1 stub (OKAY, no data) ---------------------------------------
  assign DBGAHB_SLVRDATA = 32'h0;
  assign DBGAHB_SLVREADY = 1'b1;
  assign DBGAHB_SLVRESP  = 1'b0;

  // --- IRQ packing: NUM_IRQ lines -> the M4's architectural [239:0] ----------
  wire [239:0] intisr = {{(240-NUM_IRQ){1'b0}}, CORE_IRQ};

  // --- FPU exception flags bundle -------------------------------------------
  wire fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc;
  assign CORE_FPU_FLAGS = {fpixc, fpofc, fpufc, fpioc, fpdzc, fpidc};

  // --- cold-start reset delay -----------------------------------------------
  // Hold the M4 in reset a few HCLKs after the AHB reset deasserts so the compute_ss
  // busmatrix decode/arbitration pipeline is settled before the M4's first (vector)
  // fetch. Without this, cpu_0_i's FIRST read (the reset SP @0x0) returns the
  // matrix's cold default (0) -> SP=0 -> the reset handler's stack push faults ->
  // HardFault lockup. (The M0+ manager avoids this via its PRMU reset sequencing;
  // the M4 is a reset CONSUMER, so it would otherwise fetch immediately.)
  // Widened 8->256 HCLKs (2026-06-29 HW bring-up): the 8-HCLK delay was enough in
  // zero-delay cocotb but the M4 dies before first-fetch on z2_04 silicon (M4
  // wrote no breadcrumb; DMA-250 idle). 256 HCLKs (~10us @25MHz) gives the real
  // FPGA busmatrix decode/HREADY and the unsynchronised POR deassert ample settle
  // before the M4's first vector fetch. Cheap insurance against the cold-default
  // (SP@0x0=0) first-fetch HardFault this delay exists to prevent.
  reg [7:0] m4_rdly;
  always @(posedge SYS_HCLK or negedge SYS_HRESETn)
    if (!SYS_HRESETn)      m4_rdly <= 8'h0;
    else if (~m4_rdly[7])  m4_rdly <= m4_rdly + 8'h1;
  wire m4_rst_rel   = m4_rdly[7];                 // 1 after 256 HCLKs post-HRESETn
  wire m4_poresetn  = SYS_PORESETn  & m4_rst_rel;
  wire m4_sysresetn = SYS_SYSRESETn & m4_rst_rel;

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
    .PORESETn(m4_poresetn), .SYSRESETn(m4_sysresetn), .nTRST(1'b1),
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
