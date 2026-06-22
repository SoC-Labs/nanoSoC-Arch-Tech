//-----------------------------------------------------------------------------
// hw_spinlock.v — Hardware spinlock block (address-aliased acquire)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// RP2040-SIO-style hardware mutexes for cross-core mutual exclusion, so that
// correctness no longer depends on AHB-matrix arbitration corner cases (the
// IPC back-to-back-write wedge class of bug). Copies the evt_route_ctrl.v
// zero-wait AHB-Lite register-slave idiom (addr_phase -> data_phase pipeline,
// registered read mux, HREADYOUT=1, HRESP=0).
//
// DESIGN — address-aliased acquire. The generated AHB matrix presents no
// requester-ID to slaves, so the requester is selected by ADDRESS instead:
// three alias pages map the same N_LOCKS locks, one page per requester.
//
//   Page (HADDR[9:8])   requester
//     0x000 (00)        CPU0
//     0x100 (01)        CPU1
//     0x200 (10)        DBG  (the DAP / bench scripts / loader)
//
// Each lock n is a single bit with a 2-bit owner code:
//     2'b00 free   2'b01 CPU0   2'b10 CPU1   2'b11 DBG
//
//   0x000 + n*4  LOCKn_CPU0  READ  = attempt acquire as CPU0 (READ SIDE-EFFECT)
//                                    -> returns 1 if this read acquired the lock
//                                       OR it was already owned by CPU0,
//                                       returns 0 if held by another owner.
//                            WRITE = release iff current owner == CPU0 (any data)
//   0x100 + n*4  LOCKn_CPU1  same, requester CPU1
//   0x200 + n*4  LOCKn_DBG   same, requester DBG
//
//   0x300  OWNER          RO  2 bits/lock packed: lock0 in [1:0], lock1 in
//                             [3:2], ... up to 16 locks = 32 bits. Pure
//                             diagnostics, NO side effect.
//   0x304  FORCE_RELEASE  WO  write bit n force-frees lock n (recovery path).
//
// Acquire semantics (read of an alias page in [0x000,0x200], lock n):
//   - lock free            -> set owner = requester, return 1
//   - owner == requester   -> return 1 (re-entrant read is harmless)
//   - owner == other       -> return 0, owner unchanged
//
// The acquire is a single zero-wait AHB read, so it is immune to the multi-beat
// write-contention behaviour behind the IPC wedge. The read SIDE-EFFECT must
// fire exactly once per accepted read address phase, in the data phase — this
// mirrors how evt_route pipelines wr_en_q/wr_addr_q for writes, but applied to
// the read path (acq_en_q/acq_lock_q/acq_req_q). It is cooperative (CPU0 could
// read CPU1's alias) — fine for trusted firmware; noted in the register map.
//
// Reset auto-release: cpu0_resetn / cpu1_resetn (active-low, from
// u_reset_ctrl_0). When cpu0_resetn asserts (goes low) every lock currently
// owned by CPU0 is freed; same for cpu1_resetn / CPU1. This stops a core that
// died holding a lock from wedging the other. All locks free at HRESETn.
//
// Zero wait states (HREADYOUT held high), always OKAY response.
//-----------------------------------------------------------------------------

