//-----------------------------------------------------------------------------
// core_remap_ctrl.v — managed-core memory-remap and boot-gate control register
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Generalised from the multicore system's cpu1_remap_ctrl (logic identical).
//
// A minimal AHB-Lite single-register slave for a dual-core nanosoc with one
// MANAGER core and one boot-gated MANAGED core (M0+/M0+ or M0+/M4). It lets
// the managed core's stage-0 bootrom flip its address REMAP after boot, AND
// lets the MANAGER core's stage-0 release the managed core's hardware reset
// gate (bootgate).
//
// Register map (one 32-bit register, aliased across the whole region):
//   +0x00  CTRL  [3:0] write-1-set, read-back current value.
//     [0]  REMAP     — when 1, the managed core's 0x0 aliases IMEM (else
//                      BOOTROM). The managed core's stage-0 sets this just
//                      before branching to IMEM.
//     [1]  BOOTGATE  — when 0, the managed core's sys_sysresetn is de-asserted
//                      (managed core held in reset). The MANAGER core's stage-0
//                      writes 0x2 here after flash/XiP is initialised to release
//                      the managed core from reset.
//     [3:2] spare    — pass through (write-1-set).
//
//   Write-1-set semantics: writing a '1' bit SETS that bit; writing '0'
//   has no effect. This ensures the managed core's bootrom write of REMAP=1
//   (value 0x1) cannot accidentally clear the BOOTGATE bit the manager core
//   already set. Once set, bits are only cleared by the STABLE reset PORESETn
//   (power-on / external sys_sysresetn).
//
//   nanosoc_reset_ctrl folds remap_ctrl[1] (BOOTGATE) into the managed core's
//   resetn:  managed_resetn = bootgate & ~managed_reset_pulse
//   so the managed core is held in hardware reset until the manager explicitly
//   writes 0x2.
//
//   RESET DOMAIN SPLIT (bootgate persists across a manager-core reset):
//   The REMAP_CTRL *storage* (remap_q — the bootgate/remap bits) is reset by
//   PORESETn, a STABLE reset wired at the top to the external sys_sysresetn
//   (the same signal feeding the reset controller's PORESETn). It is
//   DELIBERATELY NOT reset by HRESETn. HRESETn is the manager core's
//   PRMU-derived sys_hresetn, which dips whenever the manager takes a
//   software/fabric reset; if remap_q were cleared by HRESETn then a manager
//   reset would drop the bootgate and re-gate the managed core. Resetting
//   remap_q on PORESETn only makes the bootgate (and REMAP) bit PERSIST across
//   a manager reset, so the managed core is not re-gated and auto-recovers. The
//   AHB address/data-phase handshake flop (wr_en_q) keeps HRESETn so the bus
//   interface still resets with the fabric. At power-on PORESETn clears remap_q
//   -> BOOTROM at 0x0 and the managed core held until released.
//
//   NOTE: full clock isolation of the managed core from a manager reset is not
//   guaranteed here if the managed core's interconnect clock is sourced from
//   the manager's PRMU — a manager reset still disturbs that clock briefly. The
//   achievable, valuable win is bootgate-VALUE persistence: the managed core is
//   no longer HELD in reset after a manager reset and recovers without a manual
//   bootgate re-release.
//
// Zero wait states (HREADYOUT held high), always OKAY response.
//-----------------------------------------------------------------------------

module core_remap_ctrl #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32
) (
    input  wire                   HCLK,
    input  wire                   HRESETn,
    // Stable power-on reset (= external sys_sysresetn). Resets the REMAP_CTRL
    // storage (bootgate/remap bits) so they PERSIST across a manager-core
    // (HRESETn) reset. Mirrors nanosoc_reset_ctrl's PORESETn vs HRESETn split.
    input  wire                   PORESETn,

    // AHB-Lite slave (target) port
    input  wire                   HSEL,
    input  wire  [SYS_ADDR_W-1:0] HADDR,
    input  wire            [1:0]  HTRANS,
    input  wire                   HWRITE,
    input  wire            [2:0]  HSIZE,
    input  wire            [2:0]  HBURST,
    input  wire            [3:0]  HPROT,
    input  wire  [SYS_DATA_W-1:0] HWDATA,
    input  wire                   HMASTLOCK,
    input  wire                   HREADY,
    output wire                   HREADYOUT,
    output wire  [SYS_DATA_W-1:0] HRDATA,
    output wire                   HRESP,

    // Remap control output -> managed core's sys_remap_ctrl
    output wire            [3:0]  remap_ctrl
);

    // Unused AHB qualifiers (single-register, word-only, no bursts/locks).
    // Only HTRANS[1] and HWDATA[3:0] are consumed; reference the rest here so
    // the reduction is a no-op lint-suppression sink (this wire is never read).
    wire _unused = &{1'b0, HSIZE, HBURST, HPROT, HMASTLOCK, HADDR,
                     HTRANS[0], HWDATA[SYS_DATA_W-1:4]};

    // Address-phase write request: selected, sequential/non-seq, bus ready.
    wire        addr_phase_wr = HSEL & HREADY & HWRITE & HTRANS[1];

    reg         wr_en_q;
    reg  [3:0]  remap_q;

    // AHB address->data phase handshake pipeline flop. Resets with the fabric
    // (HRESETn) so the bus interface tracks the system bus reset.
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn)
            wr_en_q <= 1'b0;
        else
            wr_en_q <= addr_phase_wr;     // pipeline addr->data phase
    end

    // REMAP_CTRL storage (bootgate/remap bits). Reset on the STABLE PORESETn
    // only — NOT HRESETn — so the bootgate/remap value PERSISTS across a
    // manager-core (HRESETn) reset and the managed core is not re-gated.
    // write-1-set: bits only set, cleared by PORESETn (power-on / external
    // sys_sysresetn).
    always @(posedge HCLK or negedge PORESETn) begin
        if (!PORESETn)
            remap_q <= 4'b0000;          // power-on: BOOTROM at 0x0, managed core gated
        else if (wr_en_q)
            remap_q <= remap_q | HWDATA[3:0];
    end

    assign remap_ctrl = remap_q;
    assign HRDATA     = {28'b0, remap_q};
    assign HREADYOUT  = 1'b1;             // zero wait states
    assign HRESP      = 1'b0;             // always OKAY

endmodule
