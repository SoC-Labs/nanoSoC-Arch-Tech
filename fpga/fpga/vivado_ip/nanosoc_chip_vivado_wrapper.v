//-----------------------------------------------------------------------------
// NanoSoC Chip Vivado IP Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2021-2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// This wrapper presents the nanosoc_chip with clean, Vivado IP Integrator
// friendly interfaces. Test, scan, and BIST signals are tied off internally.
//
// Interfaces exposed:
//   - Clock and Reset
//   - GPIO Port 0 (16-bit, active-low tristate)
//   - GPIO Port 1 (16-bit, active-low tristate)
//   - Serial Wire Debug (SWD)
//   - UART
//-----------------------------------------------------------------------------
`include "gen_defines.v"

module nanosoc_chip_vivado_wrapper #(
    parameter integer IMEM_RAM_ADDR_W = 14  // Instruction memory address width (default 16KB)
)(
    // Clock and Reset
    input  wire        clk,           // System clock
    input  wire        nrst,          // Active-low system reset

    // GPIO Port 0 - Active-low tristate (directly usable with Vivado tri-state buffers)
    input  wire [15:0] gpio0_tri_i,   // GPIO 0 input
    output wire [15:0] gpio0_tri_o,   // GPIO 0 output
    output wire [15:0] gpio0_tri_t,   // GPIO 0 tristate enable (active-low output enable, active-high = Hi-Z)

    // GPIO Port 1 - Active-low tristate
    input  wire [15:0] gpio1_tri_i,   // GPIO 1 input
    output wire [15:0] gpio1_tri_o,   // GPIO 1 output
    output wire [15:0] gpio1_tri_t,   // GPIO 1 tristate enable (active-low output enable, active-high = Hi-Z)

    // Serial Wire Debug (active-low tristate on SWDIO)
    input  wire        swd_clk,       // SWD clock input
    input  wire        swd_dio_i,     // SWD data input
    output wire        swd_dio_o,     // SWD data output
    output wire        swd_dio_t,     // SWD data tristate (active-high = Hi-Z)

    // UART
    input  wire        uart_rxd,      // UART receive data
    output wire        uart_txd       // UART transmit data
);

    // Internal wires for nanosoc_chip port connections
    wire [15:0] p0_o;
    wire [15:0] p0_e;
    wire [15:0] p0_z;
    wire [15:0] p1_o;
    wire [15:0] p1_e;
    wire [15:0] p1_z;
    wire        swdio_o;
    wire        swdio_e;
    wire        swdio_z;

    // GPIO Port 0: Map chip output-enable (active-high) to Vivado tristate (active-high = Hi-Z)
    assign gpio0_tri_o = p0_o;
    assign gpio0_tri_t = p0_z;   // p0_z = ~p0_e (active-high = Hi-Z), matches Vivado tri_t convention

    // GPIO Port 1: Same mapping
    assign gpio1_tri_o = p1_o;
    assign gpio1_tri_t = p1_z;   // p1_z = ~p1_e (active-high = Hi-Z), matches Vivado tri_t convention

    // SWD data: Map to Vivado tristate convention
    assign swd_dio_o = swdio_o;
    assign swd_dio_t = swdio_z;  // swdio_z = ~swdio_e (active-high = Hi-Z)

    // NanoSoC Chip Instance
    nanosoc_chip #(
        .FT1248_WIDTH (1),
        .GPIO_TIO     (4)
    ) u_nanosoc_chip (
        // Power pins handled internally by nanosoc_chip ifdef

        // Test/Scan/BIST - Tied off for normal operation
        .diag_mode    (1'b0),
        .diag_ctrl    (1'b0),
        .scan_mode    (1'b0),
        .scan_enable  (1'b0),
        .scan_in      (4'b0000),
        .scan_out     (),           // Unconnected - not needed for normal operation
        .bist_mode    (1'b0),
        .bist_enable  (1'b0),
        .bist_in      (4'b0000),
        .bist_out     (),           // Unconnected - not needed for normal operation

        // UART mode and SWD mode - both active
        .alt_mode     (1'b1),       // Enable UART alternate mode
        .uart_rxd_i   (uart_rxd),
        .uart_txd_o   (uart_txd),
        .swd_mode     (1'b1),       // Enable SWD mode

        // Clock and Reset
        .clk_i        (clk),
        .test_i       (1'b0),
        .nrst_i       (nrst),

        // GPIO Port 0
        .p0_i         (gpio0_tri_i),
        .p0_o         (p0_o),
        .p0_e         (p0_e),
        .p0_z         (p0_z),

        // GPIO Port 1
        .p1_i         (gpio1_tri_i),
        .p1_o         (p1_o),
        .p1_e         (p1_e),
        .p1_z         (p1_z),

        // Serial Wire Debug
        .swdio_i      (swd_dio_i),
        .swdio_o      (swdio_o),
        .swdio_e      (swdio_e),
        .swdio_z      (swdio_z),
        .swdclk_i     (swd_clk)
    );

endmodule
