//-----------------------------------------------------------------------------
// NanoSoC Core
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// Daniel Newbrook (d.newbrook@soton.ac.uk)
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module nanosoc #(
    // System Parameters
    parameter          SYS_ADDR_W           = 32,         // System Address Width
    parameter          SYS_DATA_W           = 32,         // System Data Width

    // Widths of System Peripheral APB Subsystem
    parameter          APB_ADDR_W           = 12,         // APB Peripheral Address Width
    parameter          APB_DATA_W           = 32,         // APB Peripheral Data Width

    // DMA Parameters
    parameter          DMAC_0_TYPE          = 0,          // DMAC 0 Controller Type: 0=None, 1=PL230, 2=DMA350
    parameter          DMAC_1_TYPE          = 0,          // DMAC 1 Controller Type: 0=None, 1=PL230
    parameter          DMAC_0_CHANNEL_NUM   = 4,          // DMAC 0 Number of DMA Channels
    parameter          DMAC_1_CHANNEL_NUM   = 2,          // DMAC 1 Number of DMA Channels

    // Bootrom 0 Parameters
    parameter          BOOTROM_ADDR_W       = 11,         // Size of Bootrom (Based on Address Width) - Default 2KB

    // IMEM 0 Parameters
    parameter          IMEM_RAM_ADDR_W      = 14,         // Width of IMEM RAM Address - Default 16KB
    parameter          IMEM_RAM_DATA_W      = 32,         // Width of IMEM RAM Data Bus - Default 32 bits
    parameter          IMEM_MEM_FPGA_IMG    = "image.hex", // Image to Preload into SRAM

    // DMEM 0 Parameters
    parameter          DMEM_RAM_ADDR_W      = 14,         // Width of DMEM RAM Address - Default 16KB
    parameter          DMEM_RAM_DATA_W      = 32,         // Width of DMEM RAM Data Bus - Default 32 bits

    // Expansion SRAM Low Parameters
    parameter          SRAM_0_RAM_ADDR_W  = 14,         // Width of ExpRAM Low RAM Address - Default 16KB
    parameter          SRAM_0_RAM_DATA_W  = 32,         // Width of ExpRAM Low RAM Data Bus - Default 32 bits

    // Expansion SRAM High Parameters
    parameter          SRAM_1_RAM_ADDR_W  = 14,         // Width of ExpRAM High RAM Address - Default 16KB
    parameter          SRAM_1_RAM_DATA_W  = 32,         // Width of ExpRAM High RAM Data Bus - Default 32 bits

    // CPU Parameters
    parameter          CLKGATE_PRESENT      = 0,          // Clock gating present
    parameter          BE                   = 0,          // 1: Big endian 0: little endian
    parameter          BKPT                 = 4,          // Number of breakpoint comparators
    parameter          DBG                  = 1,          // Debug configuration
    parameter          NUMIRQ               = 32,         // Number of IRQs
    parameter          SMUL                 = 0,          // Multiplier configuration
    parameter          SYST                 = 1,          // SysTick
    parameter          WIC                  = 1,          // Wake-up interrupt controller support
    parameter          WICLINES             = 34,         // Supported WIC lines
    parameter          WPT                  = 2,          // Number of DWT comparators
    parameter          RESET_ALL_REGS       = 1,          // Do not reset all registers
    parameter          INCLUDE_JTAG         = 0,          // Do not Include JTAG feature

    // SoCDebug Parameters
    parameter          PROMPT_CHAR          = "]",        // SoCDebug prompt character
    parameter integer  FT1248_WIDTH         = 1,          // FTDI Interface 1,2,4 width supported
    parameter integer  FT1248_CLKON         = 1,          // FTDI clock always on - else quiet when no access
    parameter [7:0]    FT1248_CLKDIV        = 8'd15,      // Clock Division Ratio (4x4 for RP-PIO)

    // Address of System ROM Table
    parameter          SYSTABLE_BASE        = 32'hF000_0000, // Base Address of System ROM Table

    // SoCLabs Manufacture ID
    parameter          SOCLABS_JEPID        = 7'h51,      // SL (SoCLabs)

    // NanoSoC Part and Revision Numbers
    parameter          NANOSOC_PARTNUMBER   = 12'h001,    // NanoSoC part number
    parameter          NANOSOC_REVISION     = 4'h1        // NanoSoC revision
) (
    // Free-running and Crystal Clock Output
    input  wire                     sys_clk,              // System Input Clock
    input  wire                     sys_sysresetn,        // System Reset
    output wire                     sys_xtalclk_out,      // Crystal Clock Output

    // Scan Wiring
    input  wire                     sys_scanenable,       // Scan Mode Enable
    input  wire                     sys_testmode,         // Test Mode Enable (Override Synchronisers)
    input  wire                     sys_scaninhclk,       // HCLK scan input
    output wire                     sys_scanouthclk,      // Scan Chain Output

    // Serial-Wire Debug
    input  wire                     cpu_0_swdi,           // SWD data input
    input  wire                     cpu_0_swclk,          // SWD clock
    output wire                     cpu_0_swdo,           // SWD data output
    output wire                     cpu_0_swdoen,         // SWD data output enable

    // GPIO
    input  wire              [15:0] p0_in,                // GPIO 0 inputs
    output wire              [15:0] p0_out,               // GPIO 0 outputs
    output wire              [15:0] p0_outen,             // GPIO 0 output enables
    input  wire              [15:0] p1_in,                // GPIO 1 inputs
    output wire              [15:0] p1_out,               // GPIO 1 outputs
    output wire              [15:0] p1_outen,             // GPIO 1 output enables

    // Generated AHB clock and reset (for expansion subsystem)
    output wire                     sys_hclk,             // AHB Clock
    output wire                     sys_hresetn,          // AHB Reset

    // Expansion Region AHB Port
    output wire                     exp_hsel,             // AHB select
    output wire  [SYS_ADDR_W-1:0]   exp_haddr,            // AHB address
    output wire             [1:0]   exp_htrans,           // AHB transfer type
    output wire             [2:0]   exp_hsize,            // AHB transfer size
    output wire             [3:0]   exp_hprot,            // AHB protection
    output wire                     exp_hwrite,           // AHB write enable
    output wire                     exp_hready,           // AHB ready
    output wire  [SYS_DATA_W-1:0]   exp_hwdata,           // AHB write data
    output wire             [2:0]   exp_hburst,           // AHB burst type
    output wire                     exp_hmastlock,        // AHB master lock
    input  wire                     exp_hreadyout,        // AHB ready out
    input  wire                     exp_hresp,            // AHB response
    input  wire  [SYS_DATA_W-1:0]   exp_hrdata,           // AHB read data

    // DMA Stream 0: DMAC -> Expansion
    output wire                     exp_str_in_0_tvalid,
    input  wire                     exp_str_in_0_tready,
    output wire  [SYS_DATA_W-1:0]   exp_str_in_0_tdata,
    output wire             [3:0]   exp_str_in_0_tstrb,
    output wire                     exp_str_in_0_tlast,

    // DMA Stream 0: Expansion -> DMAC
    input  wire                     exp_str_out_0_tvalid,
    output wire                     exp_str_out_0_tready,
    input  wire  [SYS_DATA_W-1:0]   exp_str_out_0_tdata,
    input  wire             [3:0]   exp_str_out_0_tstrb,
    input  wire                     exp_str_out_0_tlast,
    output wire                     exp_str_out_0_flush,

    // DMA Stream 1: DMAC -> Expansion
    output wire                     exp_str_in_1_tvalid,
    input  wire                     exp_str_in_1_tready,
    output wire  [SYS_DATA_W-1:0]   exp_str_in_1_tdata,
    output wire             [3:0]   exp_str_in_1_tstrb,
    output wire                     exp_str_in_1_tlast,

    // DMA Stream 1: Expansion -> DMAC
    input  wire                     exp_str_out_1_tvalid,
    output wire                     exp_str_out_1_tready,
    input  wire  [SYS_DATA_W-1:0]   exp_str_out_1_tdata,
    input  wire             [3:0]   exp_str_out_1_tstrb,
    input  wire                     exp_str_out_1_tlast,
    output wire                     exp_str_out_1_flush,

    // DMA Stream 2: DMAC -> Expansion
    output wire                     exp_str_in_2_tvalid,
    input  wire                     exp_str_in_2_tready,
    output wire  [SYS_DATA_W-1:0]   exp_str_in_2_tdata,
    output wire             [3:0]   exp_str_in_2_tstrb,
    output wire                     exp_str_in_2_tlast,

    // DMA Stream 2: Expansion -> DMAC
    input  wire                     exp_str_out_2_tvalid,
    output wire                     exp_str_out_2_tready,
    input  wire  [SYS_DATA_W-1:0]   exp_str_out_2_tdata,
    input  wire             [3:0]   exp_str_out_2_tstrb,
    input  wire                     exp_str_out_2_tlast,
    output wire                     exp_str_out_2_flush,

    // Expansion Interrupt and DMA Connections
    input  wire             [3:0]   exp_irq,              // Expansion interrupt requests
    input  wire             [1:0]   exp_drq,              // Expansion DMA requests
    output wire             [1:0]   exp_dlast             // DMA last signals to expansion
);

    // System General Purpose I/O ports - before NANOSOC specific mappings
    wire              [15:0] sys_p0_altfunc;         // GPIO 0 alternate function (pin mux)
    wire              [15:0] sys_p1_altfunc;         // GPIO 1 alternate function (pin mux)
    wire              [15:0] sys_p0_in;              // GPIO 0 inputs
    wire              [15:0] sys_p0_out;             // GPIO 0 outputs
    wire              [15:0] sys_p0_outen;           // GPIO 0 output enables
    wire              [15:0] sys_p1_in;              // GPIO 1 inputs
    wire              [15:0] sys_p1_out;             // GPIO 1 outputs
    wire              [15:0] sys_p1_outen;           // GPIO 1 output enables
    wire              [15:0] sys_p1_out_mux;         // GPIO 1 Output Port Drive
    wire              [15:0] sys_p1_out_en_mux;      // Active High output drive enable (pad tech dependent)

    wire                     ft_clk_o;               // SCLK
    wire                     ft_ssn_o;               // SS_N
    wire                     ft_miso_i;              // MISO
    wire  [FT1248_WIDTH-1:0] ft_miosio_o;            // MIOSIO tristate output when enabled
    wire  [FT1248_WIDTH-1:0] ft_miosio_e;            // MIOSIO tristate output enable (active hi)
    wire  [FT1248_WIDTH-1:0] ft_miosio_z;            // MIOSIO tristate output enable (active lo)
    wire  [FT1248_WIDTH-1:0] ft_miosio_i;            // MIOSIO tristate input

    //--------------------------
    // System Wiring
    //--------------------------
    // System Input Clocks and Resets
    wire          sys_fclk;                          // Free running clock

    // System Reset Request Signals
    wire          sys_sysresetreq;                   // System Request from System Managers

    // AHB Clocks and Resets
    wire          sys_poresetn;                      // System Power On Reset
    // sys_hclk and sys_hresetn are output ports

    // APB Clocks and Resets
    wire          sys_pclk;                          // APB Clock
    wire          sys_pclkg;                         // APB Gated Clock
    wire          sys_presetn;                       // APB Reset
    wire          sys_pclken;                        // APB clock enable

    // Power Management Signals
    wire          sys_pmuenable;                     // Power Management Enable
    wire          sys_pmudbgresetreq;                // Power Management Debug Reset Req

    // Sysio APB driving signals - To all APB Components
    wire                    soc_peripheral_penable;           // APB Enable
    wire                    soc_peripheral_pwrite;            // APB Write
    wire  [APB_ADDR_W-1:0]  soc_peripheral_paddr;             // APB Address
    wire  [APB_DATA_W-1:0]  soc_peripheral_pwdata;            // APB Write Data

    // CPU sideband signalling - TO CPU Subsystem
    wire            [31:0]  sys_apb_irq;             // APB subsystem interrupt
    wire            [15:0]  sys_gpio0_irq;           // GPIO 0 IRQs
    wire            [15:0]  sys_gpio1_irq;           // GPIO 1 IRQs
    wire                    sys_nmi;                 // Watchdog interrupt

    // Combined CPU Signals
    wire          cpu_sysresetreq;                   // System Request from CPUs
    wire          cpu_prmuresetreq;                  // PMU Request from CPUs
    wire          cpu_lockup;                        // Combined Lockup from CPUs
    wire          cpu_sleepdeep;                     // Combined Sleepdeep from CPUs
    wire          cpu_sleeping;                      // Combined sleeping from CPUs

    // ADP GPIO interface
    wire               [7:0] adp_gpo8;               // ADP General Purpose Output
    wire               [7:0] adp_gpi8 = adp_gpo8;   // ADP General Purpose Input
    
    // Bus Matrix Remap Control - To Interconnect Subsystem
    wire             [3:0] sys_remap_ctrl;              // REMAP control bit

    //--------------------------
    // CPU Subsystem
    //--------------------------

    // Internal Wiring
    //--------------------------

    // CPU 0 AHB Wiring - To Interconnect Subsystem
    wire            [31:0] cpu_0_haddr;              // Address bus
    wire             [1:0] cpu_0_htrans;             // Transfer type
    wire                   cpu_0_hwrite;             // Transfer direction
    wire             [2:0] cpu_0_hsize;              // Transfer size
    wire             [2:0] cpu_0_hburst;             // Burst type
    wire             [3:0] cpu_0_hprot;              // Protection control
    wire            [31:0] cpu_0_hwdata;             // Write data
    wire                   cpu_0_hmastlock;          // Locked Sequence
    wire            [31:0] cpu_0_hrdata;             // Read data bus
    wire                   cpu_0_hready;             // HREADY feedback
    wire                   cpu_0_hresp;              // Transfer response

    // CPU Subsystem Single Slave Port Wiring - To Interconnect Subsystem
    // (bootrom_0, imem_0, dmem_0 are now internal to nanosoc_ss_cpu)
    wire                   cpu_ss_hsel;              // Select
    wire            [31:0] cpu_ss_haddr;             // Address bus
    wire             [1:0] cpu_ss_htrans;            // Transfer type
    wire                   cpu_ss_hwrite;            // Transfer direction
    wire             [2:0] cpu_ss_hsize;             // Transfer size
    wire             [2:0] cpu_ss_hburst;            // Burst type
    wire             [3:0] cpu_ss_hprot;             // Protection control
    wire            [31:0] cpu_ss_hwdata;            // Write data
    wire                   cpu_ss_hmastlock;         // Locked Sequence
    wire            [31:0] cpu_ss_hrdata;            // Read data bus
    wire                   cpu_ss_hreadyout;         // HREADY out
    wire                   cpu_ss_hresp;             // Transfer response

    // CPU Sideband Signaling - To System Control Subsystem
    wire                   cpu_0_nmi;                // Non-Maskable Interrupt request
    wire            [31:0] cpu_0_irq;                // Maskable Interrupt requests
    wire                   cpu_0_txev;               // Send Event (SEV) output
    wire                   cpu_0_rxev;               // Receive Event input
    wire                   cpu_0_lockup;             // Wake up request from WIC
    wire                   cpu_0_sysresetreq;        // System reset request
    wire                   cpu_0_prmuresetreq;       // PRMU reset request
    wire                   cpu_0_pmuenable;          // PRMU Enable
    wire                   cpu_0_pmudbgresetreq;     // Power Management Debug Reset Req

    wire                   cpu_0_sleeping;           // Processor status - sleeping
    wire                   cpu_0_sleepdeep;          // Processor status - deep sleep

    // Interrupt Wiring
    //--------------------------
    assign cpu_0_nmi = sys_nmi;

    // PRMU Wiring
    //--------------------------
    assign cpu_0_pmuenable = sys_pmuenable;

    // Instantiate Subsystem
    //--------------------------
    nanosoc_ss_cpu #(
        .CLKGATE_PRESENT   (CLKGATE_PRESENT),
        .BE                (BE),
        .BKPT              (BKPT),
        .DBG               (DBG),
        .NUMIRQ            (NUMIRQ),
        .SMUL              (SMUL),
        .SYST              (SYST),
        .WIC               (WIC),
        .WICLINES          (WICLINES),
        .WPT               (WPT),
        .RESET_ALL_REGS    (RESET_ALL_REGS),
        .INCLUDE_JTAG      (INCLUDE_JTAG),
        .ROMTABLE_BASE     (SYSTABLE_BASE),
        .BOOTROM_ADDR_W    (BOOTROM_ADDR_W),
        .IMEM_RAM_ADDR_W   (IMEM_RAM_ADDR_W),
        .IMEM_RAM_DATA_W   (IMEM_RAM_DATA_W),
        .IMEM_MEM_FPGA_IMG (IMEM_MEM_FPGA_IMG),
        .DMEM_RAM_ADDR_W   (DMEM_RAM_ADDR_W),
        .DMEM_RAM_DATA_W   (DMEM_RAM_DATA_W)
    ) u_ss_cpu (
        // System Input Clocks and Resets
        .sys_fclk(sys_fclk),
        .sys_sysresetn(sys_sysresetn),
        .sys_scanenable(sys_scanenable),
        .sys_testmode(sys_testmode),

        // System Reset Request Signals
        .sys_sysresetreq(sys_sysresetreq),
        .cpu_0_prmuresetreq(cpu_0_prmuresetreq),

        // Generated Clocks and Resets
        .sys_poresetn(sys_poresetn),
        .sys_hclk(sys_hclk),
        .sys_hresetn(sys_hresetn),

        // Power Management Signals
        .cpu_0_pmuenable(cpu_0_pmuenable),
        .cpu_0_pmudbgresetreq(cpu_0_pmudbgresetreq),

        // CPU 0 AHB Lite port
        .cpu_0_haddr(cpu_0_haddr),
        .cpu_0_htrans(cpu_0_htrans),
        .cpu_0_hwrite(cpu_0_hwrite),
        .cpu_0_hsize(cpu_0_hsize),
        .cpu_0_hburst(cpu_0_hburst),
        .cpu_0_hprot(cpu_0_hprot),
        .cpu_0_hwdata(cpu_0_hwdata),
        .cpu_0_hmastlock(cpu_0_hmastlock),
        .cpu_0_hrdata(cpu_0_hrdata),
        .cpu_0_hready(cpu_0_hready),
        .cpu_0_hresp(cpu_0_hresp),

        // System Address Remap control (for internal cpu_ss busmatrix)
        .sys_remap_ctrl(sys_remap_ctrl),

        // cpu_ss single AHB slave port (debug/DMA access to local memories)
        .cpu_ss_hsel(cpu_ss_hsel),
        .cpu_ss_haddr(cpu_ss_haddr),
        .cpu_ss_htrans(cpu_ss_htrans),
        .cpu_ss_hwrite(cpu_ss_hwrite),
        .cpu_ss_hsize(cpu_ss_hsize),
        .cpu_ss_hburst(cpu_ss_hburst),
        .cpu_ss_hprot(cpu_ss_hprot),
        .cpu_ss_hwdata(cpu_ss_hwdata),
        .cpu_ss_hmastlock(cpu_ss_hmastlock),
        .cpu_ss_hrdata(cpu_ss_hrdata),
        .cpu_ss_hresp(cpu_ss_hresp),
        .cpu_ss_hreadyout(cpu_ss_hreadyout),

        // CPU Sideband signalling
        .cpu_0_nmi(cpu_0_nmi),
        .cpu_0_irq(cpu_0_irq),
        .cpu_0_txev(cpu_0_txev),
        .cpu_0_rxev(cpu_0_rxev),
        .cpu_0_lockup(cpu_0_lockup),
        .cpu_0_sysresetreq(cpu_0_sysresetreq),

        .cpu_0_sleeping(cpu_0_sleeping),
        .cpu_0_sleepdeep(cpu_0_sleepdeep),

        // Serial-Wire Debug
        .cpu_0_swdi(cpu_0_swdi),
        .cpu_0_swclk(cpu_0_swclk),
        .cpu_0_swdo(cpu_0_swdo),
        .cpu_0_swdoen(cpu_0_swdoen)
    );

    //--------------------------
    // DMA Subsystem
    //--------------------------

    // Internal Wiring
    //--------------------------

    // DMAC 0 AHB Lite Port  - To Interconnect Subsystem
    wire          [SYS_ADDR_W-1:0] dmac_0_haddr;
    wire                     [1:0] dmac_0_htrans;
    wire                           dmac_0_hwrite;
    wire                     [2:0] dmac_0_hsize;
    wire                     [2:0] dmac_0_hburst;
    wire                     [3:0] dmac_0_hprot;
    wire          [SYS_DATA_W-1:0] dmac_0_hwdata;
    wire                           dmac_0_hmastlock;
    wire          [SYS_DATA_W-1:0] dmac_0_hrdata;
    wire                           dmac_0_hready;
    wire                           dmac_0_hresp;

    // DMAC 1 AHB Lite Port  - To Interconnect Subsystem
    wire          [SYS_ADDR_W-1:0] dmac_1_haddr;
    wire                     [1:0] dmac_1_htrans;
    wire                           dmac_1_hwrite;
    wire                     [2:0] dmac_1_hsize;
    wire                     [2:0] dmac_1_hburst;
    wire                     [3:0] dmac_1_hprot;
    wire          [SYS_DATA_W-1:0] dmac_1_hwdata;
    wire                           dmac_1_hmastlock;
    wire          [SYS_DATA_W-1:0] dmac_1_hrdata;
    wire                           dmac_1_hready;
    wire                           dmac_1_hresp;

    // DMAC_CTRL AHB Slave Port - From Interconnect Subsystem
    wire                           dmac_ctrl_hsel;
    wire          [SYS_ADDR_W-1:0] dmac_ctrl_haddr;
    wire                     [2:0] dmac_ctrl_hburst;
    wire                           dmac_ctrl_hmastlock;
    wire                     [3:0] dmac_ctrl_hprot;
    wire                     [2:0] dmac_ctrl_hsize;
    wire                     [1:0] dmac_ctrl_htrans;
    wire          [SYS_DATA_W-1:0] dmac_ctrl_hwdata;
    wire                           dmac_ctrl_hwrite;
    wire                           dmac_ctrl_hready;
    wire          [SYS_DATA_W-1:0] dmac_ctrl_hrdata;
    wire                           dmac_ctrl_hresp;
    wire                           dmac_ctrl_hreadyout;

    // DMA Request and Status
    wire  [DMAC_0_CHANNEL_NUM-1:0] dmac_0_dma_req;
    wire  [DMAC_0_CHANNEL_NUM-1:0] dmac_0_dma_done;
    wire                           dmac_0_dma_err;
    wire  [DMAC_1_CHANNEL_NUM-1:0] dmac_1_dma_req;
    wire  [DMAC_1_CHANNEL_NUM-1:0] dmac_1_dma_done;
    wire                           dmac_1_dma_err;
    wire                           dmac_any_done;
    wire                           dmac_any_error;

    // DMA Request Wiring
    //--------------------------
    assign dmac_1_dma_req = {DMAC_1_CHANNEL_NUM{1'b0}};

    // Instantiate DMA Subsystem
    //--------------------------
    nanosoc_ss_dma #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .APB_ADDR_W        (APB_ADDR_W),
        .APB_DATA_W        (APB_DATA_W),
        .DMAC_0_TYPE       (DMAC_0_TYPE),
        .DMAC_1_TYPE       (DMAC_1_TYPE),
        .DMAC_0_CHANNEL_NUM(DMAC_0_CHANNEL_NUM),
        .DMAC_1_CHANNEL_NUM(DMAC_1_CHANNEL_NUM)
    ) u_ss_dma (
        // System Clocks and Resets
        .sys_hclk    (sys_hclk),
        .sys_hresetn (sys_hresetn),
        .sys_pclk    (sys_pclk),
        .sys_pclkg   (sys_pclkg),
        .sys_presetn (sys_presetn),
        .sys_pclken  (sys_pclken),

        // DMAC 0 AHB Master Port - to interconnect
        .dmac_0_haddr    (dmac_0_haddr),
        .dmac_0_htrans   (dmac_0_htrans),
        .dmac_0_hwrite   (dmac_0_hwrite),
        .dmac_0_hsize    (dmac_0_hsize),
        .dmac_0_hburst   (dmac_0_hburst),
        .dmac_0_hprot    (dmac_0_hprot),
        .dmac_0_hwdata   (dmac_0_hwdata),
        .dmac_0_hmastlock(dmac_0_hmastlock),
        .dmac_0_hrdata   (dmac_0_hrdata),
        .dmac_0_hready   (dmac_0_hready),
        .dmac_0_hresp    (dmac_0_hresp),

        // DMAC 1 AHB Master Port - to interconnect
        .dmac_1_haddr    (dmac_1_haddr),
        .dmac_1_htrans   (dmac_1_htrans),
        .dmac_1_hwrite   (dmac_1_hwrite),
        .dmac_1_hsize    (dmac_1_hsize),
        .dmac_1_hburst   (dmac_1_hburst),
        .dmac_1_hprot    (dmac_1_hprot),
        .dmac_1_hwdata   (dmac_1_hwdata),
        .dmac_1_hmastlock(dmac_1_hmastlock),
        .dmac_1_hrdata   (dmac_1_hrdata),
        .dmac_1_hready   (dmac_1_hready),
        .dmac_1_hresp    (dmac_1_hresp),

        // DMAC_CTRL AHB Slave Port - from interconnect
        .dmac_ctrl_hsel      (dmac_ctrl_hsel),
        .dmac_ctrl_haddr     (dmac_ctrl_haddr),
        .dmac_ctrl_hburst    (dmac_ctrl_hburst),
        .dmac_ctrl_hmastlock (dmac_ctrl_hmastlock),
        .dmac_ctrl_hprot     (dmac_ctrl_hprot),
        .dmac_ctrl_hsize     (dmac_ctrl_hsize),
        .dmac_ctrl_htrans    (dmac_ctrl_htrans),
        .dmac_ctrl_hwdata    (dmac_ctrl_hwdata),
        .dmac_ctrl_hwrite    (dmac_ctrl_hwrite),
        .dmac_ctrl_hready    (dmac_ctrl_hready),
        .dmac_ctrl_hrdata    (dmac_ctrl_hrdata),
        .dmac_ctrl_hresp     (dmac_ctrl_hresp),
        .dmac_ctrl_hreadyout (dmac_ctrl_hreadyout),

        // DMA Stream 0 - to/from expansion
        .dmac_str_out_0_tvalid(exp_str_in_0_tvalid),
        .dmac_str_out_0_tready(exp_str_in_0_tready),
        .dmac_str_out_0_tdata (exp_str_in_0_tdata),
        .dmac_str_out_0_tstrb (exp_str_in_0_tstrb),
        .dmac_str_out_0_tlast (exp_str_in_0_tlast),
        .dmac_str_in_0_tvalid (exp_str_out_0_tvalid),
        .dmac_str_in_0_tready (exp_str_out_0_tready),
        .dmac_str_in_0_tdata  (exp_str_out_0_tdata),
        .dmac_str_in_0_tstrb  (exp_str_out_0_tstrb),
        .dmac_str_in_0_tlast  (exp_str_out_0_tlast),
        .dmac_str_in_0_flush  (exp_str_out_0_flush),

        // DMA Stream 1 - to/from expansion
        .dmac_str_out_1_tvalid(exp_str_in_1_tvalid),
        .dmac_str_out_1_tready(exp_str_in_1_tready),
        .dmac_str_out_1_tdata (exp_str_in_1_tdata),
        .dmac_str_out_1_tstrb (exp_str_in_1_tstrb),
        .dmac_str_out_1_tlast (exp_str_in_1_tlast),
        .dmac_str_in_1_tvalid (exp_str_out_1_tvalid),
        .dmac_str_in_1_tready (exp_str_out_1_tready),
        .dmac_str_in_1_tdata  (exp_str_out_1_tdata),
        .dmac_str_in_1_tstrb  (exp_str_out_1_tstrb),
        .dmac_str_in_1_tlast  (exp_str_out_1_tlast),
        .dmac_str_in_1_flush  (exp_str_out_1_flush),

        // DMA Stream 2 - to/from expansion
        .dmac_str_out_2_tvalid(exp_str_in_2_tvalid),
        .dmac_str_out_2_tready(exp_str_in_2_tready),
        .dmac_str_out_2_tdata (exp_str_in_2_tdata),
        .dmac_str_out_2_tstrb (exp_str_in_2_tstrb),
        .dmac_str_out_2_tlast (exp_str_in_2_tlast),
        .dmac_str_in_2_tvalid (exp_str_out_2_tvalid),
        .dmac_str_in_2_tready (exp_str_out_2_tready),
        .dmac_str_in_2_tdata  (exp_str_out_2_tdata),
        .dmac_str_in_2_tstrb  (exp_str_out_2_tstrb),
        .dmac_str_in_2_tlast  (exp_str_out_2_tlast),
        .dmac_str_in_2_flush  (exp_str_out_2_flush),

        // DMA Request and Status
        .dmac_0_dma_req  (dmac_0_dma_req),
        .dmac_0_dma_done (dmac_0_dma_done),
        .dmac_0_dma_err  (dmac_0_dma_err),
        .dmac_1_dma_req  (dmac_1_dma_req),
        .dmac_1_dma_done (dmac_1_dma_done),
        .dmac_1_dma_err  (dmac_1_dma_err),

        // Combined DMA status
        .dmac_any_done  (dmac_any_done),
        .dmac_any_error (dmac_any_error)
    );

    //--------------------------
    // Debug Subsystem
    //--------------------------

    // Internal Wiring
    //--------------------------
    // SocDebug AHB-lite Interface - To Interconnect Subsystem
    wire              [31:0] debug_haddr;
    wire              [ 2:0] debug_hburst;
    wire                     debug_hmastlock;
    wire              [ 3:0] debug_hprot;
    wire              [ 2:0] debug_hsize;
    wire              [ 1:0] debug_htrans;
    wire              [31:0] debug_hwdata;
    wire                     debug_hwrite;
    wire              [31:0] debug_hrdata;
    wire                     debug_hready;
    wire                     debug_hresp;

    // USRT APB Interface - To Debug Subsystem
    wire                     debug_psel;      // Device select
    wire              [31:0] debug_prdata;    // Read data
    wire                     debug_pready;    // Device ready
    wire                     debug_pslverr;   // Device error response

    // Debug Reset Request
    wire                     debug_resetreq;

    // Reset Request Wiring
    //--------------------------
    assign debug_resetreq = adp_gpo8[0];

    // USRT0 TXD AXI Byte Stream
    wire                   usrt0_txd_tvalid;         // Valid signal
    wire             [7:0] usrt0_txd_tdata;          // Data signal
    wire                   usrt0_txd_tready;         // Ready signal

    // USRT0 RXD AXI Byte Stream
    wire                   usrt0_rxd_tvalid;         // Valid signal
    wire             [7:0] usrt0_rxd_tdata;          // Data signal
    wire                   usrt0_rxd_tready;         // Ready signal

    // USRT1 TXD AXI Byte Stream
    wire                   usrt1_txd_tvalid;         // Valid signal
    wire             [7:0] usrt1_txd_tdata;          // Data signal
    wire                   usrt1_txd_tready;         // Ready signal

    // USRT1 RXD AXI Byte Stream
    wire                   usrt1_rxd_tvalid;         // Valid signal
    wire             [7:0] usrt1_rxd_tdata;          // Data signal
    wire                   usrt1_rxd_tready;         // Ready signal

    // ADP Interface Signals
    wire                   adp_rxd_tvalid;           // ADP RX Valid
    wire             [7:0] adp_rxd_tdata;            // ADP RX Data
    wire                   adp_rxd_tready;           // ADP RX Ready
    wire                   adp_txd_tvalid;           // ADP TX Valid
    wire             [7:0] adp_txd_tdata;            // ADP TX Data
    wire                   adp_txd_tready;           // ADP TX Ready

    wire ft1248mode = p1_in[7];                      // Added to support EXTIO mapping

    // FT1248 Clock Division Control
    wire [7:0] ft_clkdiv;

    // Sideband Wiring
    //--------------------------
    assign cpu_0_rxev = dmac_any_done;

    // Instantiate Subsystem
    //--------------------------
    nanosoc_ss_debug #(
        // System Parameters
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W),
        // SoCDebug Parameters
        .PROMPT_CHAR(PROMPT_CHAR)
    ) u_ss_debug (
        // System Clocks and Resets
        .SYS_HCLK(sys_hclk),
        .SYS_HRESETn(sys_hresetn),
        .SYS_PCLK(sys_pclk),
        .SYS_PCLKG(sys_pclkg),
        .SYS_PRESETn(sys_presetn),

        // AHB-lite Master Interface - ADP
        .DEBUG_HADDR(debug_haddr),
        .DEBUG_HBURST(debug_hburst),
        .DEBUG_HMASTLOCK(debug_hmastlock),
        .DEBUG_HPROT(debug_hprot),
        .DEBUG_HSIZE(debug_hsize),
        .DEBUG_HTRANS(debug_htrans),
        .DEBUG_HWDATA(debug_hwdata),
        .DEBUG_HWRITE(debug_hwrite),
        .DEBUG_HRDATA(debug_hrdata),
        .DEBUG_HREADY(debug_hready),
        .DEBUG_HRESP(debug_hresp),

        .ADP_RXD_TVALID_o(adp_rxd_tvalid),
        .ADP_RXD_TDATA_o( adp_rxd_tdata ),
        .ADP_RXD_TREADY_i(adp_rxd_tready),
        .ADP_TXD_TVALID_i(adp_txd_tvalid),
        .ADP_TXD_TDATA_i (adp_txd_tdata ),
        .ADP_TXD_TREADY_o(adp_txd_tready),

        // APB Slave Interface - USRT Control
        .DEBUG_PSEL        (debug_psel),
        .DEBUG_PADDR       (soc_peripheral_paddr[11:2]),
        .DEBUG_PENABLE     (soc_peripheral_penable),
        .DEBUG_PWRITE      (soc_peripheral_pwrite),
        .DEBUG_PWDATA      (soc_peripheral_pwdata),
        .DEBUG_PRDATA      (debug_prdata),
        .DEBUG_PREADY      (debug_pready),
        .DEBUG_PSLVERR     (debug_pslverr),

        // FT1248 Clock Divider
        .DEBUG_INVBAUDDIV8 (ft_clkdiv),

        // USRT Interrupts
        .DEBUG_TXINT       ( ),
        .DEBUG_RXINT       ( ),
        .DEBUG_TXOVRINT    ( ),
        .DEBUG_RXOVRINT    ( ),
        .DEBUG_UARTINT     ( ),

        // GPIO interface
        .GPO8(adp_gpo8),
        .GPI8(adp_gpi8)
    );

    wire       ft_adp_rxd_tvalid;
    wire [7:0] ft_adp_rxd_tdata;
    wire       ft_adp_rxd_tready;
    wire       ft_adp_txd_tvalid;
    wire [7:0] ft_adp_txd_tdata;
    wire       ft_adp_txd_tready;

    // EXT DAT DMA trigger wires (driven by nanosoc_ss_extio)
    wire       ext_dat_rxd_tready;
    wire       ext_dat_txd_tvalid;

    // Instantiation of FT1248 Controller
    socdebug_ft1248_control #(
        .FT1248_WIDTH (FT1248_WIDTH),
        .FT1248_CLKON (FT1248_CLKON)
    ) u_ft1248_control (
        .clk              (sys_hclk),
        .resetn           (sys_hresetn),
        
        .ft_clkdiv        (ft_clkdiv),
        .ft_clk_o         (ft_clk_o),
        .ft_ssn_o         (ft_ssn_o),
        .ft_miso_i        (ft_miso_i),
        .ft_miosio_o      (ft_miosio_o),
        .ft_miosio_e      (ft_miosio_e),
        .ft_miosio_z      (ft_miosio_z),
        .ft_miosio_i      (ft_miosio_i),

        // ADP Interface - FT1248 to ADP
        .txd_tvalid       (ft_adp_txd_tvalid),
        .txd_tdata        (ft_adp_txd_tdata ),
        .txd_tready       (ft_adp_txd_tready),
        .txd_tlast        ( ),

        // ADP Interface - FT_ADP to FT1248
        .rxd_tvalid       (ft_adp_rxd_tvalid),
        .rxd_tdata        (ft_adp_rxd_tdata ),
        .rxd_tready       (ft_adp_rxd_tready),
        .rxd_tlast        (1'b0)
    );

    //--------------------------
    // Expansion Interface
    //--------------------------

    // Expansion DRQ/DLAST Wiring
    //--------------------------
    assign exp_dlast[1:0]       = 2'b00;
    assign dmac_0_dma_req[1:0]  = exp_drq;
    assign dmac_0_dma_req[2]    = ext_dat_rxd_tready & sys_p1_out[2];
    assign dmac_0_dma_req[3]    = ext_dat_txd_tvalid & sys_p1_out[3];

    // Expansion SRAM Low Region AHB Port - Internal wires to interconnect
    wire                   sram_0_hsel;
    wire  [SYS_ADDR_W-1:0] sram_0_haddr;
    wire             [1:0] sram_0_htrans;
    wire             [2:0] sram_0_hsize;
    wire             [3:0] sram_0_hprot;
    wire                   sram_0_hwrite;
    wire                   sram_0_hready;
    wire  [SYS_DATA_W-1:0] sram_0_hwdata;
    wire             [2:0] sram_0_hburst;
    wire                   sram_0_hmastlock;
    wire                   sram_0_hreadyout;
    wire                   sram_0_hresp;
    wire  [SYS_DATA_W-1:0] sram_0_hrdata;

    nanosoc_region_sram #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (SRAM_0_RAM_ADDR_W),
        .RAM_DATA_W (SRAM_0_RAM_DATA_W)
    ) u_region_sram_0 (
        .HCLK       (sys_hclk),
        .HRESETn    (sys_hresetn),
        .HSEL       (sram_0_hsel),
        .HADDR      (sram_0_haddr),
        .HTRANS     (sram_0_htrans),
        .HSIZE      (sram_0_hsize),
        .HPROT      (sram_0_hprot),
        .HWRITE     (sram_0_hwrite),
        .HREADY     (sram_0_hready),
        .HWDATA     (sram_0_hwdata),
        .HREADYOUT  (sram_0_hreadyout),
        .HRESP      (sram_0_hresp),
        .HRDATA     (sram_0_hrdata)
    );

    // Expansion SRAM High Region AHB Port - Internal wires to interconnect
    wire                   sram_1_hsel;
    wire  [SYS_ADDR_W-1:0] sram_1_haddr;
    wire             [1:0] sram_1_htrans;
    wire             [2:0] sram_1_hsize;
    wire             [3:0] sram_1_hprot;
    wire                   sram_1_hwrite;
    wire                   sram_1_hready;
    wire  [SYS_DATA_W-1:0] sram_1_hwdata;
    wire             [2:0] sram_1_hburst;
    wire                   sram_1_hmastlock;
    wire                   sram_1_hreadyout;
    wire                   sram_1_hresp;
    wire  [SYS_DATA_W-1:0] sram_1_hrdata;

    nanosoc_region_sram #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (SRAM_1_RAM_ADDR_W),
        .RAM_DATA_W (SRAM_1_RAM_DATA_W)
    ) u_region_sram_1 (
        .HCLK       (sys_hclk),
        .HRESETn    (sys_hresetn),
        .HSEL       (sram_1_hsel),
        .HADDR      (sram_1_haddr),
        .HTRANS     (sram_1_htrans),
        .HSIZE      (sram_1_hsize),
        .HPROT      (sram_1_hprot),
        .HWRITE     (sram_1_hwrite),
        .HREADY     (sram_1_hready),
        .HWDATA     (sram_1_hwdata),
        .HREADYOUT  (sram_1_hreadyout),
        .HRESP      (sram_1_hresp),
        .HRDATA     (sram_1_hrdata)
    );

    //--------------------------
    // System Control Subsystem
    //--------------------------

    // Internal Wiring
    //--------------------------

    // SOC_PERIPHERAL AHB Interface - To Interconnect Subsystem
    wire                   soc_peripheral_hsel;               // AHB region select
    wire  [SYS_ADDR_W-1:0] soc_peripheral_haddr;              // AHB address
    wire             [2:0] soc_peripheral_hburst;             // AHB burst
    wire                   soc_peripheral_hmastlock;          // AHB lock
    wire             [3:0] soc_peripheral_hprot;              // AHB prot
    wire             [2:0] soc_peripheral_hsize;              // AHB size
    wire             [1:0] soc_peripheral_htrans;             // AHB transfer
    wire  [SYS_DATA_W-1:0] soc_peripheral_hwdata;             // AHB write data
    wire                   soc_peripheral_hwrite;             // AHB write
    wire                   soc_peripheral_hready;             // AHB ready
    wire  [SYS_DATA_W-1:0] soc_peripheral_hrdata;             // AHB read-data
    wire                   soc_peripheral_hresp;              // AHB response
    wire                   soc_peripheral_hreadyout;          // AHB ready out

    // System ROM Table AHB Interface - To Interconnect Subsystem
    wire                   systable_hsel;            // AHB region select
    wire  [SYS_ADDR_W-1:0] systable_haddr;           // AHB address
    wire             [2:0] systable_hburst;          // AHB burst
    wire                   systable_hmastlock;       // AHB lock
    wire             [3:0] systable_hprot;           // AHB prot
    wire             [2:0] systable_hsize;           // AHB size
    wire             [1:0] systable_htrans;          // AHB transfer
    wire  [SYS_DATA_W-1:0] systable_hwdata;          // AHB write data
    wire                   systable_hwrite;          // AHB write
    wire                   systable_hready;          // AHB ready
    wire  [SYS_DATA_W-1:0] systable_hrdata;          // AHB read-data
    wire                   systable_hresp;           // AHB response
    wire                   systable_hreadyout;       // AHB ready out

    // Lockup Signals - To System
    wire                   sys_wdogresetreq;         // Watchdog reset request
    wire                   sys_lockupreset;          // System Controller cfg - Reset if lockup

    // Interrupt Wiring
    //--------------------------
    wire sys_gpio0_any_irq;                          // Combined GPIO0 interrupt
    wire sys_gpio1_any_irq;                          // Combined GPIO1 interrupt

    assign sys_gpio0_any_irq = |sys_gpio0_irq;
    assign sys_gpio1_any_irq = |sys_gpio1_irq;

    // Combined CPU Wiring
    //--------------------------
    assign cpu_sysresetreq  = cpu_0_sysresetreq;
    assign cpu_lockup       = cpu_0_lockup;
    assign cpu_prmuresetreq = cpu_0_prmuresetreq;
    assign cpu_sleeping     = cpu_0_sleeping;
    assign cpu_sleepdeep    = cpu_0_sleepdeep;

    // Reset Request Wiring
    //--------------------------
    assign sys_pmudbgresetreq = cpu_0_pmudbgresetreq;

    assign sys_sysresetreq = cpu_sysresetreq
                           | debug_resetreq
                           | sys_wdogresetreq
                           | (sys_lockupreset & cpu_lockup);

    // Instantiate Subsystem
    //--------------------------

    nanosoc_ss_systemctrl #(
        // System Parameters
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W),
        .APB_ADDR_W(APB_ADDR_W),
        .APB_DATA_W(APB_DATA_W),
        .CLKGATE_PRESENT(CLKGATE_PRESENT)
    ) u_ss_systemctrl (
        // Free-running and Crystal Clock Output
        .SYS_CLK (sys_clk),                // System Input Clock
        .SYS_FCLK(sys_fclk),               // Free-running system clock
        .SYS_XTALCLK_OUT(sys_xtalclk_out), // Crystal Clock Output

        // System Input Clocks and Resets
        .SYS_SYSRESETn(sys_sysresetn),
        .SYS_PORESETn(sys_poresetn),       // Power-On-Reset reset (active-low)
        .SYS_TESTMODE(sys_testmode),       // Reset bypass in scan test
        .SYS_HCLK(sys_hclk),               // AHB clock
        .SYS_HRESETn(sys_hresetn),         // AHB reset (active-low)

        // SOC_PERIPHERAL AHB interface
        .SOC_PERIPHERAL_HSEL(soc_peripheral_hsel),           // AHB region select
        .SOC_PERIPHERAL_HADDR(soc_peripheral_haddr),         // AHB address
        .SOC_PERIPHERAL_HBURST(soc_peripheral_hburst),       // AHB burst
        .SOC_PERIPHERAL_HMASTLOCK(soc_peripheral_hmastlock), // AHB lock
        .SOC_PERIPHERAL_HPROT(soc_peripheral_hprot),         // AHB prot
        .SOC_PERIPHERAL_HSIZE(soc_peripheral_hsize),         // AHB size
        .SOC_PERIPHERAL_HTRANS(soc_peripheral_htrans),       // AHB transfer
        .SOC_PERIPHERAL_HWDATA(soc_peripheral_hwdata),       // AHB write data
        .SOC_PERIPHERAL_HWRITE(soc_peripheral_hwrite),       // AHB write
        .SOC_PERIPHERAL_HREADY(soc_peripheral_hready),       // AHB ready
        .SOC_PERIPHERAL_HRDATA(soc_peripheral_hrdata),       // AHB read-data
        .SOC_PERIPHERAL_HRESP(soc_peripheral_hresp),         // AHB response
        .SOC_PERIPHERAL_HREADYOUT(soc_peripheral_hreadyout), // AHB ready out

        // APB clocking control
        .SYS_PCLK(sys_pclk),       // Peripheral clock
        .SYS_PCLKG(sys_pclkg),     // Gated Peripheral bus clock
        .SYS_PRESETn(sys_presetn), // Peripheral system and APB reset
        .SYS_PCLKEN(sys_pclken),   // Clock divide control for AHB to APB bridge

        // APB external Slave Interfaces
        .SOC_PERIPHERAL_PENABLE(soc_peripheral_penable),
        .SOC_PERIPHERAL_PWRITE(soc_peripheral_pwrite),
        .SOC_PERIPHERAL_PADDR(soc_peripheral_paddr),
        .SOC_PERIPHERAL_PWDATA(soc_peripheral_pwdata),

        .USRT_PSEL(debug_psel),
        .USRT_PRDATA(debug_prdata),
        .USRT_PREADY(debug_pready),
        .USRT_PSLVERR(debug_pslverr),

        // CPU sideband signalling
        .SYS_NMI(sys_nmi),
        .SYS_APB_IRQ(sys_apb_irq),
        .SYS_GPIO0_IRQ(sys_gpio0_irq),
        .SYS_GPIO1_IRQ(sys_gpio1_irq),

        // CPU power/reset control
        .SYS_REMAP_CTRL(sys_remap_ctrl),
        .SYS_WDOGRESETREQ(sys_wdogresetreq),
        .SYS_LOCKUPRESET(sys_lockupreset),

        // System Reset Request Signals
        .CPU_SYSRESETREQ(cpu_sysresetreq),
        .CPU_PRMURESETREQ(cpu_prmuresetreq),

        // Power Management Control and Status
        .SYS_PMUENABLE(sys_pmuenable),
        .SYS_PMUDBGRESETREQ(sys_pmudbgresetreq),

        // CPU Status Signals
        .CPU_LOCKUP(cpu_lockup),
        .CPU_SLEEPING(cpu_sleeping),
        .CPU_SLEEPDEEP(cpu_sleepdeep),

        // USRT0
        .USRT0_TXD_TVALID (usrt0_txd_tvalid),
        .USRT0_TXD_TDATA  (usrt0_txd_tdata ),
        .USRT0_TXD_TREADY (usrt0_txd_tready),
        .USRT0_RXD_TVALID (usrt0_rxd_tvalid),
        .USRT0_RXD_TDATA  (usrt0_rxd_tdata ),
        .USRT0_RXD_TREADY (usrt0_rxd_tready),
        // USRT1
        .USRT1_TXD_TVALID (usrt1_txd_tvalid),
        .USRT1_TXD_TDATA  (usrt1_txd_tdata ),
        .USRT1_TXD_TREADY (usrt1_txd_tready),
        .USRT1_RXD_TVALID (usrt1_rxd_tvalid),
        .USRT1_RXD_TDATA  (usrt1_rxd_tdata ),
        .USRT1_RXD_TREADY (usrt1_rxd_tready),

        // GPIO
        .P0_IN          (sys_p0_in),
        .P0_OUT         (sys_p0_out),
        .P0_OUTEN       (sys_p0_outen),
        .P0_ALTFUNC     (sys_p0_altfunc),
        .P1_IN          (sys_p1_in),
        .P1_OUT         (sys_p1_out),
        .P1_OUTEN       (sys_p1_outen),
        .P1_ALTFUNC     (sys_p1_altfunc),
        .P1_OUT_MUX     (sys_p1_out_mux),
        .P1_OUT_EN_MUX  (sys_p1_out_en_mux)
    );


    //--------------------------
    // System ROM Table Region
    //--------------------------
    nanosoc_region_systable #(
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W),
        .SYSTABLE_BASE(SYSTABLE_BASE),
        .SOCLABS_JEPID(SOCLABS_JEPID),
        .NANOSOC_PARTNUMBER(NANOSOC_PARTNUMBER),
        .NANOSOC_REVISION(NANOSOC_REVISION)
    ) u_region_systable (
        .HCLK(sys_hclk),
        .HSEL(systable_hsel),
        .HADDR(systable_haddr),
        .HBURST(systable_hburst),
        .HMASTLOCK(systable_hmastlock),
        .HPROT(systable_hprot),
        .HSIZE(systable_hsize),
        .HTRANS(systable_htrans),
        .HWDATA(systable_hwdata),
        .HWRITE(systable_hwrite),
        .HREADY(systable_hready),
        .HRDATA(systable_hrdata),
        .HRESP(systable_hresp),
        .HREADYOUT(systable_hreadyout)
    );

    //--------------------------
    // EXTIO Subsystem
    //--------------------------
    nanosoc_ss_extio u_ss_extio (
        .SYS_HCLK           (sys_hclk),
        .SYS_HRESETn        (sys_hresetn),
        .SYS_TESTMODE       (sys_testmode),
        .FT1248MODE         (ft1248mode),

        // ADP stream - to/from debug subsystem
        .ADP_RXD_TVALID     (adp_rxd_tvalid),
        .ADP_RXD_TDATA      (adp_rxd_tdata),
        .ADP_RXD_TREADY     (adp_rxd_tready),
        .ADP_TXD_TVALID     (adp_txd_tvalid),
        .ADP_TXD_TDATA      (adp_txd_tdata),
        .ADP_TXD_TREADY     (adp_txd_tready),

        // FT1248 ADP stream - to/from FT1248 controller
        .FT_ADP_RXD_TVALID  (ft_adp_rxd_tvalid),
        .FT_ADP_RXD_TDATA   (ft_adp_rxd_tdata),
        .FT_ADP_RXD_TREADY  (ft_adp_rxd_tready),
        .FT_ADP_TXD_TVALID  (ft_adp_txd_tvalid),
        .FT_ADP_TXD_TDATA   (ft_adp_txd_tdata),
        .FT_ADP_TXD_TREADY  (ft_adp_txd_tready),

        // USRT0 stream - to/from peripheral subsystem
        .USRT0_TXD_TVALID   (usrt0_txd_tvalid),
        .USRT0_TXD_TDATA    (usrt0_txd_tdata),
        .USRT0_TXD_TREADY   (usrt0_txd_tready),
        .USRT0_RXD_TVALID   (usrt0_rxd_tvalid),
        .USRT0_RXD_TDATA    (usrt0_rxd_tdata),
        .USRT0_RXD_TREADY   (usrt0_rxd_tready),

        // USRT1 stream - to/from peripheral subsystem
        .USRT1_TXD_TVALID   (usrt1_txd_tvalid),
        .USRT1_TXD_TDATA    (usrt1_txd_tdata),
        .USRT1_TXD_TREADY   (usrt1_txd_tready),
        .USRT1_RXD_TVALID   (usrt1_rxd_tvalid),
        .USRT1_RXD_TDATA    (usrt1_rxd_tdata),
        .USRT1_RXD_TREADY   (usrt1_rxd_tready),

        // EXT DAT DMA triggers
        .EXT_DAT_RXD_TREADY (ext_dat_rxd_tready),
        .EXT_DAT_TXD_TVALID (ext_dat_txd_tvalid),

        // FT1248 physical signals
        .FT_CLK_O           (ft_clk_o),
        .FT_SSN_O           (ft_ssn_o),
        .FT_MIOSIO_O        (ft_miosio_o[0]),
        .FT_MIOSIO_E        (ft_miosio_e[0]),
        .FT_MISO_I          (ft_miso_i),
        .FT_MIOSIO_I        (ft_miosio_i[0]),

        // P1[6:0] physical GPIO pads
        .P1_IN              (p1_in[6:0]),
        .P1_OUT             (p1_out[6:0]),
        .P1_OUTEN           (p1_outen[6:0]),

        // P1[6:0] GPIO to/from system control subsystem
        .SYS_P1_IN          (sys_p1_in[6:0]),
        .SYS_P1_OUT_MUX     (sys_p1_out_mux[6:4]),
        .SYS_P1_OUT_EN_MUX  (sys_p1_out_en_mux[6:4])
    );

    // SOC specific IO mapping - PORT0
    assign sys_p0_in[15:0]  = p0_in[15:0];
    assign p0_out[15:0]     = sys_p0_out[15:0];
    assign p0_outen[15:0]   = sys_p0_outen[15:0];

    // PORT 1 [7] and PORT1[15:8] - standard GPIO
    assign p1_out[7]        = sys_p1_out_mux[7];
    assign p1_outen[7]      = sys_p1_out_en_mux[7];
    assign sys_p1_in[7]     = p1_in[7];

    // the rest of PORT1[15:8] is GPIO/AltFunction
    assign sys_p1_in[15:8]  = p1_in[15:8];
    assign p1_out[15:8]     = sys_p1_out_mux[15:8];
    assign p1_outen[15:8]   = sys_p1_out_en_mux[15:8];

    //--------------------------
    // Interrupt Wiring
    //--------------------------
    assign cpu_0_irq[ 3: 0] = sys_apb_irq[ 3: 0];
    assign cpu_0_irq[ 5: 4] = sys_apb_irq[ 5: 4];
    assign cpu_0_irq[ 6]    = sys_apb_irq[ 6] | sys_gpio0_any_irq;
    assign cpu_0_irq[ 7]    = sys_apb_irq[ 7] | sys_gpio1_any_irq;
    assign cpu_0_irq[10: 8] = sys_apb_irq[10: 8];
    assign cpu_0_irq[14:11] = exp_irq[3:0];
    assign cpu_0_irq[15]    = sys_apb_irq[15] | dmac_any_done | dmac_any_error;
    assign cpu_0_irq[31:16] = sys_apb_irq[31:16] | sys_gpio0_irq[15:0];

    //--------------------------
    // Interconnect Subsystem
    //--------------------------
    nanosoc_interconnect #(
        .SYS_ADDR_W   (SYS_ADDR_W),  // System Address Width
        .SYS_DATA_W   (SYS_DATA_W)   // System Data Width
    ) u_interconnect (
        // System Clocks, Resets, and Control
        .sys_hclk                (sys_hclk),
        .sys_hresetn             (sys_hresetn),
        .sys_scanenable          (sys_scanenable),
        .sys_scaninhclk          (sys_scaninhclk),
        .sys_scanouthclk         (sys_scanouthclk),

        // System Address Remap control
        .sys_remap_ctrl          (sys_remap_ctrl),

        // Debug Master Port
        .debug_haddr             (debug_haddr),
        .debug_htrans            (debug_htrans),
        .debug_hwrite            (debug_hwrite),
        .debug_hsize             (debug_hsize),
        .debug_hburst            (debug_hburst),
        .debug_hprot             (debug_hprot),
        .debug_hwdata            (debug_hwdata),
        .debug_hmastlock         (debug_hmastlock),
        .debug_hrdata            (debug_hrdata),
        .debug_hready            (debug_hready),
        .debug_hresp             (debug_hresp),

        // DMA Controller 0 Master Port
        .dmac_0_haddr            (dmac_0_haddr),
        .dmac_0_htrans           (dmac_0_htrans),
        .dmac_0_hwrite           (dmac_0_hwrite),
        .dmac_0_hsize            (dmac_0_hsize),
        .dmac_0_hburst           (dmac_0_hburst),
        .dmac_0_hprot            (dmac_0_hprot),
        .dmac_0_hwdata           (dmac_0_hwdata),
        .dmac_0_hmastlock        (dmac_0_hmastlock),
        .dmac_0_hrdata           (dmac_0_hrdata),
        .dmac_0_hready           (dmac_0_hready),
        .dmac_0_hresp            (dmac_0_hresp),

        // DMAC Controller 1 Master Port
        .dmac_1_haddr            (dmac_1_haddr),
        .dmac_1_htrans           (dmac_1_htrans),
        .dmac_1_hwrite           (dmac_1_hwrite),
        .dmac_1_hsize            (dmac_1_hsize),
        .dmac_1_hburst           (dmac_1_hburst),
        .dmac_1_hprot            (dmac_1_hprot),
        .dmac_1_hwdata           (dmac_1_hwdata),
        .dmac_1_hmastlock        (dmac_1_hmastlock),
        .dmac_1_hrdata           (dmac_1_hrdata),
        .dmac_1_hready           (dmac_1_hready),
        .dmac_1_hresp            (dmac_1_hresp),

        // CPU 0 Master Port
        .cpu_0_haddr             (cpu_0_haddr),
        .cpu_0_htrans            (cpu_0_htrans),
        .cpu_0_hwrite            (cpu_0_hwrite),
        .cpu_0_hsize             (cpu_0_hsize),
        .cpu_0_hburst            (cpu_0_hburst),
        .cpu_0_hprot             (cpu_0_hprot),
        .cpu_0_hwdata            (cpu_0_hwdata),
        .cpu_0_hmastlock         (cpu_0_hmastlock),
        .cpu_0_hrdata            (cpu_0_hrdata),
        .cpu_0_hready            (cpu_0_hready),
        .cpu_0_hresp             (cpu_0_hresp),

        // CPU Subsystem Single Slave Port (bootrom/imem/dmem now internal to cpu_ss)
        .cpu_ss_hrdata           (cpu_ss_hrdata),
        .cpu_ss_hreadyout        (cpu_ss_hreadyout),
        .cpu_ss_hresp            (cpu_ss_hresp),
        .cpu_ss_hsel             (cpu_ss_hsel),
        .cpu_ss_haddr            (cpu_ss_haddr),
        .cpu_ss_htrans           (cpu_ss_htrans),
        .cpu_ss_hwrite           (cpu_ss_hwrite),
        .cpu_ss_hsize            (cpu_ss_hsize),
        .cpu_ss_hburst           (cpu_ss_hburst),
        .cpu_ss_hprot            (cpu_ss_hprot),
        .cpu_ss_hwdata           (cpu_ss_hwdata),
        .cpu_ss_hmastlock        (cpu_ss_hmastlock),
        .cpu_ss_hreadymux        (),               // unused — cpu_ss internal busmatrix manages HREADY

        // System Peripheral Region Slave Port
        .soc_peripheral_hrdata     (soc_peripheral_hrdata),
        .soc_peripheral_hreadyout  (soc_peripheral_hreadyout),
        .soc_peripheral_hresp      (soc_peripheral_hresp),
        .soc_peripheral_hsel       (soc_peripheral_hsel),
        .soc_peripheral_haddr      (soc_peripheral_haddr),
        .soc_peripheral_htrans     (soc_peripheral_htrans),
        .soc_peripheral_hwrite     (soc_peripheral_hwrite),
        .soc_peripheral_hsize      (soc_peripheral_hsize),
        .soc_peripheral_hburst     (soc_peripheral_hburst),
        .soc_peripheral_hprot      (soc_peripheral_hprot),
        .soc_peripheral_hwdata     (soc_peripheral_hwdata),
        .soc_peripheral_hmastlock  (soc_peripheral_hmastlock),
        .soc_peripheral_hreadymux  (soc_peripheral_hready),

        // DMAC_CTRL Region Slave Port
        .dmac_ctrl_hrdata          (dmac_ctrl_hrdata),
        .dmac_ctrl_hreadyout       (dmac_ctrl_hreadyout),
        .dmac_ctrl_hresp           (dmac_ctrl_hresp),
        .dmac_ctrl_hsel            (dmac_ctrl_hsel),
        .dmac_ctrl_haddr           (dmac_ctrl_haddr),
        .dmac_ctrl_htrans          (dmac_ctrl_htrans),
        .dmac_ctrl_hwrite          (dmac_ctrl_hwrite),
        .dmac_ctrl_hsize           (dmac_ctrl_hsize),
        .dmac_ctrl_hburst          (dmac_ctrl_hburst),
        .dmac_ctrl_hprot           (dmac_ctrl_hprot),
        .dmac_ctrl_hwdata          (dmac_ctrl_hwdata),
        .dmac_ctrl_hmastlock       (dmac_ctrl_hmastlock),
        .dmac_ctrl_hreadymux       (dmac_ctrl_hready),

        // Expansion Memory Low Region Slave Port
        .sram_0_hrdata             (sram_0_hrdata),
        .sram_0_hreadyout          (sram_0_hreadyout),
        .sram_0_hresp              (sram_0_hresp),
        .sram_0_hsel               (sram_0_hsel),
        .sram_0_haddr              (sram_0_haddr),
        .sram_0_htrans             (sram_0_htrans),
        .sram_0_hwrite             (sram_0_hwrite),
        .sram_0_hsize              (sram_0_hsize),
        .sram_0_hburst             (sram_0_hburst),
        .sram_0_hprot              (sram_0_hprot),
        .sram_0_hwdata             (sram_0_hwdata),
        .sram_0_hmastlock          (sram_0_hmastlock),
        .sram_0_hreadymux          (sram_0_hready),

        // Expansion Memory High Region Slave Port
        .sram_1_hrdata             (sram_1_hrdata),
        .sram_1_hreadyout          (sram_1_hreadyout),
        .sram_1_hresp              (sram_1_hresp),
        .sram_1_hsel               (sram_1_hsel),
        .sram_1_haddr              (sram_1_haddr),
        .sram_1_htrans             (sram_1_htrans),
        .sram_1_hwrite             (sram_1_hwrite),
        .sram_1_hsize              (sram_1_hsize),
        .sram_1_hburst             (sram_1_hburst),
        .sram_1_hprot              (sram_1_hprot),
        .sram_1_hwdata             (sram_1_hwdata),
        .sram_1_hmastlock          (sram_1_hmastlock),
        .sram_1_hreadymux          (sram_1_hready),

        // Expansion Region Slave Port
        .exp_hrdata              (exp_hrdata),
        .exp_hreadyout           (exp_hreadyout),
        .exp_hresp               (exp_hresp),
        .exp_hsel                (exp_hsel),
        .exp_haddr               (exp_haddr),
        .exp_htrans              (exp_htrans),
        .exp_hwrite              (exp_hwrite),
        .exp_hsize               (exp_hsize),
        .exp_hburst              (exp_hburst),
        .exp_hprot               (exp_hprot),
        .exp_hwdata              (exp_hwdata),
        .exp_hmastlock           (exp_hmastlock),
        .exp_hreadymux           (exp_hready),

        // System ROM Table Region Slave Port
        .systable_hrdata         (systable_hrdata),
        .systable_hreadyout      (systable_hreadyout),
        .systable_hresp          (systable_hresp),
        .systable_hsel           (systable_hsel),
        .systable_haddr          (systable_haddr),
        .systable_htrans         (systable_htrans),
        .systable_hwrite         (systable_hwrite),
        .systable_hsize          (systable_hsize),
        .systable_hburst         (systable_hburst),
        .systable_hprot          (systable_hprot),
        .systable_hwdata         (systable_hwdata),
        .systable_hmastlock      (systable_hmastlock),
        .systable_hreadymux      (systable_hready)
    );

endmodule
