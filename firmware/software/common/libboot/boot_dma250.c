/*----------------------------------------------------------------------------
 * boot_dma250 — generic DMA-250 single memcpy (implementation)
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * Generalised from the validated nanosoc DMA-250 boot-copy. Verify the exact
 * timing/wait against sim on the EDA host before trusting on silicon.
 *----------------------------------------------------------------------------*/
#include "boot_dma250.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DMA250_DONE_SPINS  0x01000000u   /* bounded wait (avoid infinite hang) */

static int dma250_one(uintptr_t ch, uint32_t dst, uint32_t src,
                      uint32_t beats, int src_cacheable)
{
    REG32(ch + DMA250_CH_STATUS)      = DMA250_STAT_DONE | DMA250_STAT_ERR; /* W1C */
    REG32(ch + DMA250_CH_SRCADDR)     = src;
    REG32(ch + DMA250_CH_DESADDR)     = dst;
    REG32(ch + DMA250_CH_XSIZE)       = beats | (beats << 16);
    REG32(ch + DMA250_CH_XADDRINC)    = 1u | (1u << 16);   /* inc src + des 1 beat */
    REG32(ch + DMA250_CH_SRCTRANSCFG) = src_cacheable ? DMA250_SRC_CACHEABLE : 0u;
    REG32(ch + DMA250_CH_CTRL)        = DMA250_CTRL_1D_W;
#if defined(__arm__)
    __asm volatile ("dsb" ::: "memory");
#endif
    REG32(ch + DMA250_CH_CMD)         = DMA250_CMD_ENABLE;

    uint32_t s = 0;
    for (uint32_t i = 0; i < DMA250_DONE_SPINS; i++) {
        s = REG32(ch + DMA250_CH_STATUS);
        if (s & (DMA250_STAT_DONE | DMA250_STAT_ERR)) break;
    }
    if (s & DMA250_STAT_ERR)  { REG32(ch + DMA250_CH_STATUS) = DMA250_STAT_ERR;  return -3; }
    if (!(s & DMA250_STAT_DONE)) return -4;   /* timeout */
    REG32(ch + DMA250_CH_STATUS) = DMA250_STAT_DONE;  /* W1C */
    return 0;
}

int boot_dma250_copy(uintptr_t ch_base, uint32_t dst, uint32_t src,
                     size_t nbytes, int src_cacheable)
{
    if (nbytes & 3u) return -1;            /* word transfers only */
    uint32_t beats = (uint32_t)(nbytes >> 2);
    if (beats == 0u) return 0;

    while (beats > 0u) {
        uint32_t n = (beats > DMA250_MAX_BEATS) ? DMA250_MAX_BEATS : beats;
        int rc = dma250_one(ch_base, dst, src, n, src_cacheable);
        if (rc) return rc;
        uint32_t step = n << 2;
        src += step; dst += step; beats -= n;
    }
    return 0;
}
