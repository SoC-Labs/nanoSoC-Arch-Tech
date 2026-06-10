/*
 *-----------------------------------------------------------------------------
 * nanosoc - Arm CoreLink DMA-250 (CG097) minimal driver
 *
 * Clean-room SoC-Labs driver for the Arm CoreLink DMA-250 controller. The
 * register layout (block bases, per-channel stride, field positions) was
 * derived by inspection of the Arm-supplied register-definition headers
 *   dma250_regdef.h / dma250_reg_typedef.h (DMA250-r0p0-00eac0)
 * which are license-restricted verification aids and "must not be used as a
 * driver library". No Arm source is copied here; only the documented register
 * map is reproduced, which is the same information published in the DMA-250
 * Technical Reference Manual.
 *
 * Scope: enough of the controller to issue an immediate (non-linked) 1D
 * memory-to-memory copy purely by register writes - no in-memory command
 * descriptor, LINKADDR disabled. This mirrors the Arm command-lib flow
 *   Dma250ChannelInit() -> Dma2501DIncrCommand() -> Dma250Enable()
 * collapsed into a single helper.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef __DMA250_DRIVER_H
#define __DMA250_DRIVER_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

/* -------------------------------------------------------------------------
 * Base address.
 *
 * The DMA-250 occupies the same top-level SoC slot the PL230 / DMA-230
 * occupied in the nanosoc multicore map: the 0x20000000 shared-peripheral
 * window (NANOSOC_DMA230_APB_BASE). Keep it overridable so the same driver
 * works in cocotb / on a relocated slot / against the Arm verification base
 * (0x40002000) without an edit.
 *
 * If the project address-map header is on the include path we anchor to its
 * NANOSOC_DMA230_APB_BASE; otherwise fall back to the bare 0x20000000.
 * Either can be overridden from the command line with -DDMA250_BASE=...
 * ---------------------------------------------------------------------- */
#ifndef DMA250_BASE
#  if defined(__has_include)
#    if __has_include("nanosoc_multicore_addrmap.h")
#      include "nanosoc_multicore_addrmap.h"
#    endif
#  endif
#  if defined(NANOSOC_DMA230_APB_BASE)
#    define DMA250_BASE   NANOSOC_DMA230_APB_BASE
#  else
#    define DMA250_BASE   0x20000000UL
#  endif
#endif

/* -------------------------------------------------------------------------
 * Register-block layout (confirmed against dma250_regdef.h).
 *
 *   DMASECCFG   = DMA250_BASE + 0x0000   (secure configuration)
 *   DMASECCTRL  = DMA250_BASE + 0x0100   (secure global control / status)
 *   DMANSECCTRL = DMA250_BASE + 0x0200   (non-secure global control / status)
 *   DMAINFO     = DMA250_BASE + 0x0F00   (id / build-config block)
 *   DMACH0      = DMA250_BASE + 0x1000   (channel 0 register block)
 *   DMACHn      = DMA250_BASE + 0x1000 + n*0x100   (per-channel stride 0x100)
 * ---------------------------------------------------------------------- */
#define DMA250_SECCFG_OFFSET     0x0000UL
#define DMA250_SECCTRL_OFFSET    0x0100UL
#define DMA250_NSECCTRL_OFFSET   0x0200UL
#define DMA250_INFO_OFFSET       0x0F00UL
#define DMA250_CH0_OFFSET        0x1000UL   /* channel 0 base offset */
#define DMA250_CH_STRIDE         0x0100UL   /* per-channel block stride */

/* -------------------------------------------------------------------------
 * Per-channel register block (DMACH_TypeDef). Offsets confirmed against
 * dma250_regdef.h; RESERVED holes preserved so the struct overlays MMIO
 * 1:1 and a plain pointer cast lands every register on its TRM offset.
 * ---------------------------------------------------------------------- */
