//-----------------------------------------------------------------------------
// Nanosoc System Peripheral Region (SOC_PERIPHERAL)
// - Region Mapped to: 0x40000000-0x4fffffff
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
// David Flynn    (d.w.flynn@soton.ac.uk)
//
// Copyright 2021-6, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
module nanosoc_region_soc_peripheral #(
    parameter    SYS_ADDR_W=32,  // System Address Width
    parameter    SYS_DATA_W=32,  // System Data Width
    parameter    APB_ADDR_W=12,  // APB Peripheral Address Width
    parameter    APB_DATA_W=32   // APB Peripheral Data Width
  )(
    input  wire                   FCLK,             // Free-running system clock
    input  wire                   PORESETn,         // Power-On-Reset reset (active-low)
    
    // AHB interface
    input  wire                   HCLK,             // AHB clock
    input  wire                   HRESETn,          // AHB reset (active-low)
    input  wire                   HSEL,             // AHB region select
    input  wire  [SYS_ADDR_W-1:0] HADDR,            // AHB address
    input  wire            [ 2:0] HBURST,           // AHB burst
    input  wire                   HMASTLOCK,        // AHB lock
    input  wire            [ 3:0] HPROT,            // AHB prot
    input  wire            [ 2:0] HSIZE,            // AHB size
    input  wire            [ 1:0] HTRANS,           // AHB transfer
    input  wire  [SYS_DATA_W-1:0] HWDATA,           // AHB write data
    input  wire                   HWRITE,           // AHB write
    input  wire                   HREADY,           // AHB ready
    output wire  [SYS_DATA_W-1:0] HRDATA,           // AHB read-data
    output wire                   HRESP,            // AHB response
    output wire                   HREADYOUT,        // AHB ready out
    
    // APB clocking control
    input  wire                   PCLK,             // Peripheral clock
    input  wire                   PCLKG,            // Gated Peripheral bus clock
    input  wire                   PRESETn,          // Peripheral system and APB reset
    input  wire                   PCLKEN,           // Clock divide control for AHB to APB bridge
    
    // APB external Slave Interface
    output wire                   exp12_psel,
    output wire                   exp13_psel,
    output wire                   exp14_psel,
    output wire                   exp15_psel,
    output wire                   exp_penable,
    output wire                   exp_pwrite,
    output wire  [APB_ADDR_W-1:0] exp_paddr,
    output wire  [APB_DATA_W-1:0] exp_pwdata,
    input  wire  [APB_DATA_W-1:0] exp12_prdata,
    input  wire                   exp12_pready,
    input  wire                   exp12_pslverr,
    input  wire  [APB_DATA_W-1:0] exp13_prdata,
    input  wire                   exp13_pready,
    input  wire                   exp13_pslverr,
    input  wire  [APB_DATA_W-1:0] exp14_prdata,
    input  wire                   exp14_pready,
    input  wire                   exp14_pslverr,
    input  wire  [APB_DATA_W-1:0] exp15_prdata,
    input  wire                   exp15_pready,
    input  wire                   exp15_pslverr,

    // CPU sideband signalling
    output wire                 SYS_NMI,          // watchdog_interrupt;
    output wire         [31:0]  SYS_APB_IRQ,      // apbsubsys_interrupt;
    output wire         [15:0]  SYS_GPIO0_IRQ,    // GPIO 0 irqs
    output wire         [15:0]  SYS_GPIO1_IRQ,    // GPIO 0 irqs
    
    // CPU power/reset control
    output wire          [3:0]  REMAP_CTRL,       // REMAP control bit
    output wire                 APBACTIVE,        // APB bus active (for clock gating of PCLKG)
    input  wire                 SYSRESETREQ,      // Processor control - system reset request
    output wire                 WDOGRESETREQ,     // Watchdog reset request
    input  wire                 LOCKUP,           // Processor status - Locked up
    output wire                 LOCKUPRESET,      // System Controller cfg - reset if lockup
    output wire                 PMUENABLE,        // System Controller cfg - Enable PMU

    // USRT0 TXD axi byte stream
    output wire                   usrt0_txd_tvalid,
    output wire           [ 7:0]  usrt0_txd_tdata,
    input  wire                   usrt0_txd_tready,
    // USRT0 RXD axi byte stream
    input  wire                   usrt0_rxd_tvalid,
    input  wire           [ 7:0]  usrt0_rxd_tdata,
    output wire                   usrt0_rxd_tready,

    // USRT1 TXD axi byte stream
    output wire                   usrt1_txd_tvalid,
    output wire           [ 7:0]  usrt1_txd_tdata,
    input  wire                   usrt1_txd_tready,
    // USRT1 RXD axi byte stream
    input  wire                   usrt1_rxd_tvalid,
    input  wire           [ 7:0]  usrt1_rxd_tdata,
    output wire                   usrt1_rxd_tready,
    //UART2
    input  wire                 uart2_rxd,        // Uart 2 receive data
    output wire                 uart2_txd,        // Uart 2 transmit data
    output wire                 uart2_txen,       // Uart 2 transmit data enable
    input  wire                 timer0_extin,     // Timer 0 external input
    input  wire                 timer1_extin,     // Timer 1 external input

    // GPIO
    input  wire          [15:0] p0_in,            // GPIO 0 inputs
    output wire          [15:0] p0_out,           // GPIO 0 outputs
    output wire          [15:0] p0_outen,         // GPIO 0 output enables
    output wire          [15:0] p0_altfunc,       // GPIO 0 alternate function (pin mux)
    input  wire          [15:0] p1_in,            // GPIO 1 inputs
    output wire          [15:0] p1_out,           // GPIO 1 outputs
    output wire          [15:0] p1_outen,         // GPIO 1 output enables
    output wire          [15:0] p1_altfunc        // GPIO 1 alternate function (pin mux)
  );

  // Sysctrl base address
  localparam BASEADDR_APBSS       = 32'h4000_0000; // GPIO0 peripheral base address
  localparam BASEADDR_GPIO0       = 32'h4001_0000; // GPIO0 peripheral base address
  localparam BASEADDR_GPIO1       = 32'h4001_1000; // GPIO1 peripheral base address
  localparam BASEADDR_SYSCTRL     = 32'h4001_f000; // Sysctrl peripheral base address
  localparam BASEADDR_ADC         = 32'h4002_0000; // ADC Peripheral base address
  
   // ------------------------------------------------------------
   // Local wires
   // ------------------------------------------------------------

  wire                        defslv_hsel;   // AHB default slave signals
  wire                        defslv_hreadyout;
  wire     [SYS_DATA_W-1:0]   defslv_hrdata;
  wire                        defslv_hresp;

  wire                        apbsys_hsel;  // APB subsystem AHB interface signals
  wire                        apbsys_hreadyout;
  wire     [SYS_DATA_W-1:0]   apbsys_hrdata;
  wire                        apbsys_hresp;

  wire                        gpio0_hsel;   // AHB GPIO bus interface signals
  wire                        gpio0_hreadyout;
  wire     [SYS_DATA_W-1:0]   gpio0_hrdata;
  wire                        gpio0_hresp;

  wire                        gpio1_hsel;   // AHB GPIO bus interface signals
  wire                        gpio1_hreadyout;
  wire     [SYS_DATA_W-1:0]   gpio1_hrdata;
  wire                        gpio1_hresp;

  wire                        sysctrl_hsel;  // System control bus interface signals
  wire                        sysctrl_hreadyout;
  wire     [SYS_DATA_W-1:0]   sysctrl_hrdata;
  wire                        sysctrl_hresp;

  wire                        adcsys_hsel;  // ADC subsystem AHB interface signals
  wire                        adcsys_hreadyout;
  wire     [SYS_DATA_W-1:0]   adcsys_hrdata;
  wire                        adcsys_hresp;

  wire                        pvtsys_hsel;  // ADC subsystem AHB interface signals
  wire                        pvtsys_hreadyout;
  wire     [SYS_DATA_W-1:0]   pvtsys_hrdata;
  wire                        pvtsys_hresp;


  // AHB address decode
  nanosoc_soc_peripheral_decode #(
     .BASEADDR_APBSS       (BASEADDR_APBSS),
     .BASEADDR_GPIO0       (BASEADDR_GPIO0),
     .BASEADDR_GPIO1       (BASEADDR_GPIO1),
     .BASEADDR_SYSCTRL     (BASEADDR_SYSCTRL),
     .BASEADDR_ADC         (BASEADDR_ADC)
  ) u_addr_decode (
    // System Address
    .hsel         (HSEL),
    .haddr        (HADDR),
    .apbsys_hsel  (apbsys_hsel),
    .gpio0_hsel   (gpio0_hsel),
    .gpio1_hsel   (gpio1_hsel),
    .sysctrl_hsel (sysctrl_hsel),
    .defslv_hsel  (defslv_hsel)
  );

  // AHB slave multiplexer
  cmsdk_ahb_slave_mux #(
    .PORT0_ENABLE  (1), // APB subsystem bridge
    .PORT1_ENABLE  (1), // GPIO Port 0
    .PORT2_ENABLE  (1), // GPIO Port 1
    .PORT3_ENABLE  (1), // SYS control
    .PORT4_ENABLE  (1), // Default
    .PORT5_ENABLE  (0), // ADC Region
    .PORT6_ENABLE  (0), // Synopsys PVT monitoring region
    .PORT7_ENABLE  (0),
    .PORT8_ENABLE  (0),
    .PORT9_ENABLE  (0),
    .DW            (32)
  ) u_ahb_slave_mux_sys_bus (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HREADY       (HREADY),
    .HSEL0        (apbsys_hsel),     // Input Port 0
    .HREADYOUT0   (apbsys_hreadyout),
    .HRESP0       (apbsys_hresp),
    .HRDATA0      (apbsys_hrdata),
    .HSEL1        (gpio0_hsel),      // Input Port 1
    .HREADYOUT1   (gpio0_hreadyout),
    .HRESP1       (gpio0_hresp),
    .HRDATA1      (gpio0_hrdata),
    .HSEL2        (gpio1_hsel),      // Input Port 2
    .HREADYOUT2   (gpio1_hreadyout),
    .HRESP2       (gpio1_hresp),
    .HRDATA2      (gpio1_hrdata),
    .HSEL3        (sysctrl_hsel),    // Input Port 3
    .HREADYOUT3   (sysctrl_hreadyout),
    .HRESP3       (sysctrl_hresp),
    .HRDATA3      (sysctrl_hrdata),
    .HSEL4        (defslv_hsel),     // Input Port 4
    .HREADYOUT4   (defslv_hreadyout),
    .HRESP4       (defslv_hresp),
    .HRDATA4      (defslv_hrdata),
    .HSEL5        (adcsys_hsel),     // Input Port 5
    .HREADYOUT5   (adcsys_hreadyout),
    .HRESP5       (adcsys_hresp),
    .HRDATA5      (adcsys_hrdata),
    .HSEL6        (pvtsys_hsel),     // Input Port 6
    .HREADYOUT6   (pvtsys_hreadyout),
    .HRESP6       (pvtsys_hresp),
    .HRDATA6      (pvtsys_hrdata),
    .HSEL7        (1'b0),     // Input Port 7
    .HREADYOUT7   (defslv_hreadyout),
    .HRESP7       (defslv_hresp),
    .HRDATA7      (defslv_hrdata),
    .HSEL8        (1'b0),     // Input Port 8
    .HREADYOUT8   (defslv_hreadyout),
    .HRESP8       (defslv_hresp),
    .HRDATA8      (defslv_hrdata),
    .HSEL9        (1'b0),     // Input Port 9
    .HREADYOUT9   (defslv_hreadyout),
    .HRESP9       (defslv_hresp),
    .HRDATA9      (defslv_hrdata),

    .HREADYOUT    (HREADYOUT),   // Outputs
    .HRESP        (HRESP),
    .HRDATA       (HRDATA)
  );

  // Default slave
  cmsdk_ahb_default_slave u_ahb_default_slave_1 (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HSEL         (defslv_hsel),
    .HTRANS       (HTRANS),
    .HREADY       (HREADY),
    .HREADYOUT    (defslv_hreadyout),
    .HRESP        (defslv_hresp)
  );

  assign   defslv_hrdata = 32'h00000000; // Default slave do not have read data

  // -------------------------------
  // Peripherals
  // -------------------------------

  nanosoc_sysctrl u_sysctrl (
    // AHB Inputs
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .FCLK         (FCLK),
    .PORESETn     (PORESETn),
    .HSEL         (sysctrl_hsel),
    .HREADY       (HREADY),
    .HTRANS       (HTRANS),
    .HSIZE        (HSIZE),
    .HWRITE       (HWRITE),
    .HADDR        (HADDR[11:0]),
    .HWDATA       (HWDATA),
    
    // AHB Outputs
    .HREADYOUT    (sysctrl_hreadyout),
    .HRESP        (sysctrl_hresp),
    .HRDATA       (sysctrl_hrdata),
    
    // Reset information
    .SYSRESETREQ  (SYSRESETREQ),
    .WDOGRESETREQ (WDOGRESETREQ),
    .LOCKUP       (LOCKUP),
    
    // Engineering-change-order revision bits
    .ECOREVNUM    (4'h0),
    
    // System control signals
    .REMAP        (REMAP_CTRL),
    .PMUENABLE    (PMUENABLE),
    .LOCKUPRESET  (LOCKUPRESET)
   );

  // GPIO is driven from the AHB
  cmsdk_ahb_gpio #(
    .ALTERNATE_FUNC_MASK     (16'h0000), // No pin muxing for Port #0
    .ALTERNATE_FUNC_DEFAULT  (16'h0000)  // All pins default to GPIO
  ) u_gpio_0  (
   // AHB Inputs
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .FCLK         (FCLK),
    .HSEL         (gpio0_hsel),
    .HREADY       (HREADY),
    .HTRANS       (HTRANS),
    .HSIZE        (HSIZE),
    .HWRITE       (HWRITE),
    .HADDR        (HADDR[11:0]),
    .HWDATA       (HWDATA),
    
    // AHB Outputs
    .HREADYOUT    (gpio0_hreadyout),
    .HRESP        (gpio0_hresp),
    .HRDATA       (gpio0_hrdata),

    // Engineering-change-order revision bits
    .ECOREVNUM    (4'h0),

    .PORTIN       (p0_in),   // GPIO Interface inputs
    .PORTOUT      (p0_out),  // GPIO Interface outputs
    .PORTEN       (p0_outen),
    .PORTFUNC     (p0_altfunc), // Alternate function control

    .GPIOINT      (SYS_GPIO0_IRQ[15:0]),  // Interrupt outputs
    .COMBINT      ()
  );

  cmsdk_ahb_gpio #(
    .ALTERNATE_FUNC_MASK     (16'h002A), // pin muxing for Port #1
    .ALTERNATE_FUNC_DEFAULT  (16'h0000)  // All pins default to GPIO
  ) u_gpio_1 (
   // AHB Inputs
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .FCLK         (FCLK),
    .HSEL         (gpio1_hsel),
    .HREADY       (HREADY),
    .HTRANS       (HTRANS),
    .HSIZE        (HSIZE),
    .HWRITE       (HWRITE),
    .HADDR        (HADDR[11:0]),
    .HWDATA       (HWDATA),
    
    // AHB Outputs
    .HREADYOUT    (gpio1_hreadyout),
    .HRESP        (gpio1_hresp),
    .HRDATA       (gpio1_hrdata),

    // Engineering-change-order revision bits
    .ECOREVNUM    (4'h0),

    .PORTIN       (p1_in),   // GPIO Interface inputs
    .PORTOUT      (p1_out),  // GPIO Interface outputs
    .PORTEN       (p1_outen),
    .PORTFUNC     (p1_altfunc), // Alternate function control

    .GPIOINT      (SYS_GPIO1_IRQ[15:0]),  // Interrupt outputs
    .COMBINT      ( )
  );

  // -----------------------------------------------------------------
  // Discovery table — auto-generated bus topology registers at 0x4000_D000
  // -----------------------------------------------------------------
  wire        discovery_psel;
  wire [31:0] discovery_prdata;
  wire        discovery_pready;
  wire        discovery_pslverr;

  nanosoc_ahb_interconnect_discovery_apb_wrapper u_discovery (
    .PCLK    (PCLK),
    .PRESETn (PRESETn),
    .PSEL    (discovery_psel),
    .PENABLE (exp_penable),
    .PWRITE  (exp_pwrite),
    .PADDR   (exp_paddr),
    .PWDATA  (exp_pwdata),
    .PRDATA  (discovery_prdata),
    .PREADY  (discovery_pready),
    .PSLVERR (discovery_pslverr)
  );

  // APB subsystem for timers, UARTs
  nanosoc_soc_peripheral_apb_ss #(
    .APB_EXT_PORT12_ENABLE   (0), // No longer used (DMA config in dmac_ctrl region)
    .APB_EXT_PORT13_ENABLE   (1), // Discovery table (auto-generated bus topology registers)
    .APB_EXT_PORT14_ENABLE   (1), // USRT
    .APB_EXT_PORT15_ENABLE   (0)  // No longer used (DMA config in dmac_ctrl region)
  ) u_soc_peripheral_apb_ss (
    // AHB interface for AHB to APB bridge
    .HCLK          (HCLK),
    .HRESETn       (HRESETn),

    .HSEL          (apbsys_hsel),
    .HADDR         (HADDR[15:0]),
    .HTRANS        (HTRANS[1:0]),
    .HWRITE        (HWRITE),
    .HSIZE         (HSIZE),
    .HPROT         (HPROT),
    .HREADY        (HREADY),
    .HWDATA        (HWDATA[31:0]),

    .HREADYOUT     (apbsys_hreadyout),
    .HRDATA        (apbsys_hrdata),
    .HRESP         (apbsys_hresp),

    // APB clock and reset
    .PCLK          (PCLK),
    .PCLKG         (PCLKG),
    .PCLKEN        (PCLKEN),
    .PRESETn       (PRESETn),

    // APB extension ports
    .PADDR         (exp_paddr[11:0]),
    .PWRITE        (exp_pwrite),
    .PWDATA        (exp_pwdata[31:0]),
    .PENABLE       (exp_penable),

    .ext12_psel    (exp12_psel),
    .ext13_psel    (discovery_psel),
    .ext14_psel    (exp14_psel),
    .ext15_psel    (exp15_psel),

    // Input from APB devices on APB expansion ports
    .ext12_prdata  (exp12_prdata),
    .ext12_pready  (exp12_pready),
    .ext12_pslverr (exp12_pslverr),
    .ext13_prdata  (discovery_prdata),
    .ext13_pready  (discovery_pready),
    .ext13_pslverr (discovery_pslverr),
    .ext14_prdata  (exp14_prdata),
    .ext14_pready  (exp14_pready),
    .ext14_pslverr (exp14_pslverr),
    .ext15_prdata  (exp15_prdata),
    .ext15_pready  (exp15_pready),
    .ext15_pslverr (exp15_pslverr),

    .APBACTIVE     (APBACTIVE),  // Status Output for clock gating

    // Peripherals
    // UART/USRT
    .usrt0_txd_tvalid (usrt0_txd_tvalid),
    .usrt0_txd_tdata  (usrt0_txd_tdata ),
    .usrt0_txd_tready (usrt0_txd_tready),
    .usrt0_rxd_tvalid (usrt0_rxd_tvalid),
    .usrt0_rxd_tdata  (usrt0_rxd_tdata ),
    .usrt0_rxd_tready (usrt0_rxd_tready),

    .usrt1_txd_tvalid (usrt1_txd_tvalid),
    .usrt1_txd_tdata  (usrt1_txd_tdata ),
    .usrt1_txd_tready (usrt1_txd_tready),
    .usrt1_rxd_tvalid (usrt1_rxd_tvalid),
    .usrt1_rxd_tdata  (usrt1_rxd_tdata ),
    .usrt1_rxd_tready (usrt1_rxd_tready),

    .uart2_rxd     (uart2_rxd),
    .uart2_txd     (uart2_txd),
    .uart2_txen    (uart2_txen),

    // Timer
    .timer0_extin  (timer0_extin),
    .timer1_extin  (timer1_extin),

    // Interrupt outputs
    .apbsubsys_interrupt (SYS_APB_IRQ),
    .watchdog_interrupt  (SYS_NMI),
    
    // reset output
    .watchdog_reset      (WDOGRESETREQ)
  );

endmodule
