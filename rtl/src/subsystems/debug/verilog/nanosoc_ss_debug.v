//-----------------------------------------------------------------------------
// NanoSoC Debug Subsystem - Contains SoCDebug Module
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2023, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module nanosoc_ss_debug #(
    // System Parameters
    parameter         SYS_ADDR_W    = 32,  // System Address Width
    parameter         SYS_DATA_W    = 32,  // System Data Width
    // SoCDebug Parameters
    parameter         PROMPT_CHAR   = "]"
)(
    // System Clocks and Resets
    input  wire                     SYS_HCLK,
    input  wire                     SYS_HRESETn,
    input  wire                     SYS_PCLK,
    input  wire                     SYS_PCLKG,
    input  wire                     SYS_PRESETn,

    // AHB-lite Master Interface - ADP
    output wire    [SYS_ADDR_W-1:0] DEBUG_HADDR,
    output wire              [ 2:0] DEBUG_HBURST,
    output wire                     DEBUG_HMASTLOCK,
    output wire              [ 3:0] DEBUG_HPROT,
    output wire              [ 2:0] DEBUG_HSIZE,
    output wire              [ 1:0] DEBUG_HTRANS,
    output wire    [SYS_DATA_W-1:0] DEBUG_HWDATA,
    output wire                     DEBUG_HWRITE,
    input  wire    [SYS_DATA_W-1:0] DEBUG_HRDATA,
    input  wire                     DEBUG_HREADY,
    input  wire                     DEBUG_HRESP,

    // ADP TXD axi byte stream
    output wire                     ADP_RXD_TVALID_o,
    output wire            [ 7:0]   ADP_RXD_TDATA_o ,
    input  wire                     ADP_RXD_TREADY_i,
    // ADP RXD axi byte stream
    input  wire                     ADP_TXD_TVALID_i,
    input  wire             [ 7:0]  ADP_TXD_TDATA_i ,
    output wire                     ADP_TXD_TREADY_o,

    // APB Slave Interface - USRT Control
    input  wire                     DEBUG_PSEL,
    input  wire             [11:2]  DEBUG_PADDR,
    input  wire                     DEBUG_PENABLE,
    input  wire                     DEBUG_PWRITE,
    input  wire             [31:0]  DEBUG_PWDATA,
    output wire             [31:0]  DEBUG_PRDATA,
    output wire                     DEBUG_PREADY,
    output wire                     DEBUG_PSLVERR,

    // FT1248 Clock Divider Output
    output wire              [7:0]  DEBUG_INVBAUDDIV8,

    // USRT Interrupt Outputs
    output wire                     DEBUG_TXINT,
    output wire                     DEBUG_RXINT,
    output wire                     DEBUG_TXOVRINT,
    output wire                     DEBUG_RXOVRINT,
    output wire                     DEBUG_UARTINT,

    // GPIO interface
    output wire               [7:0] GPO8,
    input  wire               [7:0] GPI8
);

    //---------------------------
    // Internal STD Byte Streams
    //---------------------------
    wire        std_rxd_tvalid;
    wire  [7:0] std_rxd_tdata;
    wire        std_rxd_tready;
    wire        std_txd_tvalid;
    wire  [7:0] std_txd_tdata;
    wire        std_txd_tready;

    //---------------------------
    // SoCDebug Instantiation
    //---------------------------
    socdebug_ahb #(
        .PROMPT_CHAR(PROMPT_CHAR)
    ) u_socdebug (
        // AHB-lite Master Interface - ADP
        .HCLK(SYS_HCLK),
        .HRESETn(SYS_HRESETn),
        .HADDR32_o(DEBUG_HADDR),
        .HBURST3_o(DEBUG_HBURST),
        .HMASTLOCK_o(DEBUG_HMASTLOCK),
        .HPROT4_o(DEBUG_HPROT),
        .HSIZE3_o(DEBUG_HSIZE),
        .HTRANS2_o(DEBUG_HTRANS),
        .HWDATA32_o(DEBUG_HWDATA),
        .HWRITE_o(DEBUG_HWRITE),
        .HRDATA32_i(DEBUG_HRDATA),
        .HREADY_i(DEBUG_HREADY),
        .HRESP_i(DEBUG_HRESP),

        .ADP_RXD_TVALID_o(ADP_RXD_TVALID_o),
        .ADP_RXD_TDATA_o( ADP_RXD_TDATA_o ),
        .ADP_RXD_TREADY_i(ADP_RXD_TREADY_i),
        .ADP_TXD_TVALID_i(ADP_TXD_TVALID_i),
        .ADP_TXD_TDATA_i (ADP_TXD_TDATA_i ),
        .ADP_TXD_TREADY_o(ADP_TXD_TREADY_o),

        .STD_RXD_TVALID_o(std_rxd_tvalid),
        .STD_RXD_TDATA_o( std_rxd_tdata ),
        .STD_RXD_TREADY_i(std_rxd_tready),
        .STD_TXD_TVALID_i(std_txd_tvalid),
        .STD_TXD_TDATA_i (std_txd_tdata ),
        .STD_TXD_TREADY_o(std_txd_tready),

        // GPIO interface
        .GPO8_o(GPO8),
        .GPI8_i(GPI8)
    );

    //---------------------------
    // USRT Controller
    //---------------------------
    socdebug_usrt_control u_usrt_control (
        // APB Clock and Reset Signals
        .PCLK              (SYS_PCLK),
        .PCLKG             (SYS_PCLKG),
        .PRESETn           (SYS_PRESETn),

        // APB Interface Signals
        .PSEL              (DEBUG_PSEL),
        .PADDR             (DEBUG_PADDR),
        .PENABLE           (DEBUG_PENABLE),
        .PWRITE            (DEBUG_PWRITE),
        .PWDATA            (DEBUG_PWDATA),
        .PRDATA            (DEBUG_PRDATA),
        .PREADY            (DEBUG_PREADY),
        .PSLVERR           (DEBUG_PSLVERR),

        .ECOREVNUM         (4'h0),

        // ADP Interface - From USRT to ADP
        .TX_VALID_o        (std_txd_tvalid),
        .TX_DATA8_o        (std_txd_tdata ),
        .TX_READY_i        (std_txd_tready),

        // ADP Interface - From ADP to USRT
        .RX_VALID_i        (std_rxd_tvalid),
        .RX_DATA8_i        (std_rxd_tdata ),
        .RX_READY_o        (std_rxd_tready),
        .INVBAUDDIV8_o     (DEBUG_INVBAUDDIV8),

        // Interrupt Interfaces
        .TXINT             (DEBUG_TXINT),
        .RXINT             (DEBUG_RXINT),
        .TXOVRINT          (DEBUG_TXOVRINT),
        .RXOVRINT          (DEBUG_RXOVRINT),
        .UARTINT           (DEBUG_UARTINT)
    );

endmodule