typedef struct {
    volatile uint32_t CH_CMD;          /* 0x000 Channel DMA Command            */
    volatile uint32_t CH_STATUS;       /* 0x004 Channel Status                 */
    volatile uint32_t CH_INTREN;       /* 0x008 Channel Interrupt Enable       */
    volatile uint32_t CH_CTRL;         /* 0x00C Channel Control                */
    volatile uint32_t CH_SRCADDR;      /* 0x010 Source Address                 */
    volatile uint32_t RESERVED0;       /* 0x014                                */
    volatile uint32_t CH_DESADDR;      /* 0x018 Destination Address            */
    volatile uint32_t RESERVED1;       /* 0x01C                                */
    volatile uint32_t CH_XSIZE;        /* 0x020 X size [15:0]=SRC,[31:16]=DES  */
    volatile uint32_t RESERVED2;       /* 0x024                                */
    volatile uint32_t CH_SRCTRANSCFG;  /* 0x028 Source Transfer Config         */
    volatile uint32_t CH_DESTRANSCFG;  /* 0x02C Destination Transfer Config    */
    volatile uint32_t CH_XADDRINC;     /* 0x030 X addr inc [15:0]=SRC,[31:16]=DES */
    volatile uint32_t RESERVED3[6];    /* 0x034 - 0x048                        */
    volatile uint32_t CH_SRCTRIGINCFG; /* 0x04C Source Trigger-In Config       */
    volatile uint32_t CH_DESTRIGINCFG; /* 0x050 Dest Trigger-In Config         */
    volatile uint32_t CH_TRIGOUTCFG;   /* 0x054 Trigger-Out Config             */
    volatile uint32_t CH_GPOEN0;       /* 0x058 GPO Drive Enable 0             */
    volatile uint32_t RESERVED4;       /* 0x05C                                */
    volatile uint32_t CH_GPOVAL0;      /* 0x060 GPO Value 0                    */
    volatile uint32_t RESERVED5[3];    /* 0x064 - 0x06C                        */
    volatile uint32_t CH_LINKATTR;     /* 0x070 Link Addr Memory Attributes    */
    volatile uint32_t CH_AUTOCFG;      /* 0x074 Auto Command Restart Config    */
    volatile uint32_t CH_LINKADDR;     /* 0x078 Link Address [0]=LINKADDREN     */
    volatile uint32_t RESERVED6;       /* 0x07C                                */
    volatile uint32_t CH_GPOREAD0;     /* 0x080 GPO Read Value 0               */
    volatile uint32_t RESERVED7[3];    /* 0x084 - 0x08C                        */
    volatile uint32_t CH_ERRINFO;      /* 0x090 Error Information               */
    volatile uint32_t RESERVED8[13];   /* 0x094 - 0x0C4                        */
    volatile uint32_t CH_IIDR;         /* 0x0C8 Channel Implementation ID      */
    volatile uint32_t CH_AIDR;         /* 0x0CC Channel Architecture ID        */
    volatile uint32_t RESERVED9[10];   /* 0x0D0 - 0x0F4                        */
    volatile uint32_t CH_BUILDCFG0;    /* 0x0F8 Channel Build Config 0         */
    volatile uint32_t CH_BUILDCFG1;    /* 0x0FC Channel Build Config 1         */
} dma250_channel_t;

/* -------------------------------------------------------------------------
 * Global DMA INFO / build-config block (DMAINFO_TypeDef). Only the few
 * fields the driver actually reads are documented; offsets are relative to
 * DMAINFO base (DMA250_BASE + 0x0F00).
 * ---------------------------------------------------------------------- */
typedef struct {
    volatile uint32_t RESERVED0[44];   /* 0x000 - 0x0AC                        */
    volatile uint32_t DMA_BUILDCFG0;   /* 0x0B0 [9:4]=NUM_CHANNELS, etc.       */
    volatile uint32_t DMA_BUILDCFG1;   /* 0x0B4                                */
    volatile uint32_t DMA_BUILDCFG2;   /* 0x0B8                                */
    volatile uint32_t RESERVED1[3];    /* 0x0BC - 0x0C4                        */
    volatile uint32_t IIDR;            /* 0x0C8 Implementation ID              */
    volatile uint32_t AIDR;            /* 0x0CC Architecture ID                */
} dma250_info_t;

/* Pointer to channel n. */
#define DMA250_CH(n) \
    ((dma250_channel_t *)(DMA250_BASE + DMA250_CH0_OFFSET + \
                          (uint32_t)(n) * DMA250_CH_STRIDE))
#define DMA250_INFO  ((dma250_info_t *)(DMA250_BASE + DMA250_INFO_OFFSET))

/* -------------------------------------------------------------------------
 * CH_CMD (0x000) field bits.
 * ---------------------------------------------------------------------- */
#define DMA250_CMD_ENABLECMD   (1u << 0)   /* start the programmed command; self-clears on done */
#define DMA250_CMD_CLEARCMD    (1u << 1)   /* clear channel regs / internal state               */
#define DMA250_CMD_DISABLECMD  (1u << 2)   /* stop after current command                        */
#define DMA250_CMD_STOPCMD     (1u << 3)   /* stop current command immediately                  */

/* -------------------------------------------------------------------------
 * CH_STATUS (0x004) field bits. INTR_* are the W1C interrupt flags in the
 * low half; STAT_* are the live status flags in the high half.
 * ---------------------------------------------------------------------- */
