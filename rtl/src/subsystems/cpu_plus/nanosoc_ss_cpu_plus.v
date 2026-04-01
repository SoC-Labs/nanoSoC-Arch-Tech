//-----------------------------------------------------------------------------
// NanoSoC CPU+ Subsystem - Contains Cortex-M0+ Core, Memory and Clock/Reset Control
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2024, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//
// External AHB interfaces (single slave in, single master out):
//
//   cpu_ss_h*  -- single AHB slave port.  Receives accesses from external
//                masters (debug, DMA) to the local memories (bootrom, imem,
//                dmem).  Routed internally through the cpu_ss busmatrix.
//
//   cpu_0_h*   -- single AHB master port.  Carries CPU core traffic that is
//                destined for system addresses (>= 0x40000000).  This is the
//                'system' target output of the internal cpu_ss busmatrix.
//
// Internal busmatrix (nanosoc_cpu_ss_ahb_interconnect_lite):
//   Initiators : cpu_0 (CPU core), cpu_ss (slave port above)
//   Targets    : bootrom_0, imem_0, dmem_0 (local), system (master port above)
//
// M0+ additions over M0:
//   - Single-cycle I/O port (IOP parameter)
//   - Vector Table Offset Register (VTOR parameter)
//   - Memory Protection Unit (MPU parameter)
//-----------------------------------------------------------------------------

