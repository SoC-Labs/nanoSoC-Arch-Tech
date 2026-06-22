/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - Arm PrimeCell PL022 (SSP) SPI master driver / HAL
 *
 * Implementation. See spi_pl022.h for the register map / API contract and
 * docs/SPI_PL022_INTEGRATION_PLAN.md / docs/SPI_PL022_DMA_DESIGN.md for the
 * hardware integration.
 *
 * CPU1-oriented (the PL022 sits on the CPU1-private cc_periph_subsystem APB
 * ext slot) but provider-agnostic C99 — no CMSIS/NVIC calls here, so the same
 * object links into a CPU0 image or the cocotb host-native HAL build.
 *
 * Write-barrier rationale: every register WRITE goes through spi_wr() which
 * read-backs the just-written register into a DMEM sink. On the multi-master
 * AHB matrix the M0+ can otherwise drop a back-to-back write (the same hazard
 * the IPC / CC-UART drivers guard against). Status POLLS are read-only and
 * need no barrier.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */

#include "spi_pl022.h"

/* DMEM landing pad for the AHB write barrier (value intentionally unused). */
static volatile uint32_t spi_bar_sink;

/* Barriered 32-bit register write: store, then read-back into the sink so the
 * AHB write retires before the next bus access. */
static inline void spi_wr(volatile uint32_t *reg, uint32_t v)
{
    *reg = v;
    spi_bar_sink = *reg;
}

/* Plain register read (status / RX data) — no barrier needed. */
static inline uint32_t spi_rd(volatile const uint32_t *reg)
{
    return *reg;
}

/* Optional bounded spin. Returns 1 while it should keep waiting, 0 on timeout.
 * budget==0 means "wait forever" (matching SPI_PL022_POLL_TIMEOUT default). */
static inline int spi_poll_continue(uint32_t *budget)
{
    if (*budget == 0u)
        return 1;                 /* infinite */
    if (--(*budget) == 0u)
        return 0;                 /* timed out */
    return 1;
}

/* -------------------------------------------------------------------------
 * Bit-rate divider solver.
 * SCLK = SSPCLK / (CPSDVSR * (1 + SCR)), CPSDVSR even 2..254, SCR 0..255.
 * Pick the smallest combined divisor that yields SCLK <= bit_rate_hz (never
 * faster than requested). Walk CPSDVSR upward, derive the minimal SCR.
 * ---------------------------------------------------------------------- */
static int spi_calc_clock(uint32_t bit_rate_hz, uint32_t *cpsdvsr, uint32_t *scr)
{
    if (bit_rate_hz == 0u)
        return SPI_EINVAL;

    for (uint32_t cps = SPI_PL022_CPSDVSR_MIN; cps <= SPI_PL022_CPSDVSR_MAX; cps += 2u) {
        /* smallest SCR such that SSPCLK/(cps*(1+SCR)) <= bit_rate_hz
         * => (1+SCR) >= SSPCLK / (cps * bit_rate_hz)  (ceil) */
        uint32_t denom = cps * bit_rate_hz;
        uint32_t need  = (SPI_PL022_SSPCLK_HZ + denom - 1u) / denom;   /* ceil(SSPCLK/denom) = 1+SCR */
        if (need == 0u)
            need = 1u;
        if (need <= 256u) {
            *cpsdvsr = cps;
            *scr     = need - 1u;      /* 0..255 */
            return SPI_OK;
        }
    }
    return SPI_EINVAL;                 /* requested rate too low to reach */
}

/* =========================================================================
 * Init / enable
 * ========================================================================= */