#define DMA250_STATUS_INTR_DONE      (1u << 0)   /* W1C done interrupt flag      */
#define DMA250_STATUS_INTR_ERR       (1u << 1)   /* W1C error interrupt flag     */
#define DMA250_STATUS_INTR_DISABLED  (1u << 2)   /* W1C disabled interrupt flag  */
#define DMA250_STATUS_INTR_STOPPED   (1u << 3)   /* W1C stopped interrupt flag   */
#define DMA250_STATUS_STAT_DONE      (1u << 16)  /* W1C command-complete status  */
#define DMA250_STATUS_STAT_ERR       (1u << 17)  /* W1C error status             */
#define DMA250_STATUS_STAT_DISABLED  (1u << 18)
#define DMA250_STATUS_STAT_STOPPED   (1u << 19)

/* -------------------------------------------------------------------------
 * CH_INTREN (0x008) field bits.
 * ---------------------------------------------------------------------- */
#define DMA250_INTREN_DONE  (1u << 0)
#define DMA250_INTREN_ERR   (1u << 1)

/* -------------------------------------------------------------------------
 * CH_CTRL (0x00C) fields used for a 1D copy.
 *   TRANSIZE[2:0] @0   : log2(beat size in bytes): 0=8b,1=16b,2=32b,...
 *   XTYPE[2:0]    @9   : transfer template; 1 = 1D ("continue") transfer
 *   DONETYPE[1:0] @21  : when STAT_DONE asserts; 1 = at end of command
 * ---------------------------------------------------------------------- */
#define DMA250_CTRL_TRANSIZE_Pos   0
#define DMA250_CTRL_TRANSIZE_Msk   (0x7u << DMA250_CTRL_TRANSIZE_Pos)
#define DMA250_CTRL_XTYPE_Pos      9
#define DMA250_CTRL_XTYPE_Msk      (0x7u << DMA250_CTRL_XTYPE_Pos)
#define DMA250_CTRL_DONETYPE_Pos   21
#define DMA250_CTRL_DONETYPE_Msk   (0x3u << DMA250_CTRL_DONETYPE_Pos)

#define DMA250_TRANSIZE_8   0u   /* 1 byte  per beat */
#define DMA250_TRANSIZE_16  1u   /* 2 bytes per beat */
#define DMA250_TRANSIZE_32  2u   /* 4 bytes per beat */

#define DMA250_XTYPE_DISABLE 0u  /* no command   */
#define DMA250_XTYPE_CONTINUE 1u /* 1D transfer  */

#define DMA250_DONETYPE_END_OF_CMD 1u  /* STAT_DONE at end of command cycle */

/* CH_XSIZE (0x020): SRCXSIZE in [15:0], DESXSIZE in [31:16] (beat counts). */
#define DMA250_XSIZE(src, des) (((uint32_t)(src) & 0xFFFFu) | \
                                (((uint32_t)(des) & 0xFFFFu) << 16))
/* CH_XADDRINC (0x030): SRCXADDRINC in [15:0], DESXADDRINC in [31:16]. A value
 * of 1 increments the address by one TRANSIZE beat per transfer. */
#define DMA250_XADDRINC(src, des) (((uint32_t)(src) & 0xFFFFu) | \
                                   (((uint32_t)(des) & 0xFFFFu) << 16))

/* CH_LINKADDR (0x078) bit0 = LINKADDREN. We always leave it 0 (immediate,
 * non-linked command). */
#define DMA250_LINKADDR_EN  (1u << 0)

/* -------------------------------------------------------------------------
 * API
 * ---------------------------------------------------------------------- */

/* Bring a channel to a clean idle state: issue CLEARCMD and W1C any pending
 * status/interrupt flags. Safe to call before programming a new command. */
void dma250_init(uint32_t ch);

/* Program and start an immediate (non-linked) 1D word-wise memory-to-memory
 * copy on channel `ch`. Both addresses are incremented by one 32-bit beat per
 * transfer. `nbytes` should be a multiple of 4 (whole 32-bit beats); a partial
 * tail is rounded down. Returns 0 if a command was issued, non-zero on bad
 * arguments (null pointer or zero/short length). Does not wait. */
int dma250_mem2mem_1d(uint32_t ch, void *src, void *dst, uint32_t nbytes);

/* Poll CH_STATUS until the channel reports completion. Returns 0 on success
 * (STAT_DONE), non-zero if STAT_ERR was observed instead. */
int dma250_wait_done(uint32_t ch);

/* Write-1-clear the done/error status and interrupt flags on `ch`. */
void dma250_irq_clear(uint32_t ch);

#ifdef __cplusplus
}
#endif

#endif /* __DMA250_DRIVER_H */
