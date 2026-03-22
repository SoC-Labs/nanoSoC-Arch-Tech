//-----------------------------------------------------------------------------
// NanoSoC System Control and Peripheral Subsystem
// - Contains Clock Control, Pin Mux, System Peripherals and System ROM table
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

module nanosoc_ss_systemctrl #(
    parameter    SYS_ADDR_W    = 32,  // System Address Width
    parameter    SYS_DATA_W    = 32,  // System Data Width
    parameter    APB_ADDR_W    = 12,  // APB Peripheral Address Width
    parameter    APB_DATA_W    = 32,  // APB Peripheral Data Width
    
    parameter    CLKGATE_PRESENT = 0
)(
    // Free-running and Crystal Clock Output
    input  wire                   SYS_CLK,              // System Input Clock
    output wire                   SYS_FCLK,             // Free-running system clock
    output wire                   SYS_XTALCLK_OUT,      // Crystal Clock Output
    
    // System Input Clocks and Resets
    input  wire                   SYS_SYSRESETn,        // System Reset
    input  wire                   SYS_PORESETn,         // Power-On-Reset reset (active-low)
    input  wire                   SYS_TESTMODE,         // Reset bypass in scan test
    input  wire                   SYS_HCLK,             // AHB clock
    input  wire                   SYS_HRESETn,          // AHB reset (active-low)

    // SOC_PERIPHERAL AHB interface
    input  wire                   SOC_PERIPHERAL_HSEL,           // AHB region select
    input  wire  [SYS_ADDR_W-1:0] SOC_PERIPHERAL_HADDR,          // AHB address
    input  wire            [ 2:0] SOC_PERIPHERAL_HBURST,         // AHB burst
    input  wire                   SOC_PERIPHERAL_HMASTLOCK,      // AHB lock
    input  wire            [ 3:0] SOC_PERIPHERAL_HPROT,          // AHB prot
    input  wire            [ 2:0] SOC_PERIPHERAL_HSIZE,          // AHB size
    input  wire            [ 1:0] SOC_PERIPHERAL_HTRANS,         // AHB transfer
    input  wire  [SYS_DATA_W-1:0] SOC_PERIPHERAL_HWDATA,         // AHB write data
    input  wire                   SOC_PERIPHERAL_HWRITE,         // AHB write
    input  wire                   SOC_PERIPHERAL_HREADY,         // AHB ready
    output  wire [SYS_DATA_W-1:0] SOC_PERIPHERAL_HRDATA,         // AHB read-data
    output  wire                  SOC_PERIPHERAL_HRESP,          // AHB response
    output  wire                  SOC_PERIPHERAL_HREADYOUT,      // AHB ready out
    
    // APB clocking control
    output wire                   SYS_PCLK,             // Peripheral clock
    output wire                   SYS_PCLKG,            // Gated Peripheral bus clock
    output wire                   SYS_PRESETn,          // Peripheral system and APB reset
    output wire                   SYS_PCLKEN,           // Clock divide control for AHB to APB bridge

    // APB external Slave Interfaces
    output wire                   SOC_PERIPHERAL_PENABLE,
    output wire                   SOC_PERIPHERAL_PWRITE,
    output wire  [APB_ADDR_W-1:0] SOC_PERIPHERAL_PADDR,
    output wire  [APB_DATA_W-1:0] SOC_PERIPHERAL_PWDATA,
    
    output wire                   USRT_PSEL,
    input  wire  [APB_DATA_W-1:0] USRT_PRDATA,
    input  wire                   USRT_PREADY,
    input  wire                   USRT_PSLVERR,

    // CPU sideband signalling
    output wire                   SYS_NMI,          // watchdog_interrupt;
    output wire           [31:0]  SYS_APB_IRQ,      // apbsubsys_interrupt;
    output wire           [15:0]  SYS_GPIO0_IRQ,    // GPIO 0 IRQs
    output wire           [15:0]  SYS_GPIO1_IRQ,    // GPIO 0 IRQs

    // CPU power/reset control
    output wire                   SYS_REMAP_CTRL,       // REMAP control bit
    output wire                   SYS_WDOGRESETREQ,     // Watchdog reset request
    output wire                   SYS_LOCKUPRESET,      // System Controller Config - Reset if lockup
    
    // System Reset Request Signals
    input  wire                   CPU_SYSRESETREQ,       // System Request from CPUs
    input  wire                   CPU_PRMURESETREQ,      // CPU Control Reset Request (PMU and Reset Unit)
    
    // Power Management Control and Status
    output wire                   SYS_PMUENABLE,        // System Controller cfg - Enable PMU
    input  wire                   SYS_PMUDBGRESETREQ,   // Power Management Debug Reset Req
    
    // CPU Status Signals
    input  wire                   CPU_LOCKUP,           // Processor status - Locked up
    input  wire                   CPU_SLEEPING,
    input  wire                   CPU_SLEEPDEEP,

    // USRT0 TXD axi byte stream
    output wire                   USRT0_TXD_TVALID,
    output wire           [ 7:0]  USRT0_TXD_TDATA,
    input  wire                   USRT0_TXD_TREADY,
    // USRT0 RXD axi byte stream
    input  wire                   USRT0_RXD_TVALID,
    input  wire           [ 7:0]  USRT0_RXD_TDATA,
    output wire                   USRT0_RXD_TREADY,
    // USRT1 TXD axi byte stream
    output wire                   USRT1_TXD_TVALID,
    output wire           [ 7:0]  USRT1_TXD_TDATA,
    input  wire                   USRT1_TXD_TREADY,
    // USRT1 RXD axi byte stream
    input  wire                   USRT1_RXD_TVALID,
    input  wire           [ 7:0]  USRT1_RXD_TDATA,
    output wire                   USRT1_RXD_TREADY,

    // GPIO
    input  wire            [15:0] P0_IN,            // GPIO 0 inputs
    output wire            [15:0] P0_OUT,           // GPIO 0 outputs
    output wire            [15:0] P0_OUTEN,         // GPIO 0 output enables
    output wire            [15:0] P0_ALTFUNC,       // GPIO 0 alternate function (pin mux)
    input  wire            [15:0] P1_IN,            // GPIO 1 inputs
    output wire            [15:0] P1_OUT,           // GPIO 1 outputs
    output wire            [15:0] P1_OUTEN,         // GPIO 1 output enables
    output wire            [15:0] P1_ALTFUNC,       // GPIO 1 alternate function (pin mux)
    output wire            [15:0] P1_OUT_MUX,       // GPIO 1 aOutput Port Drive
    output wire            [15:0] P1_OUT_EN_MUX     // Active High output drive enable (pad tech dependent)
);
    // -------------------------------
    // Internal Wiring
    // -------------------------------
    wire apbactive;

    wire uart2_rxd;        // Uart 2 receive data
    wire uart2_txd;        // Uart 2 transmit data
    wire uart2_txen;       // Uart 2 transmit data enable
    wire timer0_extin;     // Timer 0 external input
    wire timer1_extin;     // Timer 1 external input
    
    // -------------------------------
    // NanoSoC Clock Control Instantiation
    // -------------------------------
    nanosoc_clkctrl #(
        .CLKGATE_PRESENT  (CLKGATE_PRESENT)
    ) u_clkctrl(
        // inputs
        .XTAL1            (SYS_CLK),
        .NRST             (SYS_SYSRESETn),

        .APBACTIVE        (apbactive),
        .SLEEPING         (CPU_SLEEPING),
        .SLEEPDEEP        (CPU_SLEEPDEEP),
        .LOCKUP           (CPU_LOCKUP),
        .LOCKUPRESET      (SYS_LOCKUPRESET),
        .SYSRESETREQ      (CPU_PRMURESETREQ),
        .DBGRESETREQ      (SYS_PMUDBGRESETREQ),
        .CGBYPASS         (SYS_TESTMODE),
        .RSTBYPASS        (SYS_TESTMODE),

        // outputs
        .XTAL2            (SYS_XTALCLK_OUT),

        .FCLK             (SYS_FCLK),

        .PCLK             (SYS_PCLK),
        .PCLKG            (SYS_PCLKG),
        .PCLKEN           (SYS_PCLKEN),
        .PRESETn          (SYS_PRESETn)
    );
    
    // -------------------------------
    // NanoSoC Pin Mux Instantiation
    // -------------------------------
    nanosoc_pin_mux u_pin_mux (
        // UART
        .uart0_rxd        (    ),
        .uart0_txd        (1'b1),
        .uart0_txen       (1'b1),
        .uart1_rxd        (    ),
        .uart1_txd        (1'b1),
        .uart1_txen       (1'b1),
        .uart2_rxd        (uart2_rxd),
        .uart2_txd        (uart2_txd),
        .uart2_txen       (uart2_txen),

        // Timer
        .timer0_extin     (timer0_extin),
        .timer1_extin     (timer1_extin),

        // IO Ports
        .p0_in            ( ), // was (p0_in) now from pad inputs),
        .p0_out           (P0_OUT),
        .p0_outen         (P0_OUTEN),
        .p0_altfunc       (P0_ALTFUNC),

        .p1_in            ( ), // was(p1_in) now from pad inputs),
        .p1_out           (P1_OUT),
        .p1_outen         (P1_OUTEN),
        .p1_altfunc       (P1_ALTFUNC),

        // IO pads
        .p1_out_mux       (P1_OUT_MUX),
        .p1_out_en_mux    (P1_OUT_EN_MUX)
    );
    
    // -------------------------------
    // SOC_PERIPHERAL Region Instantiation
    // -------------------------------
    nanosoc_region_soc_peripheral #(
        .SYS_ADDR_W(SYS_ADDR_W),
        .SYS_DATA_W(SYS_DATA_W),
        .APB_ADDR_W(APB_ADDR_W),
        .APB_DATA_W(APB_DATA_W)
    ) u_region_soc_peripheral (
        // Clock and Reset
        .FCLK(SYS_FCLK),
        .PORESETn(SYS_PORESETn),

        // AHB interface
        .HCLK(SYS_HCLK),
        .HRESETn(SYS_HRESETn),
        .HSEL(SOC_PERIPHERAL_HSEL),
        .HADDR(SOC_PERIPHERAL_HADDR),
        .HBURST(SOC_PERIPHERAL_HBURST),
        .HMASTLOCK(SOC_PERIPHERAL_HMASTLOCK),
        .HPROT(SOC_PERIPHERAL_HPROT),
        .HSIZE(SOC_PERIPHERAL_HSIZE),
        .HTRANS(SOC_PERIPHERAL_HTRANS),
        .HWDATA(SOC_PERIPHERAL_HWDATA),
        .HWRITE(SOC_PERIPHERAL_HWRITE),
        .HREADY(SOC_PERIPHERAL_HREADY),
        .HRDATA(SOC_PERIPHERAL_HRDATA),
        .HRESP(SOC_PERIPHERAL_HRESP),
        .HREADYOUT(SOC_PERIPHERAL_HREADYOUT),

        // APB clocking control
        .PCLK(SYS_PCLK),
        .PCLKG(SYS_PCLKG),
        .PRESETn(SYS_PRESETn),
        .PCLKEN(SYS_PCLKEN),

        // APB external Slave Interface
        // Slots 12, 13, 15 no longer used (DMA config moved to dmac_ctrl region)
        .exp12_psel(),
        .exp13_psel(),
        .exp14_psel(USRT_PSEL),
        .exp15_psel(),
        .exp_penable(SOC_PERIPHERAL_PENABLE),
        .exp_pwrite(SOC_PERIPHERAL_PWRITE),
        .exp_paddr(SOC_PERIPHERAL_PADDR),
        .exp_pwdata(SOC_PERIPHERAL_PWDATA),
        .exp12_prdata(32'h00000000),
        .exp12_pready(1'b1),
        .exp12_pslverr(1'b0),
        .exp13_prdata(32'h00000000),
        .exp13_pready(1'b1),
        .exp13_pslverr(1'b0),
        .exp14_prdata(USRT_PRDATA),
        .exp14_pready(USRT_PREADY),
        .exp14_pslverr(USRT_PSLVERR),
        .exp15_prdata(32'h00000000),
        .exp15_pready(1'b1),
        .exp15_pslverr(1'b0),

        // CPU sideband signaling
        .SYS_NMI(SYS_NMI),
        .SYS_APB_IRQ(SYS_APB_IRQ),
        .SYS_GPIO0_IRQ(SYS_GPIO0_IRQ),
        .SYS_GPIO1_IRQ(SYS_GPIO1_IRQ),

        // CPU power/reset control
        .REMAP_CTRL(SYS_REMAP_CTRL),
        .APBACTIVE(apbactive),
        .SYSRESETREQ(CPU_SYSRESETREQ),
        .WDOGRESETREQ(SYS_WDOGRESETREQ),
        .LOCKUP(CPU_LOCKUP),
        .LOCKUPRESET(SYS_LOCKUPRESET),
        .PMUENABLE(SYS_PMUENABLE),

        // IO signaling
        // USRT0
        .usrt0_txd_tvalid (USRT0_TXD_TVALID),
        .usrt0_txd_tdata  (USRT0_TXD_TDATA ),
        .usrt0_txd_tready (USRT0_TXD_TREADY),
        .usrt0_rxd_tvalid (USRT0_RXD_TVALID),
        .usrt0_rxd_tdata  (USRT0_RXD_TDATA ),
        .usrt0_rxd_tready (USRT0_RXD_TREADY),
        
        // USRT1
        .usrt1_txd_tvalid (USRT1_TXD_TVALID),
        .usrt1_txd_tdata  (USRT1_TXD_TDATA ),
        .usrt1_txd_tready (USRT1_TXD_TREADY),
        .usrt1_rxd_tvalid (USRT1_RXD_TVALID),
        .usrt1_rxd_tdata  (USRT1_RXD_TDATA ),
        .usrt1_rxd_tready (USRT1_RXD_TREADY),
        
        // UART2
        .uart2_rxd(uart2_rxd),
        .uart2_txd(uart2_txd),
        .uart2_txen(uart2_txen),
        .timer0_extin(timer0_extin),
        .timer1_extin(timer1_extin),

        // GPIO
        .p0_in(P0_IN),
        .p0_out(P0_OUT),
        .p0_outen(P0_OUTEN),
        .p0_altfunc(P0_ALTFUNC),
        .p1_in(P1_IN),
        .p1_out(P1_OUT),
        .p1_outen(P1_OUTEN),
        .p1_altfunc(P1_ALTFUNC)
    );

endmodule