module nanosoc_ss_cpu_plus #(
    // System Parameters
    parameter    SYS_ADDR_W     = 32,  // System Address Width
    parameter    SYS_DATA_W     = 32,  // System Data Width

    // CPU Parameters
    parameter CLKGATE_PRESENT   = 0,
    parameter BE                = 0,   // 1: Big endian 0: little endian
    parameter BKPT              = 4,   // Number of breakpoint comparators
    parameter DBG               = 1,   // Debug configuration
    parameter NUMIRQ            = 32,  // NUM of IRQ
    parameter SMUL              = 0,   // Multiplier configuration
    parameter SYST              = 1,   // SysTick
    parameter WIC               = 1,   // Wake-up interrupt controller support
    parameter WICLINES          = 34,  // Supported WIC lines
    parameter WPT               = 2,   // Number of DWT comparators
    parameter RESET_ALL_REGS    = 0,   // Do not reset all registers
    parameter INCLUDE_JTAG      = 0,   // Do not Include JTAG feature

    // Cortex-M0+ specific parameters
    parameter IOP               = 0,   // Single-cycle I/O port
    parameter VTOR              = 0,   // Vector Table Offset Register
    parameter MPU               = 0,   // Memory Protection Unit (0 or 8 regions)

    // ROM Table Base Address
    parameter [31:0] ROMTABLE_BASE = 32'hE00FF003,  // Defaultly Points to Core ROM Table

    // Bootrom 0 Parameters
    parameter    BOOTROM_ADDR_W    = 11,  // Size of Bootrom (Based on Address Width) - Default 2KB

    // IMEM 0 Parameters
    parameter    IMEM_RAM_ADDR_W   = 14,          // Width of IMEM RAM Address - Default 16KB
    parameter    IMEM_RAM_DATA_W   = 32,          // Width of IMEM RAM Data Bus - Default 32 bits
    parameter    IMEM_MEM_FPGA_IMG = "image.hex", // Image to Preload into SRAM

    // DMEM 0 Parameters
    parameter    DMEM_RAM_ADDR_W   = 14,          // Width of IMEM RAM Address - Default 16KB
    parameter    DMEM_RAM_DATA_W   = 32           // Width of IMEM RAM Data Bus - Default 32 bits
)(
    // System Input Clocks and Resets
    input  wire          sys_fclk,              // Free running clock
    input  wire          sys_sysresetn,         // System Reset
    input  wire          sys_scanenable,        // Scan Mode Enable
    input  wire          sys_testmode,          // Test Mode Enable (Override Synchronisers)

    // System Reset Request Signals
    input  wire          sys_sysresetreq,       // System Request from System Managers
    output wire          cpu_0_prmuresetreq,    // CPU Control Reset Request (PMU and Reset Unit)

    // Generated Clocks and Resets
    output wire          sys_poresetn,          // System Power On Reset
    output wire          sys_hclk,              // AHB Clock
    output wire          sys_hresetn,           // AHB and System reset

    // Power Management Signals
    input  wire          cpu_0_pmuenable,       // Power Management Enable
    output wire          cpu_0_pmudbgresetreq,  // Power Management Debug Reset Req

    // System Address Remap control (used by internal cpu_ss busmatrix)
    input  wire    [3:0] sys_remap_ctrl,

    // CPU 0 AHB master port -- system traffic out (>= 0x40000000)
    output wire   [31:0] cpu_0_haddr,
    output wire    [1:0] cpu_0_htrans,
    output wire          cpu_0_hwrite,
    output wire    [2:0] cpu_0_hsize,
    output wire    [2:0] cpu_0_hburst,
    output wire    [3:0] cpu_0_hprot,
    output wire   [31:0] cpu_0_hwdata,
    output wire          cpu_0_hmastlock,
    input  wire   [31:0] cpu_0_hrdata,
    input  wire          cpu_0_hready,
    input  wire          cpu_0_hresp,

    // cpu_ss AHB slave port -- single external slave interface
    input  wire          cpu_ss_hsel,
    input  wire   [31:0] cpu_ss_haddr,
    input  wire    [1:0] cpu_ss_htrans,
    input  wire          cpu_ss_hwrite,
    input  wire    [2:0] cpu_ss_hsize,
    input  wire    [2:0] cpu_ss_hburst,
    input  wire    [3:0] cpu_ss_hprot,
    input  wire   [31:0] cpu_ss_hwdata,
    input  wire          cpu_ss_hmastlock,
    output wire   [31:0] cpu_ss_hrdata,
    output wire          cpu_ss_hresp,
    output wire          cpu_ss_hreadyout,

    // Single-cycle I/O port (directly exposed, active when IOP=1)
    output wire   [31:0] cpu_0_ioaddr,
    output wire          cpu_0_iotrans,
    output wire          cpu_0_iowrite,
    output wire    [2:0] cpu_0_iosize,
    output wire   [31:0] cpu_0_iowdata,
    output wire    [3:0] cpu_0_ioprot,
    input  wire   [31:0] cpu_0_iordata,
    output wire          cpu_0_iomaster,

    // CPU Sideband signalling
    input  wire          cpu_0_nmi,
    input  wire   [31:0] cpu_0_irq,
    output wire          cpu_0_txev,
    input  wire          cpu_0_rxev,
    output wire          cpu_0_lockup,
    output wire          cpu_0_sysresetreq,

    output wire          cpu_0_sleeping,
    output wire          cpu_0_sleepdeep,

    // Serial-Wire Debug
    input  wire          cpu_0_swdi,
    input  wire          cpu_0_swclk,
    output wire          cpu_0_swdo,
    output wire          cpu_0_swdoen
);

    // -----------------------------------------------------------------------
    // Internal AHB wires: CPU core master bus
    // (routed through cpu_ss busmatrix)
    // -----------------------------------------------------------------------
    wire [31:0] i_cpu_0_haddr;
    wire  [1:0] i_cpu_0_htrans;
    wire        i_cpu_0_hwrite;
    wire  [2:0] i_cpu_0_hsize;
    wire  [2:0] i_cpu_0_hburst;
    wire  [3:0] i_cpu_0_hprot;
    wire [31:0] i_cpu_0_hwdata;
    wire        i_cpu_0_hmastlock;
    wire [31:0] i_cpu_0_hrdata;
    wire        i_cpu_0_hready;
    wire        i_cpu_0_hresp;

    // Internal AHB wires: busmatrix -> local memory targets
    // bootrom_0
    wire        i_bootrom_0_hsel;
    wire [31:0] i_bootrom_0_haddr;
    wire  [1:0] i_bootrom_0_htrans;
    wire        i_bootrom_0_hwrite;
    wire  [2:0] i_bootrom_0_hsize;
    wire  [2:0] i_bootrom_0_hburst;
    wire  [3:0] i_bootrom_0_hprot;
    wire [31:0] i_bootrom_0_hwdata;
    wire        i_bootrom_0_hmastlock;
    wire        i_bootrom_0_hreadymux;
    wire [31:0] i_bootrom_0_hrdata;
    wire        i_bootrom_0_hresp;
    wire        i_bootrom_0_hreadyout;
    // imem_0
    wire        i_imem_0_hsel;
    wire [31:0] i_imem_0_haddr;
    wire  [1:0] i_imem_0_htrans;
    wire        i_imem_0_hwrite;
    wire  [2:0] i_imem_0_hsize;
    wire  [2:0] i_imem_0_hburst;
    wire  [3:0] i_imem_0_hprot;
    wire [31:0] i_imem_0_hwdata;
    wire        i_imem_0_hmastlock;
    wire        i_imem_0_hreadymux;
    wire [31:0] i_imem_0_hrdata;
    wire        i_imem_0_hresp;
    wire        i_imem_0_hreadyout;
    // dmem_0
    wire        i_dmem_0_hsel;
    wire [31:0] i_dmem_0_haddr;
    wire  [1:0] i_dmem_0_htrans;
    wire        i_dmem_0_hwrite;
    wire  [2:0] i_dmem_0_hsize;
    wire  [2:0] i_dmem_0_hburst;
    wire  [3:0] i_dmem_0_hprot;
    wire [31:0] i_dmem_0_hwdata;
    wire        i_dmem_0_hmastlock;
    wire        i_dmem_0_hreadymux;
    wire [31:0] i_dmem_0_hrdata;
    wire        i_dmem_0_hresp;
    wire        i_dmem_0_hreadyout;

    // -------------------------------
    // CPU Core 0 Instantiation (Cortex-M0+)
    // -------------------------------
    slcorem0p #(
        .CLKGATE_PRESENT (CLKGATE_PRESENT),
        .BE              (BE),
        .BKPT            (BKPT),
        .DBG             (DBG),
        .INCLUDE_JTAG    (INCLUDE_JTAG),
        .NUMIRQ          (NUMIRQ),
        .RESET_ALL_REGS  (RESET_ALL_REGS),
        .SMUL            (SMUL),
        .SYST            (SYST),
        .WIC             (WIC),
        .WICLINES        (WICLINES),
        .WPT             (WPT),
        .ROMTABLE_BASE   (ROMTABLE_BASE),
        // M0+ specific
        .IOP             (IOP),
        .VTOR            (VTOR),
        .MPU             (MPU)
    ) u_cpu_0 (
        // System Input Clocks and Resets
        .SYS_FCLK(sys_fclk),
        .SYS_SYSRESETn(sys_sysresetn),
        .SYS_SCANENABLE(sys_scanenable),
        .SYS_TESTMODE(sys_testmode),

        // System Reset Request Signals
        .SYS_SYSRESETREQ(sys_sysresetreq),
        .CORE_PRMURESETREQ(cpu_0_prmuresetreq),

        // Generated Clocks and Resets
        .SYS_PORESETn(sys_poresetn),
        .SYS_HCLK(sys_hclk),
        .SYS_HRESETn(sys_hresetn),

        // Power Management Signals
        .CORE_PMUENABLE(cpu_0_pmuenable),
        .CORE_PMUDBGRESETREQ(cpu_0_pmudbgresetreq),

        // AHB Lite port -- internal wires to cpu_ss busmatrix
        .HADDR(i_cpu_0_haddr),
        .HTRANS(i_cpu_0_htrans),
        .HWRITE(i_cpu_0_hwrite),
        .HSIZE(i_cpu_0_hsize),
        .HBURST(i_cpu_0_hburst),
        .HPROT(i_cpu_0_hprot),
        .HWDATA(i_cpu_0_hwdata),
        .HMASTLOCK(i_cpu_0_hmastlock),
        .HRDATA(i_cpu_0_hrdata),
        .HREADY(i_cpu_0_hready),
        .HRESP(i_cpu_0_hresp),

        // Single-cycle I/O port
        .IOADDR(cpu_0_ioaddr),
        .IOTRANS(cpu_0_iotrans),
        .IOWRITE(cpu_0_iowrite),
        .IOSIZE(cpu_0_iosize),
        .IOWDATA(cpu_0_iowdata),
        .IOPROT(cpu_0_ioprot),
        .IORDATA(cpu_0_iordata),
        .IOMASTER(cpu_0_iomaster),

        // Sideband CPU signalling
        .CORE_NMI(cpu_0_nmi),
        .CORE_IRQ(cpu_0_irq),
        .CORE_TXEV(cpu_0_txev),
        .CORE_RXEV(cpu_0_rxev),
        .CORE_LOCKUP(cpu_0_lockup),
        .CORE_SYSRESETREQ(cpu_0_sysresetreq),

        .CORE_SLEEPING(cpu_0_sleeping),
        .CORE_SLEEPDEEP(cpu_0_sleepdeep),

        // Serial-Wire Debug
        .CORE_SWDI(cpu_0_swdi),
        .CORE_SWCLK(cpu_0_swclk),
        .CORE_SWDO(cpu_0_swdo),
        .CORE_SWDOEN(cpu_0_swdoen)
    );

    // -----------------------------------------------------------------------
    // CPU Subsystem Internal Busmatrix
    // 2-initiator (cpu_0, cpu_ss) x 4-target (bootrom_0, imem_0, dmem_0, system)
    // Reuses the same busmatrix as the M0 subsystem (address map is identical)
    // -----------------------------------------------------------------------
    nanosoc_cpu_ss_interconnect u_cpu_ss_busmatrix (
        // System Clocks, Resets and Control
        .sys_hclk       (sys_hclk),
        .sys_hresetn    (sys_hresetn),
        .sys_scanenable (sys_scanenable),
        .sys_scaninhclk (1'b0),
        .sys_scanouthclk(),
        .sys_remap_ctrl (sys_remap_ctrl),

        // CPU core master (cpu_0 initiator)
        .cpu_0_haddr     (i_cpu_0_haddr),
        .cpu_0_htrans    (i_cpu_0_htrans),
        .cpu_0_hwrite    (i_cpu_0_hwrite),
        .cpu_0_hsize     (i_cpu_0_hsize),
        .cpu_0_hburst    (i_cpu_0_hburst),
        .cpu_0_hprot     (i_cpu_0_hprot),
        .cpu_0_hwdata    (i_cpu_0_hwdata),
        .cpu_0_hmastlock (i_cpu_0_hmastlock),
        .cpu_0_hrdata    (i_cpu_0_hrdata),
        .cpu_0_hready    (i_cpu_0_hready),
        .cpu_0_hresp     (i_cpu_0_hresp),

        // External slave port (cpu_ss initiator)
        .cpu_ss_haddr     (cpu_ss_haddr),
        .cpu_ss_htrans    (cpu_ss_htrans),
        .cpu_ss_hwrite    (cpu_ss_hwrite),
        .cpu_ss_hsize     (cpu_ss_hsize),
        .cpu_ss_hburst    (cpu_ss_hburst),
        .cpu_ss_hprot     (cpu_ss_hprot),
        .cpu_ss_hwdata    (cpu_ss_hwdata),
        .cpu_ss_hmastlock (cpu_ss_hmastlock),
        .cpu_ss_hrdata    (cpu_ss_hrdata),
        .cpu_ss_hready    (cpu_ss_hreadyout),
        .cpu_ss_hresp     (cpu_ss_hresp),

        // bootrom_0 target
        .bootrom_0_hrdata    (i_bootrom_0_hrdata),
        .bootrom_0_hreadyout (i_bootrom_0_hreadyout),
        .bootrom_0_hresp     (i_bootrom_0_hresp),
        .bootrom_0_hsel      (i_bootrom_0_hsel),
        .bootrom_0_haddr     (i_bootrom_0_haddr),
        .bootrom_0_htrans    (i_bootrom_0_htrans),
        .bootrom_0_hwrite    (i_bootrom_0_hwrite),
        .bootrom_0_hsize     (i_bootrom_0_hsize),
        .bootrom_0_hburst    (i_bootrom_0_hburst),
        .bootrom_0_hprot     (i_bootrom_0_hprot),
        .bootrom_0_hwdata    (i_bootrom_0_hwdata),
        .bootrom_0_hmastlock (i_bootrom_0_hmastlock),
        .bootrom_0_hreadymux (i_bootrom_0_hreadymux),

        // imem_0 target
        .imem_0_hrdata    (i_imem_0_hrdata),
        .imem_0_hreadyout (i_imem_0_hreadyout),
        .imem_0_hresp     (i_imem_0_hresp),
        .imem_0_hsel      (i_imem_0_hsel),
        .imem_0_haddr     (i_imem_0_haddr),
        .imem_0_htrans    (i_imem_0_htrans),
        .imem_0_hwrite    (i_imem_0_hwrite),
        .imem_0_hsize     (i_imem_0_hsize),
        .imem_0_hburst    (i_imem_0_hburst),
        .imem_0_hprot     (i_imem_0_hprot),
        .imem_0_hwdata    (i_imem_0_hwdata),
        .imem_0_hmastlock (i_imem_0_hmastlock),
        .imem_0_hreadymux (i_imem_0_hreadymux),

        // dmem_0 target
        .dmem_0_hrdata    (i_dmem_0_hrdata),
        .dmem_0_hreadyout (i_dmem_0_hreadyout),
        .dmem_0_hresp     (i_dmem_0_hresp),
        .dmem_0_hsel      (i_dmem_0_hsel),
        .dmem_0_haddr     (i_dmem_0_haddr),
        .dmem_0_htrans    (i_dmem_0_htrans),
        .dmem_0_hwrite    (i_dmem_0_hwrite),
        .dmem_0_hsize     (i_dmem_0_hsize),
        .dmem_0_hburst    (i_dmem_0_hburst),
        .dmem_0_hprot     (i_dmem_0_hprot),
        .dmem_0_hwdata    (i_dmem_0_hwdata),
        .dmem_0_hmastlock (i_dmem_0_hmastlock),
        .dmem_0_hreadymux (i_dmem_0_hreadymux),

        // system target -> external master port
        .system_hrdata    (cpu_0_hrdata),
        .system_hreadyout (cpu_0_hready),
        .system_hresp     (cpu_0_hresp),
        .system_hsel      (),
        .system_haddr     (cpu_0_haddr),
        .system_htrans    (cpu_0_htrans),
        .system_hwrite    (cpu_0_hwrite),
        .system_hsize     (cpu_0_hsize),
        .system_hburst    (cpu_0_hburst),
        .system_hprot     (cpu_0_hprot),
        .system_hwdata    (cpu_0_hwdata),
        .system_hmastlock (cpu_0_hmastlock),
        .system_hreadymux ()
    );

    // ----------------------------------
    // CPU 0 Bootrom Region Instantiation
    // ----------------------------------
    nanosoc_region_bootrom_0 #(
        .SYS_ADDR_W      (SYS_ADDR_W),
        .SYS_DATA_W      (SYS_DATA_W),
        .BOOTROM_ADDR_W  (BOOTROM_ADDR_W)
    ) u_region_bootrom_0 (
        // Clock (No Reset on Bootrom)
        .HCLK(sys_hclk),

        // AHB connection to Initiator (via internal busmatrix)
        .HSEL(i_bootrom_0_hsel),
        .HADDR(i_bootrom_0_haddr),
        .HTRANS(i_bootrom_0_htrans),
        .HSIZE(i_bootrom_0_hsize),
        .HPROT(i_bootrom_0_hprot),
        .HWRITE(i_bootrom_0_hwrite),
        .HREADY(i_bootrom_0_hreadymux),
        .HWDATA(i_bootrom_0_hwdata),

        // Outputs
        .HREADYOUT(i_bootrom_0_hreadyout),
        .HRESP(i_bootrom_0_hresp),
        .HRDATA(i_bootrom_0_hrdata)
    );

    // -----------------------------------------------
    // CPU 0 Instruction Memory Region Instantiation
    // -----------------------------------------------
    nanosoc_region_imem_0 #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .IMEM_RAM_ADDR_W   (IMEM_RAM_ADDR_W),
        .IMEM_RAM_DATA_W   (IMEM_RAM_DATA_W),
        .IMEM_MEM_FPGA_IMG (IMEM_MEM_FPGA_IMG)
    ) u_region_imem_0 (
        // Clock and Reset
        .HCLK(sys_hclk),
        .HRESETn(sys_hresetn),

        // AHB connection to Initiator (via internal busmatrix)
        .HSEL(i_imem_0_hsel),
        .HADDR(i_imem_0_haddr),
        .HTRANS(i_imem_0_htrans),
        .HSIZE(i_imem_0_hsize),
        .HPROT(i_imem_0_hprot),
        .HWRITE(i_imem_0_hwrite),
        .HREADY(i_imem_0_hreadymux),
        .HWDATA(i_imem_0_hwdata),

        // Outputs
        .HREADYOUT(i_imem_0_hreadyout),
        .HRESP(i_imem_0_hresp),
        .HRDATA(i_imem_0_hrdata)
    );

    // ---------------------------------------
    // CPU 0 Data Memory Region Instantiation
    // ---------------------------------------
    nanosoc_region_dmem_0 #(
        .SYS_ADDR_W        (SYS_ADDR_W),
        .SYS_DATA_W        (SYS_DATA_W),
        .DMEM_RAM_ADDR_W   (DMEM_RAM_ADDR_W),
        .DMEM_RAM_DATA_W   (DMEM_RAM_DATA_W)
    ) u_region_dmem_0 (
        // Clock and Reset
        .HCLK(sys_hclk),
        .HRESETn(sys_hresetn),

        // AHB connection to Initiator (via internal busmatrix)
        .HSEL(i_dmem_0_hsel),
        .HADDR(i_dmem_0_haddr),
        .HTRANS(i_dmem_0_htrans),
        .HSIZE(i_dmem_0_hsize),
        .HPROT(i_dmem_0_hprot),
        .HWRITE(i_dmem_0_hwrite),
        .HREADY(i_dmem_0_hreadymux),
        .HWDATA(i_dmem_0_hwdata),

        // Outputs
        .HREADYOUT(i_dmem_0_hreadyout),
        .HRESP(i_dmem_0_hresp),
        .HRDATA(i_dmem_0_hrdata)
    );


endmodule
