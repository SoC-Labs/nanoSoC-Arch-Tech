/*
 *-----------------------------------------------------------------------------
 * nanosoc - Arm CoreLink DMA-250 (CG097) minimal driver - implementation
 *
 * Clean-room SoC-Labs implementation. See dma250_driver.h for provenance and
 * the register map. The 1D mem-to-mem path issues an immediate command by
 * register writes only (LINKADDR disabled, no in-memory descriptor):
 *
 *   CH_SRCADDR    <- src
 *   CH_DESADDR    <- dst
 *   CH_XSIZE      <- beat count (SRC=DES)
 *   CH_XADDRINC   <- 1 / 1  (increment src & dst by one beat)
 *   CH_CTRL       <- TRANSIZE=word, XTYPE=1D, DONETYPE=end-of-command
 *   CH_CMD.ENABLECMD = 1     -> hardware runs the copy and self-clears.
 *
 * This is the register-level equivalent of the Arm command-lib sequence
 * Dma250ChannelInit()/Dma2501DIncrCommand()/Dma250Enable(), and matches the
 * dma250_integration_check.c "simple 1D increment" test (TRANSIZE=2/32-bit,
 * SRCXADDRINC=DESXADDRINC=1, DONETYPE=1).
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */

#include "dma250_driver.h"

void dma250_init(uint32_t ch)
{
    dma250_channel_t *c = DMA250_CH(ch);

    /* CH_CMD (0x000): CLEARCMD resets the channel registers and any internal
     * queues/buffers, returning the channel to a known idle state. */
    c->CH_CMD = DMA250_CMD_CLEARCMD;

    /* CH_STATUS (0x004): W1C any sticky done/error/interrupt flags left over
     * from a previous command so the next wait starts clean. */
    c->CH_STATUS = DMA250_STATUS_STAT_DONE | DMA250_STATUS_STAT_ERR |
                   DMA250_STATUS_INTR_DONE | DMA250_STATUS_INTR_ERR;

    /* CH_INTREN (0x008): leave interrupts disabled; this driver polls. */
    c->CH_INTREN = 0u;

    /* CH_LINKADDR (0x078): ensure command-linking is OFF (immediate command,
     * no in-memory descriptor fetch). */
    c->CH_LINKADDR = 0u;
}

int dma250_mem2mem_1d(uint32_t ch, void *src, void *dst, uint32_t nbytes)
{
    dma250_channel_t *c = DMA250_CH(ch);
    uint32_t ctrl;
    uint32_t beats;

    if (src == NULL || dst == NULL || nbytes < 4u) {
        return -1;
    }

    /* Whole 32-bit beats (TRANSIZE=word). Round a partial tail down. */
    beats = nbytes >> 2;                 /* nbytes / 4 */
    if (beats == 0u || beats > 0xFFFFu) { /* XSIZE field is 16-bit */
        return -1;
    }

    /* CH_SRCADDR (0x010) / CH_DESADDR (0x018): byte addresses of the copy. */
    c->CH_SRCADDR = (uint32_t)src;
    c->CH_DESADDR = (uint32_t)dst;

    /* CH_XSIZE (0x020): SRCXSIZE[15:0] = DESXSIZE[31:16] = number of beats.
     * Equal src/des sizes give a straight 1:1 copy (no packing). */
    c->CH_XSIZE = DMA250_XSIZE(beats, beats);

    /* CH_XADDRINC (0x030): advance both source and destination by one beat
     * (one TRANSIZE) per transfer -> contiguous linear copy. */
    c->CH_XADDRINC = DMA250_XADDRINC(1u, 1u);

    /* CH_SRCTRANSCFG (0x028) / CH_DESTRANSCFG (0x02C): leave at reset. Reset
     * memory attributes (device/normal default) and the default max-burst
     * length are sufficient for an SRAM-to-SRAM copy; reset already gives a
     * secure/privileged-capable channel on this single-security build. */

    /* CH_CTRL (0x00C): read-modify-write the fields we own and clear the rest
     * of the transfer template so no triggers/GPO/2D behaviour is inherited.
     *   TRANSIZE = word (4-byte beats)
     *   XTYPE    = 1 (1D "continue" transfer)
     *   DONETYPE = 1 (STAT_DONE asserts at end of command) */
    ctrl  = c->CH_CTRL;
    ctrl &= ~(DMA250_CTRL_TRANSIZE_Msk | DMA250_CTRL_XTYPE_Msk |
              DMA250_CTRL_DONETYPE_Msk);
    ctrl |= (DMA250_TRANSIZE_32        << DMA250_CTRL_TRANSIZE_Pos);
    ctrl |= (DMA250_XTYPE_CONTINUE     << DMA250_CTRL_XTYPE_Pos);
    ctrl |= (DMA250_DONETYPE_END_OF_CMD << DMA250_CTRL_DONETYPE_Pos);
    c->CH_CTRL = ctrl;

    /* CH_CMD (0x000): ENABLECMD=1 launches the programmed command. The bit is
     * write-1-only and auto-clears to 0 when the DMA process completes. */
    c->CH_CMD = DMA250_CMD_ENABLECMD;

    return 0;
}

int dma250_wait_done(uint32_t ch)
{
    dma250_channel_t *c = DMA250_CH(ch);
    uint32_t status;

    /* Poll CH_STATUS (0x004) for STAT_DONE / STAT_ERR. ENABLECMD also
     * self-clears at completion, but STAT_DONE is the architected
     * "command reached its DONE point" flag and distinguishes error exit. */
    for (;;) {
        status = c->CH_STATUS;
        if (status & DMA250_STATUS_STAT_ERR) {
            return -1;
        }
        if (status & DMA250_STATUS_STAT_DONE) {
            return 0;
        }
    }
}

void dma250_irq_clear(uint32_t ch)
{
    dma250_channel_t *c = DMA250_CH(ch);

    /* CH_STATUS (0x004) is write-1-clear: clearing STAT_DONE/STAT_ERR also
     * auto-clears the corresponding INTR_DONE/INTR_ERR interrupt flags, but we
     * write all four explicitly to be unambiguous. */
    c->CH_STATUS = DMA250_STATUS_INTR_DONE | DMA250_STATUS_INTR_ERR |
                   DMA250_STATUS_STAT_DONE | DMA250_STATUS_STAT_ERR;
}
