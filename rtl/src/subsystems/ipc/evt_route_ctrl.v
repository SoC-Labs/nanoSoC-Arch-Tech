//-----------------------------------------------------------------------------
// evt_route_ctrl.v — Dynamic event-routing control register slave
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// A minimal AHB-Lite register slave (mirrors the cpu1_remap_ctrl.v recipe)
// that exposes per-destination-CPU bitmasks for the dynamic event-routing
// matrix. Each routable event source i (a DMA-230 done channel) can be
// independently steered to each CPU's NVIC DMA-done IRQ and/or each CPU's
// RXEV (WFE wake) by setting bit i in the relevant route register.
//
// Register map (word offsets decoded from HADDR, only the low N_SRC bits of
// each ROUTE register are writable; [31:N_SRC] read-as-zero / write-ignored):
//   +0x00  IRQ_ROUTE_CPU0  RW  reset 0x00000000  DMA-done -> CPU0 NVIC IRQ
//   +0x04  IRQ_ROUTE_CPU1  RW  reset 0x0000000F  DMA-done -> CPU1 NVIC IRQ
//                                                 (LOAD-BEARING: all DMA-done
//                                                  -> CPU1 / chip-control at reset)
//   +0x08  EVT_ROUTE_CPU0  RW  reset 0x00000000  DMA-done -> CPU0 RXEV
//   +0x0C  EVT_ROUTE_CPU1  RW  reset 0x00000000  DMA-done -> CPU1 RXEV
//   +0x10  ROUTE_LOCK      RW  reset 0x00000000  bit0 write-1-set: once 1, the
//                                                 four ROUTE registers become
//                                                 read-only until HRESETn.
//
//   Access semantics: the four ROUTE registers are plain RW (a write replaces
//   the value) so software can both grant and revoke a route — unlike
//   cpu1_remap_ctrl's write-1-set. ROUTE_LOCK bit0 is write-1-set so it can
//   only be raised (and is cleared only by system reset); while it is set the
//   four ROUTE registers ignore writes (anti-clobber).
//
// Mask outputs (consumed by the SoC AND/OR routing glue), flattened as
//   [cpu*N_SRC + src], so bits [3:0] = CPU0, [7:4] = CPU1 for N_SRC=4:
//   irq_route_mask = { IRQ_ROUTE_CPU1[N_SRC-1:0], IRQ_ROUTE_CPU0[N_SRC-1:0] }
//   evt_route_mask = { EVT_ROUTE_CPU1[N_SRC-1:0], EVT_ROUTE_CPU0[N_SRC-1:0] }
//
// Reads return the registered register value (1-cycle, like the template).
// Zero wait states (HREADYOUT held high), always OKAY response.
//-----------------------------------------------------------------------------

