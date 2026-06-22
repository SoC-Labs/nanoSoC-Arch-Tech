/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - dma250_ch0_guard.h : single-channel CH0 busy-guard
 *
 * The SoC's Arm CoreLink DMA-250 (CG097) is the dma250_top_CFG_MIN minimum-config
 * variant: a SINGLE channel (NUM_CHANNELS=1). Both CPU0 data-plane services that
 * use the DMA do so on channel 0:
 *   - the GDB stub (gdb_stub.h, GDB_DMA_CH=0): RAM<->RAM bounce to/from the CPU1
 *     admin alias (the only DMA-reachable cross-AP path).
 *   - the TFTP flash service (tftp_flash.h, TFTP_DMA_CH=0): RAM->RAM staging
 *     (currently a CPU copy because the staging SRAM is outside dma_230_0_m's
 *     aperture — see tftp_flash.h — but the channel slot is still reserved).
 *
 * In the SEPARATE apps only one service is active, so CH0 is naturally serial.
 * In the UNIFIED eth_netapp_demo build BOTH services run on the single CPU0
 * thread. CPU0 is single-threaded, so two CH0 transfers can never be *issued*
 * concurrently; the residual hazard is reconfiguring CH0 (CLEARCMD + new SRC/
 * DES/CTRL/ENABLECMD) while a PREVIOUS command's tail is still in flight on the
 * fabric. dma250_init() issues CLEARCMD but does not first confirm the channel
 * is idle. This helper provides that defensive wait: call dma250_ch0_wait_idle()
 * at the START of every CH0 acquisition, before dma250_init()/reconfigure.
 *
 * "Idle" is read from CH_CMD.ENABLECMD (bit0): it is set while a command runs
 * and self-clears to 0 when the DMA process completes (dma250_driver.h). The
 * wait is BOUNDED (DMA250_CH0_IDLE_SPINS) so it can never hang CPU0 if the
 * channel is wedged or — on the CFG_MIN part — a non-existent channel was
 * programmed and ENABLECMD never set (the same trap GDB_DMA_CH documents).
 *
 * Header-only, static-inline; matches the eth_netapp service modules' style.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef NANOSOC_DMA250_CH0_GUARD_H
#define NANOSOC_DMA250_CH0_GUARD_H

#include <stdint.h>

#include "dma250_driver.h"

/* Channel the data-plane services share (CFG_MIN single channel). */
#ifndef DMA250_CH0_GUARD_CH
#define DMA250_CH0_GUARD_CH   0u
#endif

/* Bounded spin so a wedged / never-started channel cannot hang CPU0. A normal
 * SRAM<->SRAM bounce (<=256 B for GDB) completes in a handful of beats, so any
 * realistic in-flight tail clears in well under this budget. */
#ifndef DMA250_CH0_IDLE_SPINS
#define DMA250_CH0_IDLE_SPINS  100000u
#endif

/* Wait (bounded) for the shared DMA-250 channel to be idle before a new
 * acquisition reconfigures it. Returns 0 if the channel is idle, -1 if the
 * bounded wait expired (channel busy/wedged — caller may still proceed; the
 * subsequent dma250_init() CLEARCMD will reset it). */
static inline int dma250_ch0_wait_idle(void)
{
    dma250_channel_t *c = DMA250_CH(DMA250_CH0_GUARD_CH);
    for (uint32_t spins = DMA250_CH0_IDLE_SPINS; spins != 0u; --spins) {
        /* ENABLECMD (CH_CMD bit0) self-clears when the command completes; if it
         * is already 0 the channel holds no in-flight command. */
        if ((c->CH_CMD & DMA250_CMD_ENABLECMD) == 0u)
            return 0;
    }
    return -1;
}

#endif /* NANOSOC_DMA250_CH0_GUARD_H */