int spi_pl022_init(const spi_pl022_cfg_t *cfg)
{
    if (cfg == NULL)
        return SPI_EINVAL;
    if (cfg->data_bits < 4u || cfg->data_bits > 16u)
        return SPI_EINVAL;
    if (cfg->frame_format > SPI_PL022_FRF_UWIRE)
        return SPI_EINVAL;

    uint32_t cpsdvsr = 0u, scr = 0u;
    int rc = spi_calc_clock(cfg->bit_rate_hz, &cpsdvsr, &scr);
    if (rc != SPI_OK)
        return rc;

    /* Disable before reconfiguring (CR0/CPSR latch on the disable->enable
     * edge). */
    spi_pl022_disable();

    uint32_t cr0 = 0u;
    cr0 |= (SPI_PL022_DSS((uint32_t)cfg->data_bits) << SPI_PL022_SSPCR0_DSS_Pos);
    cr0 |= (((uint32_t)cfg->frame_format << SPI_PL022_SSPCR0_FRF_Pos)
            & SPI_PL022_SSPCR0_FRF_Msk);
    if ((uint32_t)cfg->mode & 0x2u) cr0 |= SPI_PL022_SSPCR0_SPO_Msk;  /* CPOL */
    if ((uint32_t)cfg->mode & 0x1u) cr0 |= SPI_PL022_SSPCR0_SPH_Msk;  /* CPHA */
    cr0 |= ((scr << SPI_PL022_SSPCR0_SCR_Pos) & SPI_PL022_SSPCR0_SCR_Msk);

    spi_wr(&SPI_PL022->SSPCR0,  cr0);
    spi_wr(&SPI_PL022->SSPCPSR, cpsdvsr);

    /* CR1: master (MS=0), DMA/IRQ off here; LBM optional for self-test. */
    uint32_t cr1 = cfg->loopback ? SPI_PL022_SSPCR1_LBM_Msk : 0u;
    spi_wr(&SPI_PL022->SSPCR1,   cr1);          /* SSE still 0 => disabled */

    /* Mask all interrupts and clear the W1C sources by default. */
    spi_wr(&SPI_PL022->SSPIMSC,  0u);
    spi_wr(&SPI_PL022->SSPICR,   SPI_PL022_ICR_ALL_Msk);
    spi_wr(&SPI_PL022->SSPDMACR, 0u);

    return SPI_OK;
}

void spi_pl022_enable(void)
{
    uint32_t cr1 = spi_rd(&SPI_PL022->SSPCR1) | SPI_PL022_SSPCR1_SSE_Msk;
    spi_wr(&SPI_PL022->SSPCR1, cr1);
}

void spi_pl022_disable(void)
{
    uint32_t cr1 = spi_rd(&SPI_PL022->SSPCR1) & ~SPI_PL022_SSPCR1_SSE_Msk;
    spi_wr(&SPI_PL022->SSPCR1, cr1);
}

/* =========================================================================
 * Chip-select control (SSP_SSCTRL wrapper CSR)
 *
 * Operating model (plan §5.3): firmware sets ss_sel + ss_enable (+ cs_hold for
 * multi-byte devices), runs SSPDR transfers, then drops ss_enable. ss_decode_en
 * is sticky between selects (it reflects what is physically on the board), so
 * select()/deselect() preserve it and only touch ss_sel/ss_enable/cs_hold.
 * ========================================================================= */
void spi_pl022_set_decode_mode(int decoder_enabled)
{
    uint32_t v = SPI_PL022_SSCTRL & ~SPI_PL022_SSCTRL_DECODE_EN_Msk;
    if (decoder_enabled)
        v |= SPI_PL022_SSCTRL_DECODE_EN_Msk;
    /* Force CS deasserted while changing mode so no slave glitches. */
    v &= ~SPI_PL022_SSCTRL_SSEN_Msk;
    spi_wr(&SPI_PL022_SSCTRL, v);
}

void spi_pl022_select(uint8_t slave, int hold)
{
    /* Preserve ss_decode_en; replace ss_sel and (re)assert ss_enable.
     * In decoder mode the caller should have called deselect() first (the
     * standard manual-CS discipline) — we still drop enable below before
     * re-driving so a same-call ss_sel change cannot momentarily point the
     * external decoder at the wrong device while enabled. */
    uint32_t v = SPI_PL022_SSCTRL & SPI_PL022_SSCTRL_DECODE_EN_Msk;
    v |= (((uint32_t)slave << SPI_PL022_SSCTRL_SSSEL_Pos)
          & SPI_PL022_SSCTRL_SSSEL_Msk);
    if (hold)
        v |= SPI_PL022_SSCTRL_CSHOLD_Msk;
    /* Stage ss_sel with enable low first (decoder-safe), then assert enable. */
    spi_wr(&SPI_PL022_SSCTRL, v);
    v |= SPI_PL022_SSCTRL_SSEN_Msk;
    spi_wr(&SPI_PL022_SSCTRL, v);
}

void spi_pl022_deselect(void)
{
    /* Drop ss_enable; keep ss_decode_en and ss_sel so a re-select is cheap. */
    uint32_t v = SPI_PL022_SSCTRL & ~SPI_PL022_SSCTRL_SSEN_Msk;
    spi_wr(&SPI_PL022_SSCTRL, v);
}

