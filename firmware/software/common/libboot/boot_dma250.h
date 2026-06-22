/*----------------------------------------------------------------------------
 * boot_dma250 — generic Arm CoreLink DMA-250 single memcpy for staged boot.
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * Reusable across nanosoc systems (lives in arch_tech). Register interface taken
 * from the validated nanosoc DMA-250 boot-copy. The channel base + addresses are
 * passed by the system, so this stays board-agnostic.
 *
 * The DMA-250's 16-bit XSIZE allows up to 65535 word-beats (256 KB) per cycle;
 * larger copies are chunked here. Set `src_cacheable` for QSPI-XiP sources so the
 * DMA drives HPROT[3]=1 and the XiP cache serves the flash fetch.
 *----------------------------------------------------------------------------*/
#ifndef BOOT_DMA250_H
#define BOOT_DMA250_H

#include <stdint.h>
#include <stddef.h>

/* Per-channel register offsets from the channel base. */
#define DMA250_CH_CMD         0x000u   /* [0]=ENABLE, [1]=CLEAR                  */
#define DMA250_CH_STATUS      0x004u   /* [16]=DONE, [17]=ERR (W1C)             */
#define DMA250_CH_CTRL        0x00Cu   /* TRANSIZE[2:0] XTYPE[11:9] DONETYPE[22:21] */
#define DMA250_CH_SRCADDR     0x010u
#define DMA250_CH_DESADDR     0x018u
#define DMA250_CH_XSIZE       0x020u   /* [15:0]=SRC beats, [31:16]=DES beats   */
#define DMA250_CH_SRCTRANSCFG 0x028u   /* source memory attributes              */
#define DMA250_CH_XADDRINC    0x030u   /* [15:0]=SRC inc, [31:16]=DES inc       */

#define DMA250_CMD_ENABLE     (1u << 0)
#define DMA250_CMD_CLEAR      (1u << 1)
#define DMA250_STAT_DONE      (1u << 16)
#define DMA250_STAT_ERR       (1u << 17)
/* word transfer (TRANSIZE=2), 1D (XTYPE=1), end-of-cycle done (DONETYPE=1). */
#define DMA250_CTRL_1D_W      ((2u << 0) | (1u << 9) | (1u << 21))
/* Normal memory, inner+outer write-back cacheable -> HPROT[3]=1 (XiP cache). */
#define DMA250_SRC_CACHEABLE  0x000000FFu

#define DMA250_MAX_BEATS      0xFFFFu   /* 16-bit XSIZE */

/* Word-copy `nbytes` (must be 4-aligned) from `src` to `dst` via the channel at
 * `ch_base`. Chunks transfers > 256 KB. Returns 0 on success, <0 on error. */
int boot_dma250_copy(uintptr_t ch_base, uint32_t dst, uint32_t src,
                     size_t nbytes, int src_cacheable);

#endif /* BOOT_DMA250_H */
