//-----------------------------------------------------------------------------
// NanoSoC System Integration Level
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// Daniel Newbrook (d.newbrook@soton.ac.uk)
// David Flynn (d.w.flynn@soton.ac.uk)
//
// Copyright (C) 2023, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This module wraps the nanosoc core and connects the expansion region port
// (EXP) to nanosoc_region_exp, allowing custom accelerators to be substituted
// here by replacing or conditionally compiling nanosoc_region_exp.
//-----------------------------------------------------------------------------
module nanosoc_system #(
    // System Parameters
    parameter          SYS_ADDR_W            = 32,         // System Address Width
    parameter          SYS_DATA_W            = 32,         // System Data Width
    
    // Accelerator Expansion Region Parameters
    parameter          ACCELERATOR_SUBSYSTEM = 0,

    // Widths of System Peripheral APB Subsystem
    parameter          APB_ADDR_W           = 12,         // APB Peripheral Address Width
    parameter          APB_DATA_W           = 32,         // APB Peripheral Data Width

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

    // DMA Parameters
    parameter          DMAC_0_TYPE          = 0,          // DMAC 0 Controller Type: 0=None, 1=PL230, 2=DMA350
    parameter          DMAC_1_TYPE          = 0,          // DMAC 1 Controller Type: 0=None, 1=PL230
    parameter          DMAC_0_CHANNEL_NUM   = 4,          // DMAC 0 Number of DMA Channels : Add EXTDATA TX, RX
    parameter          DMAC_1_CHANNEL_NUM   = 2,          // DMAC 1 Number of DMA Channels

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
    input  wire                     SYS_CLK,              // System Input Clock
    input  wire                     SYS_SYSRESETn,        // System Reset
    output wire                     SYS_XTALCLK_OUT,      // Crystal Clock Output

    // Scan Wiring
    input  wire                     SYS_SCANENABLE,       // Scan Mode Enable
    input  wire                     SYS_TESTMODE,         // Test Mode Enable (Override Synchronisers)
    input  wire                     SYS_SCANINHCLK,       // HCLK scan input
    output wire                     SYS_SCANOUTHCLK,      // Scan Chain Output

    // Serial-Wire Debug
    input  wire                     CPU_0_SWDI,           // SWD data input
    input  wire                     CPU_0_SWCLK,          // SWD clock
    output wire                     CPU_0_SWDO,           // SWD data output
    output wire                     CPU_0_SWDOEN,         // SWD data output enable

    // GPIO
    input  wire              [15:0] P0_IN,               // GPIO 0 inputs
    output wire              [15:0] P0_OUT,              // GPIO 0 outputs
    output wire              [15:0] P0_OUTEN,            // GPIO 0 output enables
    input  wire              [15:0] P1_IN,               // GPIO 1 inputs
    output wire              [15:0] P1_OUT,              // GPIO 1 outputs
    output wire              [15:0] P1_OUTEN             // GPIO 1 output enables
);

    //--------------------------
    // Expansion Region Wiring
    // (between nanosoc core and nanosoc_region_exp)
    //--------------------------

    // AHB clock and reset from nanosoc core
    wire                     SYS_HCLK;
    wire                     SYS_HRESETn;

    // Expansion Region AHB Port
    wire                     EXP_HSEL;
    wire  [SYS_ADDR_W-1:0]   EXP_HADDR;
    wire             [1:0]   EXP_HTRANS;
    wire             [2:0]   EXP_HSIZE;
    wire             [3:0]   EXP_HPROT;
    wire                     EXP_HWRITE;
    wire                     EXP_HREADY;
    wire  [SYS_DATA_W-1:0]   EXP_HWDATA;
    wire             [2:0]   EXP_HBURST;
    wire                     EXP_HMASTLOCK;
    wire                     EXP_HREADYOUT;
    wire                     EXP_HRESP;
    wire  [SYS_DATA_W-1:0]   EXP_HRDATA;

    // DMA Stream 0
    wire                     EXP_STR_IN_0_TVALID;
    wire                     EXP_STR_IN_0_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_IN_0_TDATA;
    wire             [3:0]   EXP_STR_IN_0_TSTRB;
    wire                     EXP_STR_IN_0_TLAST;
    wire                     EXP_STR_OUT_0_TVALID;
    wire                     EXP_STR_OUT_0_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_OUT_0_TDATA;
    wire             [3:0]   EXP_STR_OUT_0_TSTRB;
    wire                     EXP_STR_OUT_0_TLAST;
    wire                     EXP_STR_OUT_0_FLUSH;

    // DMA Stream 1
    wire                     EXP_STR_IN_1_TVALID;
    wire                     EXP_STR_IN_1_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_IN_1_TDATA;
    wire             [3:0]   EXP_STR_IN_1_TSTRB;
    wire                     EXP_STR_IN_1_TLAST;
    wire                     EXP_STR_OUT_1_TVALID;
    wire                     EXP_STR_OUT_1_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_OUT_1_TDATA;
    wire             [3:0]   EXP_STR_OUT_1_TSTRB;
    wire                     EXP_STR_OUT_1_TLAST;
    wire                     EXP_STR_OUT_1_FLUSH;

    // DMA Stream 2
    wire                     EXP_STR_IN_2_TVALID;
    wire                     EXP_STR_IN_2_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_IN_2_TDATA;
    wire             [3:0]   EXP_STR_IN_2_TSTRB;
    wire                     EXP_STR_IN_2_TLAST;
    wire                     EXP_STR_OUT_2_TVALID;
    wire                     EXP_STR_OUT_2_TREADY;
    wire  [SYS_DATA_W-1:0]   EXP_STR_OUT_2_TDATA;
    wire             [3:0]   EXP_STR_OUT_2_TSTRB;
    wire                     EXP_STR_OUT_2_TLAST;
    wire                     EXP_STR_OUT_2_FLUSH;

    // Expansion Interrupt and DMA connections
    wire             [3:0]   EXP_IRQ;
    wire             [1:0]   EXP_DRQ;
    wire             [1:0]   EXP_DLAST;

    //--------------------------
    // NanoSoC Core Instantiation
    //--------------------------
    nanosoc #(
        .SYS_ADDR_W          (SYS_ADDR_W),
        .SYS_DATA_W          (SYS_DATA_W),
        .APB_ADDR_W          (APB_ADDR_W),
        .APB_DATA_W          (APB_DATA_W),
        .BOOTROM_ADDR_W      (BOOTROM_ADDR_W),
        .IMEM_RAM_ADDR_W     (IMEM_RAM_ADDR_W),
        .IMEM_RAM_DATA_W     (IMEM_RAM_DATA_W),
        .IMEM_MEM_FPGA_IMG   (IMEM_MEM_FPGA_IMG),
        .DMEM_RAM_ADDR_W     (DMEM_RAM_ADDR_W),
        .DMEM_RAM_DATA_W     (DMEM_RAM_DATA_W),
        .SRAM_0_RAM_ADDR_W (SRAM_0_RAM_ADDR_W),
        .SRAM_0_RAM_DATA_W (SRAM_0_RAM_DATA_W),
        .SRAM_1_RAM_ADDR_W (SRAM_1_RAM_ADDR_W),
        .SRAM_1_RAM_DATA_W (SRAM_1_RAM_DATA_W),
        .CLKGATE_PRESENT     (CLKGATE_PRESENT),
        .BE                  (BE),
        .BKPT                (BKPT),
        .DBG                 (DBG),
        .NUMIRQ              (NUMIRQ),
        .SMUL                (SMUL),
        .SYST                (SYST),
        .WIC                 (WIC),
        .WICLINES            (WICLINES),
        .WPT                 (WPT),
        .RESET_ALL_REGS      (RESET_ALL_REGS),
        .INCLUDE_JTAG        (INCLUDE_JTAG),
        .DMAC_0_TYPE         (DMAC_0_TYPE),
        .DMAC_1_TYPE         (DMAC_1_TYPE),
        .DMAC_0_CHANNEL_NUM  (DMAC_0_CHANNEL_NUM),
        .DMAC_1_CHANNEL_NUM  (DMAC_1_CHANNEL_NUM),
        .PROMPT_CHAR         (PROMPT_CHAR),
        .FT1248_WIDTH        (FT1248_WIDTH),
        .FT1248_CLKON        (FT1248_CLKON),
        .FT1248_CLKDIV       (FT1248_CLKDIV),
        .SYSTABLE_BASE       (SYSTABLE_BASE),
        .SOCLABS_JEPID       (SOCLABS_JEPID),
        .NANOSOC_PARTNUMBER  (NANOSOC_PARTNUMBER),
        .NANOSOC_REVISION    (NANOSOC_REVISION)
    ) u_nanosoc (
        // Clocks and Resets
        .sys_clk             (SYS_CLK),
        .sys_sysresetn       (SYS_SYSRESETn),
        .sys_xtalclk_out     (SYS_XTALCLK_OUT),

        // Scan
        .sys_scanenable      (SYS_SCANENABLE),
        .sys_testmode        (SYS_TESTMODE),
        .sys_scaninhclk      (SYS_SCANINHCLK),
        .sys_scanouthclk     (SYS_SCANOUTHCLK),

        // Serial-Wire Debug
        .cpu_0_swdi          (CPU_0_SWDI),
        .cpu_0_swclk         (CPU_0_SWCLK),
        .cpu_0_swdo          (CPU_0_SWDO),
        .cpu_0_swdoen        (CPU_0_SWDOEN),

        // GPIO
        .p0_in               (P0_IN),
        .p0_out              (P0_OUT),
        .p0_outen            (P0_OUTEN),
        .p1_in               (P1_IN),
        .p1_out              (P1_OUT),
        .p1_outen            (P1_OUTEN),

        // Generated AHB clock and reset
        .sys_hclk            (SYS_HCLK),
        .sys_hresetn         (SYS_HRESETn),

        // Expansion Region AHB Port
        .exp_hsel            (EXP_HSEL),
        .exp_haddr           (EXP_HADDR),
        .exp_htrans          (EXP_HTRANS),
        .exp_hsize           (EXP_HSIZE),
        .exp_hprot           (EXP_HPROT),
        .exp_hwrite          (EXP_HWRITE),
        .exp_hready          (EXP_HREADY),
        .exp_hwdata          (EXP_HWDATA),
        .exp_hburst          (EXP_HBURST),
        .exp_hmastlock       (EXP_HMASTLOCK),
        .exp_hreadyout       (EXP_HREADYOUT),
        .exp_hresp           (EXP_HRESP),
        .exp_hrdata          (EXP_HRDATA),

        // DMA Stream 0
        .exp_str_in_0_tvalid  (EXP_STR_IN_0_TVALID),
        .exp_str_in_0_tready  (EXP_STR_IN_0_TREADY),
        .exp_str_in_0_tdata   (EXP_STR_IN_0_TDATA),
        .exp_str_in_0_tstrb   (EXP_STR_IN_0_TSTRB),
        .exp_str_in_0_tlast   (EXP_STR_IN_0_TLAST),
        .exp_str_out_0_tvalid (EXP_STR_OUT_0_TVALID),
        .exp_str_out_0_tready (EXP_STR_OUT_0_TREADY),
        .exp_str_out_0_tdata  (EXP_STR_OUT_0_TDATA),
        .exp_str_out_0_tstrb  (EXP_STR_OUT_0_TSTRB),
        .exp_str_out_0_tlast  (EXP_STR_OUT_0_TLAST),
        .exp_str_out_0_flush  (EXP_STR_OUT_0_FLUSH),

        // DMA Stream 1
        .exp_str_in_1_tvalid  (EXP_STR_IN_1_TVALID),
        .exp_str_in_1_tready  (EXP_STR_IN_1_TREADY),
        .exp_str_in_1_tdata   (EXP_STR_IN_1_TDATA),
        .exp_str_in_1_tstrb   (EXP_STR_IN_1_TSTRB),
        .exp_str_in_1_tlast   (EXP_STR_IN_1_TLAST),
        .exp_str_out_1_tvalid (EXP_STR_OUT_1_TVALID),
        .exp_str_out_1_tready (EXP_STR_OUT_1_TREADY),
        .exp_str_out_1_tdata  (EXP_STR_OUT_1_TDATA),
        .exp_str_out_1_tstrb  (EXP_STR_OUT_1_TSTRB),
        .exp_str_out_1_tlast  (EXP_STR_OUT_1_TLAST),
        .exp_str_out_1_flush  (EXP_STR_OUT_1_FLUSH),

        // DMA Stream 2
        .exp_str_in_2_tvalid  (EXP_STR_IN_2_TVALID),
        .exp_str_in_2_tready  (EXP_STR_IN_2_TREADY),
        .exp_str_in_2_tdata   (EXP_STR_IN_2_TDATA),
        .exp_str_in_2_tstrb   (EXP_STR_IN_2_TSTRB),
        .exp_str_in_2_tlast   (EXP_STR_IN_2_TLAST),
        .exp_str_out_2_tvalid (EXP_STR_OUT_2_TVALID),
        .exp_str_out_2_tready (EXP_STR_OUT_2_TREADY),
        .exp_str_out_2_tdata  (EXP_STR_OUT_2_TDATA),
        .exp_str_out_2_tstrb  (EXP_STR_OUT_2_TSTRB),
        .exp_str_out_2_tlast  (EXP_STR_OUT_2_TLAST),
        .exp_str_out_2_flush  (EXP_STR_OUT_2_FLUSH),

        // Expansion Interrupt and DMA Connections
        .exp_irq             (EXP_IRQ),
        .exp_drq             (EXP_DRQ),
        .exp_dlast           (EXP_DLAST)
    );

    //--------------------------
    // Expansion Region Instantiation
    //--------------------------
    nanosoc_region_exp #(
        .SYS_ADDR_W            (SYS_ADDR_W),
        .SYS_DATA_W            (SYS_DATA_W),
        .ACCELERATOR_SUBSYSTEM (ACCELERATOR_SUBSYSTEM)
    ) u_region_exp (
        .HCLK                (SYS_HCLK),
        .HRESETn             (SYS_HRESETn),

        // AHB Subordinate Port
        .HSEL                (EXP_HSEL),
        .HADDR               (EXP_HADDR),
        .HTRANS              (EXP_HTRANS),
        .HSIZE               (EXP_HSIZE),
        .HPROT               (EXP_HPROT),
        .HWRITE              (EXP_HWRITE),
        .HREADY              (EXP_HREADY),
        .HWDATA              (EXP_HWDATA),
        .HREADYOUT           (EXP_HREADYOUT),
        .HRESP               (EXP_HRESP),
        .HRDATA              (EXP_HRDATA),

        // DMA Stream 0
        .EXP_STR_IN_0_TVALID  (EXP_STR_IN_0_TVALID),
        .EXP_STR_IN_0_TREADY  (EXP_STR_IN_0_TREADY),
        .EXP_STR_IN_0_TDATA   (EXP_STR_IN_0_TDATA),
        .EXP_STR_IN_0_TSTRB   (EXP_STR_IN_0_TSTRB),
        .EXP_STR_IN_0_TLAST   (EXP_STR_IN_0_TLAST),
        .EXP_STR_OUT_0_TVALID (EXP_STR_OUT_0_TVALID),
        .EXP_STR_OUT_0_TREADY (EXP_STR_OUT_0_TREADY),
        .EXP_STR_OUT_0_TDATA  (EXP_STR_OUT_0_TDATA),
        .EXP_STR_OUT_0_TSTRB  (EXP_STR_OUT_0_TSTRB),
        .EXP_STR_OUT_0_TLAST  (EXP_STR_OUT_0_TLAST),
        .EXP_STR_OUT_0_FLUSH  (EXP_STR_OUT_0_FLUSH),

        // DMA Stream 1
        .EXP_STR_IN_1_TVALID  (EXP_STR_IN_1_TVALID),
        .EXP_STR_IN_1_TREADY  (EXP_STR_IN_1_TREADY),
        .EXP_STR_IN_1_TDATA   (EXP_STR_IN_1_TDATA),
        .EXP_STR_IN_1_TSTRB   (EXP_STR_IN_1_TSTRB),
        .EXP_STR_IN_1_TLAST   (EXP_STR_IN_1_TLAST),
        .EXP_STR_OUT_1_TVALID (EXP_STR_OUT_1_TVALID),
        .EXP_STR_OUT_1_TREADY (EXP_STR_OUT_1_TREADY),
        .EXP_STR_OUT_1_TDATA  (EXP_STR_OUT_1_TDATA),
        .EXP_STR_OUT_1_TSTRB  (EXP_STR_OUT_1_TSTRB),
        .EXP_STR_OUT_1_TLAST  (EXP_STR_OUT_1_TLAST),
        .EXP_STR_OUT_1_FLUSH  (EXP_STR_OUT_1_FLUSH),

        // DMA Stream 2
        .EXP_STR_IN_2_TVALID  (EXP_STR_IN_2_TVALID),
        .EXP_STR_IN_2_TREADY  (EXP_STR_IN_2_TREADY),
        .EXP_STR_IN_2_TDATA   (EXP_STR_IN_2_TDATA),
        .EXP_STR_IN_2_TSTRB   (EXP_STR_IN_2_TSTRB),
        .EXP_STR_IN_2_TLAST   (EXP_STR_IN_2_TLAST),
        .EXP_STR_OUT_2_TVALID (EXP_STR_OUT_2_TVALID),
        .EXP_STR_OUT_2_TREADY (EXP_STR_OUT_2_TREADY),
        .EXP_STR_OUT_2_TDATA  (EXP_STR_OUT_2_TDATA),
        .EXP_STR_OUT_2_TSTRB  (EXP_STR_OUT_2_TSTRB),
        .EXP_STR_OUT_2_TLAST  (EXP_STR_OUT_2_TLAST),
        .EXP_STR_OUT_2_FLUSH  (EXP_STR_OUT_2_FLUSH),

        // Interrupt and DMAC Connections
        .EXP_IRQ             (EXP_IRQ),
        .EXP_DRQ             (EXP_DRQ),
        .EXP_DLAST           (EXP_DLAST)
    );

endmodule