/* =========================================================================
 * Blocking transfers
 * ========================================================================= */
int spi_pl022_transfer(uint16_t tx)
{
    uint32_t budget = SPI_PL022_POLL_TIMEOUT;

    /* Wait for TX FIFO space (TNF). */
    while (!(spi_rd(&SPI_PL022->SSPSR) & SPI_PL022_SSPSR_TNF_Msk)) {
        if (!spi_poll_continue(&budget))
            return SPI_ETIMEOUT;
    }
    spi_wr(&SPI_PL022->SSPDR, (uint32_t)tx);

    /* Wait for the matching RX frame (full-duplex: one in per one out). */
    budget = SPI_PL022_POLL_TIMEOUT;
    while (!(spi_rd(&SPI_PL022->SSPSR) & SPI_PL022_SSPSR_RNE_Msk)) {
        if (!spi_poll_continue(&budget))
            return SPI_ETIMEOUT;
    }
    return (int)(spi_rd(&SPI_PL022->SSPDR) & 0xFFFFu);
}

int spi_pl022_transfer_buf(const uint8_t *tx, uint8_t *rx, size_t len)
{
    /* Frame width: re-derive from CR0 so byte vs half-word indexing is right.
     * data_bits <= 8 => one byte per frame; 9..16 => two bytes per frame. */
    uint32_t dss   = (spi_rd(&SPI_PL022->SSPCR0) & SPI_PL022_SSPCR0_DSS_Msk)
                     >> SPI_PL022_SSPCR0_DSS_Pos;
    int      wide  = (dss >= 8u);            /* DSS field 8 => 9-bit frame */
    size_t   i;

    for (i = 0u; i < len; i++) {
        uint16_t out;
        if (tx == NULL) {
            out = 0xFFFFu;                   /* read: drive idle line high */
        } else if (wide) {
            out = (uint16_t)(tx[2u * i] | ((uint16_t)tx[2u * i + 1u] << 8));
        } else {
            out = tx[i];
        }

        int in = spi_pl022_transfer(out);
        if (in < 0)
            return SPI_ETIMEOUT;

        if (rx != NULL) {
            if (wide) {
                rx[2u * i]      = (uint8_t)(in & 0xFFu);
                rx[2u * i + 1u] = (uint8_t)((in >> 8) & 0xFFu);
            } else {
                rx[i] = (uint8_t)(in & 0xFFu);
            }
        }
    }
    return SPI_OK;
}

int spi_pl022_flush(void)
{
    uint32_t budget = SPI_PL022_POLL_TIMEOUT;
    uint32_t want   = SPI_PL022_SSPSR_TFE_Msk;     /* TX empty ... */
    for (;;) {
        uint32_t sr = spi_rd(&SPI_PL022->SSPSR);
        if ((sr & want) && !(sr & SPI_PL022_SSPSR_BSY_Msk))   /* ... and not busy */
            return SPI_OK;
        if (!spi_poll_continue(&budget))
            return SPI_ETIMEOUT;
    }
}

/* =========================================================================
 * IRQ-driven transfer — skeleton
 *
 * Non-blocking: arms the TX/RX FIFO-service interrupts (SSPIMSC TX/RX bits)
 * and records the buffers. The combined SSPINTR routes to the NVIC line chosen
 * in the integration plan (§7.5). The installed NVIC ISR must call
 * spi_pl022_irq_handler(); poll spi_pl022_irq_done() for completion.
 *
 * NVIC enable / vector install are CMSIS-specific and so live in the app that
 * owns the IRQ line (cf. firmware/apps/cpu0_dma_irq_test for the override-the-
 * weak-handler idiom) — kept out of this portable driver core.
 * ========================================================================= */
static struct {
    const uint8_t *tx;
    uint8_t       *rx;
    size_t         len;
    volatile size_t tx_pos;
    volatile size_t rx_pos;
    volatile int   done;
    int            wide;
} s_irq;