module evt_route_ctrl #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter N_SRC      = 4,
    parameter N_CPU      = 2
) (
    input  wire                   HCLK,
    input  wire                   HRESETn,

    // AHB-Lite slave (target) port — same port set as cpu1_remap_ctrl.v
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

    // Routing-mask outputs -> SoC AND/OR routing glue (flattened [cpu*N_SRC+src])
    output wire  [N_CPU*N_SRC-1:0] irq_route_mask,
    output wire  [N_CPU*N_SRC-1:0] evt_route_mask
);

    // Word-offset decode field. Five word registers => 3 address bits suffice.
    localparam ADDR_LSB = 2;            // word-aligned
    localparam ADDR_MSB = 4;            // covers offsets 0x00..0x1C

    // Register word offsets (HADDR[ADDR_MSB:ADDR_LSB]).
    localparam [2:0] OFF_IRQ_CPU0 = 3'h0;   // 0x00
    localparam [2:0] OFF_IRQ_CPU1 = 3'h1;   // 0x04
    localparam [2:0] OFF_EVT_CPU0 = 3'h2;   // 0x08
    localparam [2:0] OFF_EVT_CPU1 = 3'h3;   // 0x0C
    localparam [2:0] OFF_LOCK     = 3'h4;   // 0x10

    // Reset constant: all routable sources -> CPU1 IRQ at power-on.
    localparam [N_SRC-1:0] IRQ_CPU1_RST = {N_SRC{1'b1}};

    // Unused AHB qualifiers (word-only register slave, no bursts/locks).
    wire _unused = &{1'b0, HSIZE, HBURST, HPROT, HMASTLOCK};

    // Address-phase access request: selected, sequential/non-seq, bus ready.
    wire        addr_phase    = HSEL & HREADY & HTRANS[1];
    wire        addr_phase_wr = addr_phase & HWRITE;
    wire        addr_phase_rd = addr_phase & ~HWRITE;
    wire [2:0]  word_addr     = HADDR[ADDR_MSB:ADDR_LSB];

    // Pipeline address-phase -> data-phase (writes) / read-data registration.
    reg         wr_en_q;
    reg  [2:0]  wr_addr_q;
    reg  [2:0]  rd_addr_q;

    // Register storage (only low N_SRC bits of the route regs are meaningful).
    reg  [N_SRC-1:0] irq_route_cpu0_q;
    reg  [N_SRC-1:0] irq_route_cpu1_q;
    reg  [N_SRC-1:0] evt_route_cpu0_q;
    reg  [N_SRC-1:0] evt_route_cpu1_q;
    reg              route_lock_q;

    // Routes are frozen once ROUTE_LOCK bit0 is set.
    wire        route_wr_allowed = ~route_lock_q;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            wr_en_q          <= 1'b0;
            wr_addr_q        <= 3'h0;
            rd_addr_q        <= 3'h0;
            irq_route_cpu0_q <= {N_SRC{1'b0}};
            irq_route_cpu1_q <= IRQ_CPU1_RST;   // LOAD-BEARING: all DMA-done -> CPU1
            evt_route_cpu0_q <= {N_SRC{1'b0}};
            evt_route_cpu1_q <= {N_SRC{1'b0}};
            route_lock_q     <= 1'b0;
        end else begin
            // Capture address phase for the following data phase.
            wr_en_q   <= addr_phase_wr;
            wr_addr_q <= word_addr;
            // Register read address whenever a read is accepted (1-cycle read data).
            if (addr_phase_rd) begin
                rd_addr_q <= word_addr;
            end

            // Data-phase write: HWDATA is valid the cycle after the address phase.
            if (wr_en_q) begin
                case (wr_addr_q)
                    OFF_IRQ_CPU0: if (route_wr_allowed) irq_route_cpu0_q <= HWDATA[N_SRC-1:0];
                    OFF_IRQ_CPU1: if (route_wr_allowed) irq_route_cpu1_q <= HWDATA[N_SRC-1:0];
                    OFF_EVT_CPU0: if (route_wr_allowed) evt_route_cpu0_q <= HWDATA[N_SRC-1:0];
                    OFF_EVT_CPU1: if (route_wr_allowed) evt_route_cpu1_q <= HWDATA[N_SRC-1:0];
                    OFF_LOCK:     route_lock_q <= route_lock_q | HWDATA[0]; // bit0 write-1-set
                    default:      ; // unmapped offset: ignore
                endcase
            end
        end
    end

    // Registered read data mux (1-cycle latency, like the template).
    reg  [SYS_DATA_W-1:0] hrdata_q;
    always @(*) begin
        case (rd_addr_q)
            OFF_IRQ_CPU0: hrdata_q = {{(SYS_DATA_W-N_SRC){1'b0}}, irq_route_cpu0_q};
            OFF_IRQ_CPU1: hrdata_q = {{(SYS_DATA_W-N_SRC){1'b0}}, irq_route_cpu1_q};
            OFF_EVT_CPU0: hrdata_q = {{(SYS_DATA_W-N_SRC){1'b0}}, evt_route_cpu0_q};
            OFF_EVT_CPU1: hrdata_q = {{(SYS_DATA_W-N_SRC){1'b0}}, evt_route_cpu1_q};
            OFF_LOCK:     hrdata_q = {{(SYS_DATA_W-1){1'b0}}, route_lock_q};
            default:      hrdata_q = {SYS_DATA_W{1'b0}};
        endcase
    end

    // Flattened mask outputs: [cpu*N_SRC + src] -> CPU0 low, CPU1 high.
    assign irq_route_mask = {irq_route_cpu1_q, irq_route_cpu0_q};
    assign evt_route_mask = {evt_route_cpu1_q, evt_route_cpu0_q};

    assign HRDATA    = hrdata_q;
    assign HREADYOUT = 1'b1;             // zero wait states
    assign HRESP     = 1'b0;             // always OKAY

endmodule
