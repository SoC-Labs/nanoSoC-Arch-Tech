/*
 *-----------------------------------------------------------------------------
 * NanoSoC Test: spi_loopback — PL022 SSP internal + external loopback
 *
 * Phase 1 (INTERNAL): SSPCR1.LBM=1 routes the PL022 transmit serializer
 * straight into the receive serializer inside the macrocell — no pins, no
 * jumper. Proves the APB register path, clock prescaler and FIFOs.
 *
 * Phase 2 (EXTERNAL): LBM=0, real pins. Requires a physical MOSI->MISO
 * jumper on the board (Pynq-Z2 PMODA: JA2 -> JA3). Proves the pad routing
 * (SoC spi_mosi -> pin -> spi_miso) at the board level. CS (JA1) and SCK
 * (JA4) toggle automatically per frame (Motorola SPI, SSPFSSOUT) so the
 * phases are also scope-observable.
 *
 * This SoC exposes the raw PL022 behind an AHB->APB bridge at
 * NANOSOC_SPI_BASE (0x2800C000) with a single chip select; there is NO
 * SSP_SSCTRL wrapper CSR at +0x100, so spi_pl022_select()/deselect() are
 * deliberately not used here.
 *
 * Output (UART2 -> PS UART1 EMIO -> 38400 8N1):
 *   per phase: TX bytes, RX bytes, PASS/FAIL verdict
 *   overall  : ** TEST PASSED ** when both phases match
 * The test then re-runs forever (a few seconds per lap) so the external
 * phase can be re-checked live after the jumper is fitted, without
 * re-pulsing reset.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */

#ifdef CORTEX_M0
#include "CMSDK_CM0.h"
#include "core_cm0.h"
#endif

#ifdef CORTEX_M0PLUS
#include "CMSDK_CM0plus.h"
#include "core_cm0plus.h"
#endif

#include <stdio.h>
#include <stdint.h>
#include "uart_stdout.h"
#include "spi_pl022.h"

#define SPI_TEST_BIT_RATE_HZ  1000000u   /* ~961 kHz actual @ 25 MHz HCLK */

static const uint8_t pattern[] = {
    0xA5, 0x5A, 0xC3, 0x3C, 0x0F, 0xF0, 0x81, 0x7E
};
#define PATTERN_LEN  (sizeof(pattern))

static void print_bytes(const char *tag, const char *dir, const uint8_t *buf)
{
    unsigned i;
    printf("[%s] %s:", tag, dir);
    for (i = 0; i < PATTERN_LEN; i++)
        printf(" %02X", buf[i]);
    printf("\n");
}

/* Run one loopback phase. Returns the number of mismatched bytes,
 * or -1 on driver/timeout error. */
static int run_phase(const char *tag, int internal_lbm, uint8_t *rx)
{
    spi_pl022_cfg_t cfg;
    int rc;
    unsigned i, mismatches;

    cfg.bit_rate_hz  = SPI_TEST_BIT_RATE_HZ;
    cfg.data_bits    = 8u;
    cfg.mode         = SPI_MODE0;
    cfg.frame_format = SPI_PL022_FRF_SPI;
    cfg.loopback     = internal_lbm ? 1u : 0u;

    for (i = 0; i < PATTERN_LEN; i++)
        rx[i] = 0xEE;                       /* poison so a dead RX is visible */

    rc = spi_pl022_init(&cfg);
    if (rc != SPI_OK) {
        printf("[%s] spi_pl022_init failed (%d)\n", tag, rc);
        return -1;
    }
    spi_pl022_enable();

    rc = spi_pl022_transfer_buf(pattern, rx, PATTERN_LEN);
    (void)spi_pl022_flush();
    spi_pl022_disable();

    print_bytes(tag, "TX", pattern);
    print_bytes(tag, "RX", rx);

    if (rc != SPI_OK) {
        printf("[%s] transfer timeout (SSP not responding)\n", tag);
        return -1;
    }

    mismatches = 0;
    for (i = 0; i < PATTERN_LEN; i++)
        if (rx[i] != pattern[i])
            mismatches++;
    return (int)mismatches;
}

static void delay_roughly_seconds(void)
{
#ifdef NANOSOC_SYS_CLK_FREQ_HZ
    volatile uint32_t n = NANOSOC_SYS_CLK_FREQ_HZ / 4u;
#else
    volatile uint32_t n = 6250000u;
#endif
    while (n--)
        ;
}

int main(void)
{
    uint8_t  rx[PATTERN_LEN];
    int      int_res, ext_res;
    uint32_t lap = 0;
    static const char alive[] = "spi_loopback: alive\n";
    const char *p;

    /* Raw immediate marker before ANY runtime init: stage-0 left UART2
     * TX-enabled at the right BAUDDIV, so a bare DATA write is visible even
     * if everything below faults. 'S' = app entered main(). */
    CMSDK_UART2->DATA = 'S';

    UartStdOutInit();

    /* FPGA console insurance: UartStdOutInit() enables the SoCDebug USRT2,
     * which steers UartPutc/printf onto the FT1248/ADP drain path. On the
     * pynq builds that drain is a dead self-loop, so force the console onto
     * UART2 (the PS UART1 EMIO bridge) by disabling USRT2 again. Harmless
     * where the ADP host is real: UART2 output is identical. */
    CMSDK_USRT2->CTRL = 0x00;

    /* First line via the retarget's polled UartPutc only (no printf/newlib
     * involvement) — separates "app+UART alive" from "printf works". */
    for (p = alive; *p != '\0'; p++)
        UartPutc((unsigned char)*p);

    printf("\nNanoSoC PL022 SPI loopback test (base 0x%08X)\n",
           (unsigned int)SPI_PL022_BASE);

    for (;;) {
        lap++;
        printf("--- lap %u ---\n", (unsigned int)lap);

        /* Phase 1: internal loopback (SSPCR1.LBM=1) — no jumper needed. */
        int_res = run_phase("INT", 1, rx);
        printf("SPI INTERNAL LOOPBACK: %s\n",
               (int_res == 0) ? "PASS" : "FAIL");

        /* Phase 2: external loopback (real pins) — needs JA2->JA3 jumper. */
        ext_res = run_phase("EXT", 0, rx);
        printf("SPI EXTERNAL LOOPBACK: %s%s\n",
               (ext_res == 0) ? "PASS" : "FAIL",
               (ext_res == 0) ? "" : " (is the PMODA JA2->JA3 jumper fitted?)");

        if (int_res == 0 && ext_res == 0)
            printf("** TEST PASSED **\n");
        else
            printf("** TEST FAILED **\n");

        if (lap == 1) {
            /* End-of-test marker after lap 1: a lone EOT byte. Simulation
             * UART capture ends the sim on 0x04; on hardware it is an
             * invisible control byte. Deliberately NOT UartEndSimulation()
             * — that parks in while(1) and would defeat the continuous
             * re-probe loop below (found on z2-04: test ran one lap then
             * parked). */
            UartPutc(0x04);
        }
        delay_roughly_seconds();
    }

    return 0;
}