void spi_pl022_irq_start(const uint8_t *tx, uint8_t *rx, size_t len)
{
    uint32_t dss = (spi_rd(&SPI_PL022->SSPCR0) & SPI_PL022_SSPCR0_DSS_Msk)
                   >> SPI_PL022_SSPCR0_DSS_Pos;
    s_irq.tx     = tx;
    s_irq.rx     = rx;
    s_irq.len    = len;
    s_irq.tx_pos = 0u;
    s_irq.rx_pos = 0u;
    s_irq.done   = (len == 0u);
    s_irq.wide   = (dss >= 8u);

    /* Clear stale W1C sources, then unmask TX + RX FIFO-service interrupts.
     * (ROR/RT left masked here; an app can add them.) */
    spi_wr(&SPI_PL022->SSPICR,  SPI_PL022_ICR_ALL_Msk);
    spi_wr(&SPI_PL022->SSPIMSC, SPI_PL022_INT_TX_Msk | SPI_PL022_INT_RX_Msk);
}

void spi_pl022_irq_handler(void)
{
    /* Drain RX FIFO into the buffer. */
    while (spi_rd(&SPI_PL022->SSPSR) & SPI_PL022_SSPSR_RNE_Msk) {
        uint32_t in = spi_rd(&SPI_PL022->SSPDR) & 0xFFFFu;
        if (s_irq.rx != NULL && s_irq.rx_pos < s_irq.len) {
            if (s_irq.wide) {
                s_irq.rx[2u * s_irq.rx_pos]      = (uint8_t)(in & 0xFFu);
                s_irq.rx[2u * s_irq.rx_pos + 1u] = (uint8_t)((in >> 8) & 0xFFu);
            } else {
                s_irq.rx[s_irq.rx_pos] = (uint8_t)(in & 0xFFu);
            }
        }
        if (s_irq.rx_pos < s_irq.len)
            s_irq.rx_pos++;
    }

    /* Fill TX FIFO while there is space and frames left to send. */
    while ((s_irq.tx_pos < s_irq.len) &&
           (spi_rd(&SPI_PL022->SSPSR) & SPI_PL022_SSPSR_TNF_Msk)) {
        uint16_t out;
        if (s_irq.tx == NULL) {
            out = 0xFFFFu;
        } else if (s_irq.wide) {
            out = (uint16_t)(s_irq.tx[2u * s_irq.tx_pos]
                             | ((uint16_t)s_irq.tx[2u * s_irq.tx_pos + 1u] << 8));
        } else {
            out = s_irq.tx[s_irq.tx_pos];
        }
        spi_wr(&SPI_PL022->SSPDR, (uint32_t)out);
        s_irq.tx_pos++;
    }

    /* All frames sent and received -> mask interrupts and flag completion. */
    if (s_irq.tx_pos >= s_irq.len && s_irq.rx_pos >= s_irq.len) {
        spi_wr(&SPI_PL022->SSPIMSC, 0u);
        s_irq.done = 1;
    } else if (s_irq.tx_pos >= s_irq.len) {
        /* No more to send: keep only RX unmasked so we still collect trailing
         * frames, then complete on the next handler pass. */
        spi_wr(&SPI_PL022->SSPIMSC, SPI_PL022_INT_RX_Msk | SPI_PL022_INT_RT_Msk);
    }
}

int spi_pl022_irq_done(void)
{
    return s_irq.done;
}

/* =========================================================================
 * DMA-driven transfer — skeleton
 *
 * Only flips SSPDMACR. The DMA-230 (PL230) channel programming (control
 * descriptor in the DMA control SRAM, CHNL_ENABLE_SET, the SSPDR src/dst
 * address, byte count, single-vs-burst arbitration) is SoC-wiring dependent
 * and fully specified in docs/SPI_PL022_DMA_DESIGN.md. Wire that up, program
 * the channel(s), then call these to gate the PL022 DMA request lines.
 * ========================================================================= */
void spi_pl022_dma_tx_enable(int en)
{
    uint32_t v = spi_rd(&SPI_PL022->SSPDMACR);
    if (en) v |=  SPI_PL022_SSPDMACR_TXDMAE_Msk;
    else    v &= ~SPI_PL022_SSPDMACR_TXDMAE_Msk;
    spi_wr(&SPI_PL022->SSPDMACR, v);
}

void spi_pl022_dma_rx_enable(int en)
{
    uint32_t v = spi_rd(&SPI_PL022->SSPDMACR);
    if (en) v |=  SPI_PL022_SSPDMACR_RXDMAE_Msk;
    else    v &= ~SPI_PL022_SSPDMACR_RXDMAE_Msk;
    spi_wr(&SPI_PL022->SSPDMACR, v);
}
