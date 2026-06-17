//-----------------------------------------------------------------------------
// nanosoc_reset_ctrl.v — NanoSoC per-core reset controller
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Adapted from nanosoc_sysctrl.v (itself adapted from the Arm CMSDK System
// Controller, (C) COPYRIGHT 2010-2013 Arm Limited or its affiliates).
// The AHB address/data-phase handshake, byte-strobe write generation, read
// multiplexer, PID/CID identification ROM and the W1C RESET_INFO capture flop
// style are reused VERBATIM from nanosoc_sysctrl.v where possible, then
// extended to two cores with reset aggregation and an FCLK pulse-stretcher.
//-----------------------------------------------------------------------------
// A single addressable AHB-Lite slave that is BOTH a register block AND a
// per-core reset generator for the dual-core (CPU0 / CPU1) NanoSoC.
//
// Programmer's model (12-bit decode on HADDR[11:0]):
//   0x008 RW   SYS_CTRL
//      bit [0]  LOCKUPRESETEN  - enable lockup->reset for BOTH cores
//   0x010 W1C  RESET_INFO_CPU0
//      bit [0]  SYSRESETREQ
//      bit [2]  LOCKUPRESET
//      bit [3]  EXTRESET
//   0x014 W1C  RESET_INFO_CPU1
//      bit [0]  SYSRESETREQ
//      bit [1]  WDOGRESETREQ
//      bit [2]  LOCKUPRESET
//      bit [3]  EXTRESET
//   0x020 W    SW_RESET  (self-clearing, reads back 0)
//      bit [0]  CPU0_SWRST - one-shot software reset of CPU0
//      bit [1]  CPU1_SWRST - one-shot software reset of CPU1
//   0x000 RO   REMAP_CTRL  - reserved (parity with nanosoc_sysctrl, RAZ)
//   0x004 RO   PMU_CTRL    - reserved (parity with nanosoc_sysctrl, RAZ)
//   0xFD0..0xFFC RO  PID4..PID3 / CID0..CID3 identification ROM
//
// Reset generation (combinational request + clocked N-cycle pulse stretch on
// FCLK). The stretch / capture flops are async-reset on ~PORESETn (power-on)
// because this module is not wired the system reset directly; external reset
// reaches the cores via the top level.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_reset_ctrl #(
  parameter SYS_ADDR_W    = 32,
  parameter SYS_DATA_W    = 32,
  parameter RESET_STRETCH = 8     // active-high reset pulse length, FCLK cycles
) (
  // Clocks / resets
  input  wire                   HCLK,         // AHB system bus clock
  input  wire                   HRESETn,      // AHB system bus reset (active low)
  input  wire                   FCLK,         // free-running clock (stretch/capture)
  input  wire                   PORESETn,     // power-on reset (active low)

  // AHB-Lite target bundle (subset matching cpu1_remap_ctrl.v)
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

  // Sideband reset-source inputs (active-high level/pulse)
  input  wire                   cpu0_sysresetreq,
  input  wire                   cpu1_sysresetreq,
  input  wire                   cpu1_wdogresetreq,
  input  wire                   cpu0_lockup,
  input  wire                   cpu1_lockup,
  input  wire                   ext_sysresetreq,
  input  wire                   cpu1_bootgate,

  // Per-core reset outputs (active-low)
  output wire                   cpu0_resetn,
  output wire                   cpu1_resetn
);

  // --------------------------------------------------------------------------
  // Identification ROM (reused verbatim from nanosoc_sysctrl.v)
  // --------------------------------------------------------------------------
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID4 = 32'h00000004; // 0xFD0 : PID 4
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID5 = 32'h00000000; // 0xFD4 : PID 5
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID6 = 32'h00000000; // 0xFD8 : PID 6
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID7 = 32'h00000000; // 0xFDC : PID 7
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID0 = 32'h00000026; // 0xFE0 : PID 0
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID1 = 32'h000000B8; // 0xFE4 : PID 1
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID2 = 32'h0000001B; // 0xFE8 : PID 2
  localparam  ARM_CMSDK_CM0_SYSCTRL_PID3 = 32'h00000000; // 0xFEC : PID 3
  localparam  ARM_CMSDK_CM0_SYSCTRL_CID0 = 32'h0000000D; // 0xFF0 : CID 0
  localparam  ARM_CMSDK_CM0_SYSCTRL_CID1 = 32'h000000F0; // 0xFF4 : CID 1
  localparam  ARM_CMSDK_CM0_SYSCTRL_CID2 = 32'h00000005; // 0xFF8 : CID 2
  localparam  ARM_CMSDK_CM0_SYSCTRL_CID3 = 32'h000000B1; // 0xFFC : CID 3

  // --------------------------------------------------------------------------
  // Internal registers / wires
  // --------------------------------------------------------------------------
  reg    [31:0] read_mux;
  reg           reg_lockupreset;     // SYS_CTRL[0] LOCKUPRESETEN
  reg    [3:0]  reg_resetinfo_cpu0;  // RESET_INFO_CPU0 (W1C)
  reg    [3:0]  reg_resetinfo_cpu1;  // RESET_INFO_CPU1 (W1C)

  // Unused AHB qualifiers (kept on the port list for generator/AHB parity).
  wire _unused = &{1'b0, HBURST, HPROT, HMASTLOCK};

  // --------------------------------------------------------------------------
  // AHB address/data-phase handshake + byte strobes
  // (reused verbatim from nanosoc_sysctrl.v)
  // --------------------------------------------------------------------------
  wire         ahb_access  = HTRANS[1] & HSEL & HREADY;
  wire         ahb_write   = ahb_access &   HWRITE;
  wire         ahb_read    = ahb_access & (~HWRITE);
  wire  [3:0]  nxt_byte_strobe;
  reg   [3:0]  reg_byte_strobe;
  reg          reg_read_enable;
  reg          reg_write_enable;
  reg   [11:2] reg_addr;

  // Byte strobes to support sub-word transfers
  assign nxt_byte_strobe[0] = (HSIZE[1] | ((HADDR[1] == 1'b0) & HSIZE[0]) | (HADDR[1:0] == 2'b00)) & ahb_access;
  assign nxt_byte_strobe[1] = (HSIZE[1] | ((HADDR[1] == 1'b0) & HSIZE[0]) | (HADDR[1:0] == 2'b01)) & ahb_access;
  assign nxt_byte_strobe[2] = (HSIZE[1] | ((HADDR[1] == 1'b1) & HSIZE[0]) | (HADDR[1:0] == 2'b10)) & ahb_access;
  assign nxt_byte_strobe[3] = (HSIZE[1] | ((HADDR[1] == 1'b1) & HSIZE[0]) | (HADDR[1:0] == 2'b11)) & ahb_access;

  // Data-phase read/write enables and byte lane strobe
  always @(posedge HCLK or negedge HRESETn) begin
    if (~HRESETn) begin
      reg_byte_strobe  <= 4'b0000;
      reg_read_enable  <= 1'b0;
      reg_write_enable <= 1'b0;
    end else if (HREADY) begin
      reg_byte_strobe  <= nxt_byte_strobe;
      reg_read_enable  <= ahb_read;
      reg_write_enable <= ahb_write;
    end
  end

  // Registered address (only [11:2] decoded), update only if selected
  always @(posedge HCLK or negedge HRESETn) begin
    if (~HRESETn)
      reg_addr <= {10{1'b0}};
    else if (ahb_access)
      reg_addr <= HADDR[11:2];
  end

  // --------------------------------------------------------------------------
  // Read multiplexer (structure reused from nanosoc_sysctrl.v)
  // --------------------------------------------------------------------------
  always @(reg_addr or reg_lockupreset or reg_resetinfo_cpu0 or
           reg_resetinfo_cpu1 or reg_read_enable) begin
    case (reg_read_enable)
      1'b1: begin
        if (reg_addr[11:5] == 7'h00) begin
          case (reg_addr[4:2])
            3'b000: read_mux = {32{1'b0}};                       // 0x000 REMAP_CTRL (reserved, RAZ)
            3'b001: read_mux = {32{1'b0}};                       // 0x004 PMU_CTRL   (reserved, RAZ)
            3'b010: read_mux = {{31{1'b0}}, reg_lockupreset};    // 0x008 SYS_CTRL
            3'b100: read_mux = {{28{1'b0}}, reg_resetinfo_cpu0}; // 0x010 RESET_INFO_CPU0
            3'b101: read_mux = {{28{1'b0}}, reg_resetinfo_cpu1}; // 0x014 RESET_INFO_CPU1
            // 0x018 (110), 0x01C (111), 0x00C (011): unmapped -> RAZ
            3'b011, 3'b110, 3'b111: read_mux = {32{1'b0}};
            default: read_mux = {32{1'bx}};
          endcase
        end else if (reg_addr[11:6] == 6'h3F) begin
          case (reg_addr[5:2])
            4'h4: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID4; // 0xFD0
            4'h5: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID5; // 0xFD4
            4'h6: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID6; // 0xFD8
            4'h7: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID7; // 0xFDC
            4'h8: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID0; // 0xFE0
            4'h9: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID1; // 0xFE4
            4'hA: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID2; // 0xFE8
            4'hB: read_mux = ARM_CMSDK_CM0_SYSCTRL_PID3; // 0xFEC
            4'hC: read_mux = ARM_CMSDK_CM0_SYSCTRL_CID0; // 0xFF0
            4'hD: read_mux = ARM_CMSDK_CM0_SYSCTRL_CID1; // 0xFF4
            4'hE: read_mux = ARM_CMSDK_CM0_SYSCTRL_CID2; // 0xFF8
            4'hF: read_mux = ARM_CMSDK_CM0_SYSCTRL_CID3; // 0xFFC
            4'h0, 4'h1, 4'h2, 4'h3: read_mux = {32{1'b0}};
            default: read_mux = {32{1'bx}};
          endcase
        end else begin
          read_mux = {32{1'b0}};
        end
      end
      1'b0:    read_mux = {32{1'b0}}; // read_enable not active
      default: read_mux = {32{1'bx}};
    endcase
  end

  // --------------------------------------------------------------------------
  // SYS_CTRL[0] LOCKUPRESETEN register (0x008)
  // (reused from nanosoc_sysctrl LOCKUPRESETEN register)
  // --------------------------------------------------------------------------
  wire reg_lockupreset_write;
  assign reg_lockupreset_write = reg_write_enable &
                                 (reg_addr[11:2] == 10'h002) & reg_byte_strobe[0];

  // Persist LOCKUPRESETEN across a CPU0/fabric HRESETn dip: clock on FCLK and
  // async-clear only on PORESETn, matching the RESET_INFO capture domain below.
  // On HRESETn it would disarm on every CPU0/external reset, silently dropping
  // lockup protection exactly when it is needed. The write enable/data are the
  // same HCLK-domain signals the RESET_INFO captures already sample into FCLK.
  always @(posedge FCLK or negedge PORESETn) begin
    if (~PORESETn)
      reg_lockupreset <= 1'b0;
    else if (reg_lockupreset_write)
      reg_lockupreset <= HWDATA[0];
  end

  wire lockupreseten = reg_lockupreset;

  // --------------------------------------------------------------------------
  // SW_RESET (0x020) — write-1 generates a one-shot pulse, reads back 0.
  // --------------------------------------------------------------------------
  wire reg_swreset_write;
  assign reg_swreset_write = reg_write_enable &
                             (reg_addr[11:2] == 10'h008) & reg_byte_strobe[0];

  // One-shot software reset request pulses (single HCLK cycle)
  reg  cpu0_swreset_pulse;
  reg  cpu1_swreset_pulse;

  always @(posedge HCLK or negedge HRESETn) begin
    if (~HRESETn) begin
      cpu0_swreset_pulse <= 1'b0;
      cpu1_swreset_pulse <= 1'b0;
    end else begin
      // self-clearing: asserted only in the cycle of the write
      cpu0_swreset_pulse <= reg_swreset_write & HWDATA[0];
      cpu1_swreset_pulse <= reg_swreset_write & HWDATA[1];
    end
  end

  // --------------------------------------------------------------------------
  // Per-core reset aggregation (combinational request)
  // --------------------------------------------------------------------------
  wire cpu0_reset_req = cpu0_sysresetreq
                      | (cpu0_lockup & lockupreseten)
                      |  cpu0_swreset_pulse
                      |  ext_sysresetreq;

  wire cpu1_reset_req = cpu1_sysresetreq
                      | (cpu1_lockup & lockupreseten)
                      |  cpu1_wdogresetreq
                      |  cpu1_swreset_pulse
                      |  ext_sysresetreq;

  // --------------------------------------------------------------------------
  // FCLK pulse stretcher — turn each request into an N-cycle active-high pulse.
  // Counter-based, RESET_STRETCH cycles. Async-reset on ~PORESETn.
  // --------------------------------------------------------------------------
  // NB: width must hold the reload value RESET_STRETCH itself (not just
  // RESET_STRETCH-1), so size from (RESET_STRETCH+1). With RESET_STRETCH=8 this
  // gives CNT_W=4 and the reload 8[3:0]=8 (a $clog2(8)=3 width would wrap 8->0
  // and the pulse would never stretch).
  localparam CNT_W = (RESET_STRETCH <= 1) ? 1 : $clog2(RESET_STRETCH + 1);

  reg  [CNT_W-1:0] cpu0_stretch_cnt;
  reg  [CNT_W-1:0] cpu1_stretch_cnt;
  reg              cpu0_reset_pulse;
  reg              cpu1_reset_pulse;

  // CPU0 stretcher
  always @(posedge FCLK or negedge PORESETn) begin
    if (~PORESETn) begin
      cpu0_stretch_cnt <= {CNT_W{1'b0}};
      cpu0_reset_pulse <= 1'b0;
    end else if (cpu0_reset_req) begin
      // (re)trigger: assert pulse and reload the countdown
      cpu0_stretch_cnt <= RESET_STRETCH[CNT_W-1:0];
      cpu0_reset_pulse <= 1'b1;
    end else if (cpu0_stretch_cnt != {CNT_W{1'b0}}) begin
      cpu0_stretch_cnt <= cpu0_stretch_cnt - 1'b1;
      cpu0_reset_pulse <= 1'b1;
    end else begin
      cpu0_reset_pulse <= 1'b0;
    end
  end

  // CPU1 stretcher
  always @(posedge FCLK or negedge PORESETn) begin
    if (~PORESETn) begin
      cpu1_stretch_cnt <= {CNT_W{1'b0}};
      cpu1_reset_pulse <= 1'b0;
    end else if (cpu1_reset_req) begin
      cpu1_stretch_cnt <= RESET_STRETCH[CNT_W-1:0];
      cpu1_reset_pulse <= 1'b1;
    end else if (cpu1_stretch_cnt != {CNT_W{1'b0}}) begin
      cpu1_stretch_cnt <= cpu1_stretch_cnt - 1'b1;
      cpu1_reset_pulse <= 1'b1;
    end else begin
      cpu1_reset_pulse <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // RESET_INFO capture (W1C) — mirrors nanosoc_sysctrl RSTINFO capture,
  // extended per-core, on FCLK, async-clear on PORESETn.
  // --------------------------------------------------------------------------
  wire reg_resetinfo_cpu0_write;
  wire reg_resetinfo_cpu1_write;
  assign reg_resetinfo_cpu0_write = reg_write_enable &
                                    (reg_addr[11:2] == 10'h004) & reg_byte_strobe[0];
  assign reg_resetinfo_cpu1_write = reg_write_enable &
                                    (reg_addr[11:2] == 10'h005) & reg_byte_strobe[0];

  // ---- CPU0 cause capture ----
  // bit[0] SYSRESETREQ, bit[2] LOCKUPRESET, bit[3] EXTRESET  (bit[1] unused)
  wire [3:0] nxt_resetinfo_cpu0;
  assign nxt_resetinfo_cpu0[0] = ((~(reg_resetinfo_cpu0_write & HWDATA[0])) & reg_resetinfo_cpu0[0]) | cpu0_sysresetreq;
  assign nxt_resetinfo_cpu0[1] = 1'b0;
  assign nxt_resetinfo_cpu0[2] = ((~(reg_resetinfo_cpu0_write & HWDATA[2])) & reg_resetinfo_cpu0[2]) | (cpu0_lockup & lockupreseten);
  assign nxt_resetinfo_cpu0[3] = ((~(reg_resetinfo_cpu0_write & HWDATA[3])) & reg_resetinfo_cpu0[3]) | ext_sysresetreq;

  wire reg_resetinfo_cpu0_en = reg_resetinfo_cpu0_write | cpu0_sysresetreq |
                               (cpu0_lockup & lockupreseten) | ext_sysresetreq;

  always @(posedge FCLK or negedge PORESETn) begin
    if (~PORESETn)
      reg_resetinfo_cpu0 <= 4'b0000;
    else if (reg_resetinfo_cpu0_en)
      reg_resetinfo_cpu0 <= nxt_resetinfo_cpu0;
  end

  // ---- CPU1 cause capture ----
  // bit[0] SYSRESETREQ, bit[1] WDOGRESETREQ, bit[2] LOCKUPRESET, bit[3] EXTRESET
  wire [3:0] nxt_resetinfo_cpu1;
  assign nxt_resetinfo_cpu1[0] = ((~(reg_resetinfo_cpu1_write & HWDATA[0])) & reg_resetinfo_cpu1[0]) | cpu1_sysresetreq;
  assign nxt_resetinfo_cpu1[1] = ((~(reg_resetinfo_cpu1_write & HWDATA[1])) & reg_resetinfo_cpu1[1]) | cpu1_wdogresetreq;
  assign nxt_resetinfo_cpu1[2] = ((~(reg_resetinfo_cpu1_write & HWDATA[2])) & reg_resetinfo_cpu1[2]) | (cpu1_lockup & lockupreseten);
  assign nxt_resetinfo_cpu1[3] = ((~(reg_resetinfo_cpu1_write & HWDATA[3])) & reg_resetinfo_cpu1[3]) | ext_sysresetreq;

  wire reg_resetinfo_cpu1_en = reg_resetinfo_cpu1_write | cpu1_sysresetreq | cpu1_wdogresetreq |
                               (cpu1_lockup & lockupreseten) | ext_sysresetreq;

  always @(posedge FCLK or negedge PORESETn) begin
    if (~PORESETn)
      reg_resetinfo_cpu1 <= 4'b0000;
    else if (reg_resetinfo_cpu1_en)
      reg_resetinfo_cpu1 <= nxt_resetinfo_cpu1;
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  // Active-low core resets. cpu1_bootgate folded in: bootgate=0 holds CPU1 in
  // reset (drives cpu1_resetn low) regardless of the stretcher state.
  assign cpu0_resetn = ~cpu0_reset_pulse;
  assign cpu1_resetn = cpu1_bootgate & ~cpu1_reset_pulse;

  // AHB response
  assign HREADYOUT = 1'b1;   // zero wait states
  assign HRDATA    = read_mux;
  assign HRESP     = 1'b0;   // always OKAY

endmodule