module hw_spinlock #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter N_LOCKS    = 16
) (
    input  wire                   HCLK,
    input  wire                   HRESETn,

    // AHB-Lite slave (target) port — same port set as evt_route_ctrl.v
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

    // Per-core reset auto-release strobes (active-low, from u_reset_ctrl_0).
    input  wire                   cpu0_resetn,
    input  wire                   cpu1_resetn
);

    // Owner codes.
    localparam [1:0] OWN_FREE = 2'b00;
    localparam [1:0] OWN_CPU0 = 2'b01;
    localparam [1:0] OWN_CPU1 = 2'b10;
    localparam [1:0] OWN_DBG  = 2'b11;

    // Address decode. Word-aligned; lock index in HADDR[ADDR_MSB:2], requester
    // page in HADDR[9:8]. The diagnostic block (OWNER/FORCE_RELEASE) lives at
    // page 0x300 (HADDR[9:8]==2'b11) and is selected by HADDR[2] within it.
    localparam ADDR_LSB = 2;                       // word-aligned
    localparam IDX_W    = (N_LOCKS <= 1) ? 1 : $clog2(N_LOCKS);
    localparam IDX_MSB  = ADDR_LSB + IDX_W - 1;    // top bit of the lock index

    localparam [1:0] PAGE_CPU0 = 2'b00;            // 0x000
    localparam [1:0] PAGE_CPU1 = 2'b01;            // 0x100
    localparam [1:0] PAGE_DBG  = 2'b10;            // 0x200
    localparam [1:0] PAGE_DIAG = 2'b11;            // 0x300 (OWNER / FORCE_RELEASE)

    // Unused AHB qualifiers (word-only register slave, no bursts/locks).
    wire _unused = &{1'b0, HSIZE, HBURST, HPROT, HMASTLOCK};

    // Address-phase access request: selected, sequential/non-seq, bus ready.
    wire        addr_phase    = HSEL & HREADY & HTRANS[1];
    wire        addr_phase_wr = addr_phase &  HWRITE;
    wire        addr_phase_rd = addr_phase & ~HWRITE;

    wire [1:0]  page          = HADDR[9:8];
    wire [IDX_W-1:0] lock_idx  = HADDR[IDX_MSB:ADDR_LSB];
    wire        diag_force     = HADDR[2];          // within DIAG page: 1 => 0x304

    // Map a requester page to its owner code (only valid for the 3 acquire pages).
    function [1:0] page_owner;
        input [1:0] p;
        begin
            case (p)
                PAGE_CPU0: page_owner = OWN_CPU0;
                PAGE_CPU1: page_owner = OWN_CPU1;
                default:   page_owner = OWN_DBG;   // PAGE_DBG
            endcase
        end
    endfunction

    // Lock owner storage.
    reg [1:0] owner_q [0:N_LOCKS-1];

    integer i;

    // ---- Address-phase -> data-phase pipeline ---------------------------
    // Writes (release / force-release) act in the data phase, exactly like
    // evt_route. Reads with an acquire side-effect are pipelined the same way:
    // capture {lock, requester, is-acquire-page} at the accepted read address
    // phase, then fire the acquire once in the following data phase.
    reg                acq_en_q;        // an acquire read was accepted
    reg [IDX_W-1:0]    acq_lock_q;
    reg [1:0]          acq_req_q;       // requester owner code for that read

    reg                wr_en_q;
    reg [IDX_W-1:0]    wr_lock_q;
    reg [1:0]          wr_page_q;
    reg                wr_diag_q;
    reg                wr_force_q;

    // Read-data registration: what to return in the data phase.
    reg                rd_en_q;
    reg [1:0]          rd_page_q;
    reg [IDX_W-1:0]    rd_lock_q;

    wire is_acquire_page = (page == PAGE_CPU0) ||
                           (page == PAGE_CPU1) ||
                           (page == PAGE_DBG);

    // Acquire is accepted only for a read to one of the 3 requester pages.
    wire acq_accept = addr_phase_rd & is_acquire_page;

    // Combinational view of the acquire result for the read captured last
    // cycle (acq_*_q): 1 if owned-by-requester after this acquire resolves.
    wire acquire_hit = (owner_q[acq_lock_q] == OWN_FREE) ||
                       (owner_q[acq_lock_q] == acq_req_q);

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            acq_en_q   <= 1'b0;
            acq_lock_q <= {IDX_W{1'b0}};
            acq_req_q  <= OWN_FREE;
            wr_en_q    <= 1'b0;
            wr_lock_q  <= {IDX_W{1'b0}};
            wr_page_q  <= 2'b00;
            wr_diag_q  <= 1'b0;
            wr_force_q <= 1'b0;
            rd_en_q    <= 1'b0;
            rd_page_q  <= 2'b00;
            rd_lock_q  <= {IDX_W{1'b0}};
            for (i = 0; i < N_LOCKS; i = i + 1)
                owner_q[i] <= OWN_FREE;
        end else begin
            // Capture the accepted address phase for the following data phase.
            acq_en_q   <= acq_accept;
            acq_lock_q <= lock_idx;
            acq_req_q  <= page_owner(page);

            wr_en_q    <= addr_phase_wr;
            wr_lock_q  <= lock_idx;
            wr_page_q  <= page;
            wr_diag_q  <= (page == PAGE_DIAG);
            wr_force_q <= diag_force;       // within DIAG page: HADDR[2]=1 => FORCE_RELEASE

            rd_en_q    <= addr_phase_rd;
            rd_page_q  <= page;
            rd_lock_q  <= lock_idx;

            // --- Read side-effect: acquire (fires once, in the data phase) ---
            if (acq_en_q) begin
                if (owner_q[acq_lock_q] == OWN_FREE)
                    owner_q[acq_lock_q] <= acq_req_q;   // grant to first reader
                // owner == requester  -> re-entrant, leave unchanged
                // owner == other       -> contention, leave unchanged
            end

            // --- Write side-effect: release / force-release (data phase) -----
            if (wr_en_q) begin
                if (wr_diag_q) begin
                    if (wr_force_q) begin
                        // FORCE_RELEASE (0x304): write bit n frees lock n.
                        // HWDATA is valid in this (data) phase, like evt_route.
                        for (i = 0; i < N_LOCKS; i = i + 1)
                            if (HWDATA[i])
                                owner_q[i] <= OWN_FREE;
                    end
                    // OWNER (0x300) is RO: writes ignored.
                end else begin
                    // Release page: free iff current owner == requesting page.
                    if (owner_q[wr_lock_q] == page_owner(wr_page_q))
                        owner_q[wr_lock_q] <= OWN_FREE;
                end
            end

            // --- Reset auto-release (active-low, level-triggered while low) ---
            // Frees every lock owned by a core whose reset is asserted. Takes
            // priority each cycle; safe to coincide with acquire/release.
            for (i = 0; i < N_LOCKS; i = i + 1) begin
                if (!cpu0_resetn && (owner_q[i] == OWN_CPU0))
                    owner_q[i] <= OWN_FREE;
                if (!cpu1_resetn && (owner_q[i] == OWN_CPU1))
                    owner_q[i] <= OWN_FREE;
            end
        end
    end

    // ---- OWNER diagnostic word: 2 bits/lock, lock0 in [1:0] ----------------
    wire [SYS_DATA_W-1:0] owner_word;
    genvar g;
    generate
        for (g = 0; g < N_LOCKS; g = g + 1) begin : g_owner
            assign owner_word[2*g +: 2] = owner_q[g];
        end
        // Zero-fill the high bits when 2*N_LOCKS < SYS_DATA_W.
        if (2*N_LOCKS < SYS_DATA_W) begin : g_owner_pad
            assign owner_word[SYS_DATA_W-1 : 2*N_LOCKS] = {(SYS_DATA_W-2*N_LOCKS){1'b0}};
        end
    endgenerate

    // ---- Registered read-data mux (1-cycle latency, like the template) -----
    // For an acquire-page read, return the acquire result computed from the
    // pipelined address (acquire_hit), zero-extended. For the DIAG page return
    // OWNER (FORCE_RELEASE is WO -> reads 0). Anything else reads 0.
    reg  [SYS_DATA_W-1:0] hrdata_q;
    always @(*) begin
        if (rd_en_q) begin
            case (rd_page_q)
                PAGE_CPU0,
                PAGE_CPU1,
                PAGE_DBG: hrdata_q = {{(SYS_DATA_W-1){1'b0}}, acquire_hit};
                PAGE_DIAG: begin
                    // 0x300 OWNER (HADDR[2]==0) returns the packed owner word;
                    // 0x304 FORCE_RELEASE (WO) reads 0. rd_lock_q[0] mirrors
                    // HADDR[2] for these word offsets.
                    hrdata_q = (rd_lock_q[0]) ? {SYS_DATA_W{1'b0}} : owner_word;
                end
                default:   hrdata_q = {SYS_DATA_W{1'b0}};
            endcase
        end else begin
            hrdata_q = {SYS_DATA_W{1'b0}};
        end
    end

    assign HRDATA    = hrdata_q;
    assign HREADYOUT = 1'b1;             // zero wait states
    assign HRESP     = 1'b0;             // always OKAY

endmodule
