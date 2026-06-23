/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - Arm PrimeCell PL022 (SSP) SPI master driver / HAL
 *
 * Software view of the PL022 SSP wrapped as the CPU1-private nanosoc_spi_ss
 * region (planned: src/rtl/wrappers/nanosoc_spi_ss.v + the SSP_SSCTRL chip-
 * select CSR at wrapper offset 0x100). See docs/SPI_PL022_INTEGRATION_PLAN.md
 * for the RTL/YAML/flist integration and docs/SPI_PL022_DMA_DESIGN.md for the
 * DMA-230 hook-up.
 *
 * The PL022 hangs on an APB extension slot of the CPU1 CMSDK peripheral
 * subsystem (cc_periph_subsystem). The APB data bus is 32-bit but the PL022
 * is a 16-bit peripheral (PWDATA[15:0] / PRDATA[15:0]); the wrapper zero-
 * extends reads and forwards the low 16 bits of writes, so from software the
 * registers look like ordinary 32-bit-aligned words whose meaningful payload
 * is the low 16 bits (and only the low 8 for SSPDR when DSS <= 8 bits).
 *
 * ── Multi-master write hazard ───────────────────────────────────────────────
 * This block is reached over the shared multi-master AHB matrix. Back-to-back
 * register writes from the M0+ over that matrix have a known drop hazard (see
 * the IPC / CC-UART notes in docs/ and firmware/apps/ipc_rpc_slave). Every
 * config / data write in this driver is therefore issued through spi_wr_b(),
 * which read-backs the register into a DMEM sink to force the AHB write to
 * retire before the next access. Pure status polling (SSPSR) is read-only and
 * needs no barrier.
 *
 * Register access is via a CMSIS-style volatile struct (matching
 * nanosoc_uart_t in nanosoc_multicore_addrmap.h and nanosoc_evt_route_t in
 * evt_route_ctrl.h). Bit-field macros follow the eth_netapp driver's
 * <REG>_<FIELD>_Pos / _Msk idiom.
 *
 * Target: Arm Cortex-M0+ (CPU1), word-aligned access, no OS. Portable C99.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef SPI_PL022_H
#define SPI_PL022_H

#include <stdint.h>
#include <stddef.h>

/* Host-native cocotb driver-in-the-loop build strips the volatile qualifier
 * (matches firmware/apps/eth_netapp/driver/hal_io.h). */
#if defined(__has_include)
#  if __has_include("hal_io.h")
#    include "hal_io.h"
#  endif
#endif
#ifndef __IO
#  define __IO volatile
#endif
#ifndef __I
#  define __I  volatile const
#endif
#ifndef __O
#  define __O  volatile
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Base address
 *
 * The PL022 region base is configurable — it is one APB extension slot of
 * cc_periph_subsystem (base 0x28000000). The integration plan/DMA note place
 * it on ext slot 12 => +0xC000 => 0x2800C000. Prefer the nanosoc_gen-produced
 * memmap symbol when present (so the driver tracks the regenerated RTL); fall
 * back to the architectural default. Override at compile time with
 * -DSPI_PL022_BASE=0x......
 * ========================================================================= */
#if defined(__has_include)
#  if __has_include("nanosoc_memmap.h")
#    include "nanosoc_memmap.h"
#  endif
#endif

#ifndef SPI_PL022_BASE
#  if defined(NANOSOC_MULTICORE_SOC_SPI_SS_0_BASE)
#    define SPI_PL022_BASE   NANOSOC_MULTICORE_SOC_SPI_SS_0_BASE
#  elif defined(NANOSOC_MULTICORE_SOC_CC_PERIPH_0_BASE)
     /* ext slot 12 of the CPU1 CMSDK APB subsystem (PADDR[15:12] == 0xC). */
#    define SPI_PL022_BASE   (NANOSOC_MULTICORE_SOC_CC_PERIPH_0_BASE + 0x0000C000u)
#  else
#    define SPI_PL022_BASE   0x2800C000u   /* cc_periph 0x28000000 + ext12 0xC000 */
#  endif
#endif

/* =========================================================================
 * PL022 register block (offsets per the PL022 TRM / SspDefs.v PA_* constants).
 * The SSP_SSCTRL wrapper CSR lives on a separate decode page at +0x100 and is
 * NOT part of the vendor PL022 — it is the nanosoc_spi_ss chip-select control.
 * ========================================================================= */
typedef struct {
    __IO uint32_t SSPCR0;       /* 0x000 Control register 0 (format/clock-rate) */
    __IO uint32_t SSPCR1;       /* 0x004 Control register 1 (enable/master/LBM)  */
    __IO uint32_t SSPDR;        /* 0x008 Data register (TX FIFO push / RX FIFO pop) */
    __I  uint32_t SSPSR;        /* 0x00C Status register (RO)                    */
    __IO uint32_t SSPCPSR;      /* 0x010 Clock prescale divisor (even 2..254)    */
    __IO uint32_t SSPIMSC;      /* 0x014 Interrupt mask set/clear                */
    __I  uint32_t SSPRIS;       /* 0x018 Raw interrupt status (RO)               */
    __I  uint32_t SSPMIS;       /* 0x01C Masked interrupt status (RO)            */
    __O  uint32_t SSPICR;       /* 0x020 Interrupt clear (W1C: ROR, RT)          */
    __IO uint32_t SSPDMACR;     /* 0x024 DMA control (RXDMAE/TXDMAE)             */
} spi_pl022_regs_t;

/* SSPSR / interrupt bit positions live below. The wrapper CSR is a single
 * 32-bit register at +0x100 — accessed via its own pointer, not this struct,
 * so the struct stays a faithful 1:1 image of the vendor register map. */
#define SPI_PL022_SSCTRL_OFFSET   0x100u

/* Register block + chip-select CSR pointers. */
#define SPI_PL022 \
    ((spi_pl022_regs_t *)(uintptr_t)SPI_PL022_BASE)
#define SPI_PL022_SSCTRL \
    (*(__IO uint32_t *)(uintptr_t)(SPI_PL022_BASE + SPI_PL022_SSCTRL_OFFSET))

/* -------------------------------------------------------------------------
 * SSPCR0 — frame format / data size / serial-clock-rate
 *   [3:0]  DSS  Data Size Select   (value = bits-1; 0x07 => 8-bit, 0x0F => 16-bit)
 *   [5:4]  FRF  Frame Format       (00 Motorola SPI, 01 TI SSI, 10 National uWire)
 *   [6]    SPO  SPI clock polarity (CPOL)
 *   [7]    SPH  SPI clock phase    (CPHA)
 *   [15:8] SCR  Serial Clock Rate  (additional divider; SCLK = SSPCLK / (CPSDVSR*(1+SCR)))
 * ---------------------------------------------------------------------- */
#define SPI_PL022_SSPCR0_DSS_Pos   0u
#define SPI_PL022_SSPCR0_DSS_Msk   (0xFu << 0)
#define SPI_PL022_SSPCR0_FRF_Pos   4u
#define SPI_PL022_SSPCR0_FRF_Msk   (0x3u << 4)
#define SPI_PL022_SSPCR0_SPO_Msk   (1u << 6)      /* CPOL */
#define SPI_PL022_SSPCR0_SPH_Msk   (1u << 7)      /* CPHA */
#define SPI_PL022_SSPCR0_SCR_Pos   8u
#define SPI_PL022_SSPCR0_SCR_Msk   (0xFFu << 8)

/* DSS encodings (data size = N bits -> field value N-1; 4..16 bits valid). */
#define SPI_PL022_DSS_4BIT   0x3u
#define SPI_PL022_DSS_8BIT   0x7u
#define SPI_PL022_DSS_16BIT  0xFu
#define SPI_PL022_DSS(bits)  (((uint32_t)(bits) - 1u) & 0xFu)

/* FRF encodings. */
#define SPI_PL022_FRF_SPI    0x0u   /* Motorola SPI */
#define SPI_PL022_FRF_TI     0x1u   /* TI synchronous serial */
#define SPI_PL022_FRF_UWIRE  0x2u   /* National Semiconductor Microwire */

/* -------------------------------------------------------------------------
 * SSPCR1 — operating mode
 *   [0] LBM  Loopback mode (internal MOSI->MISO, self-test)
 *   [1] SSE  SSP enable    (1 = run; toggle 0->1 to apply CR0/CPSR changes)
 *   [2] MS   Master/slave  (0 = master — the only mode this driver uses)
 *   [3] SOD  Slave output disable (master: ignored)
 * ---------------------------------------------------------------------- */
#define SPI_PL022_SSPCR1_LBM_Msk   (1u << 0)
#define SPI_PL022_SSPCR1_SSE_Msk   (1u << 1)
#define SPI_PL022_SSPCR1_MS_Msk    (1u << 2)
#define SPI_PL022_SSPCR1_SOD_Msk   (1u << 3)

/* -------------------------------------------------------------------------
 * SSPSR — status (read-only). Bit order {BSY,RFF,RNE,TNF,TFE} per SspApbif.v.
 *   [0] TFE  Transmit FIFO empty
 *   [1] TNF  Transmit FIFO not full   (ok to push another SSPDR word)
 *   [2] RNE  Receive  FIFO not empty  (a word is waiting in SSPDR)
 *   [3] RFF  Receive  FIFO full
 *   [4] BSY  Busy (transmitting/receiving, or TX FIFO not empty)
 * ---------------------------------------------------------------------- */
#define SPI_PL022_SSPSR_TFE_Msk    (1u << 0)
#define SPI_PL022_SSPSR_TNF_Msk    (1u << 1)
#define SPI_PL022_SSPSR_RNE_Msk    (1u << 2)
#define SPI_PL022_SSPSR_RFF_Msk    (1u << 3)
#define SPI_PL022_SSPSR_BSY_Msk    (1u << 4)

/* -------------------------------------------------------------------------
 * SSPCPSR — clock prescale divisor. Even value 2..254. Combined with SCR:
 *   SCLK = SSPCLK / (CPSDVSR * (1 + SCR))
 * SSPCLK == HCLK here (NANOSOC_SYS_CLK_FREQ_HZ).
 * ---------------------------------------------------------------------- */
#define SPI_PL022_CPSDVSR_MIN  2u
#define SPI_PL022_CPSDVSR_MAX  254u

/* -------------------------------------------------------------------------
 * SSPIMSC / SSPRIS / SSPMIS / SSPICR — interrupts (bits per SspDefs/Ssp.v).
 *   [0] ROR  Receive overrun       (SSPICR W1C)
 *   [1] RT   Receive timeout        (SSPICR W1C)
 *   [2] RX   RX FIFO >= 1/2 full    (cleared by draining RX FIFO)
 *   [3] TX   TX FIFO <= 1/2 empty   (cleared by filling TX FIFO)
 * ---------------------------------------------------------------------- */
#define SPI_PL022_INT_ROR_Msk      (1u << 0)
#define SPI_PL022_INT_RT_Msk       (1u << 1)
#define SPI_PL022_INT_RX_Msk       (1u << 2)
#define SPI_PL022_INT_TX_Msk       (1u << 3)
#define SPI_PL022_INT_ALL_Msk      (0xFu)
#define SPI_PL022_ICR_ALL_Msk      (SPI_PL022_INT_ROR_Msk | SPI_PL022_INT_RT_Msk)

/* -------------------------------------------------------------------------
 * SSPDMACR — DMA control. See docs/SPI_PL022_DMA_DESIGN.md.
 *   [0] RXDMAE  Enable RX DMA request lines (SSPRXDMASREQ/BREQ)
 *   [1] TXDMAE  Enable TX DMA request lines (SSPTXDMASREQ/BREQ)
 * ---------------------------------------------------------------------- */
#define SPI_PL022_SSPDMACR_RXDMAE_Msk  (1u << 0)
#define SPI_PL022_SSPDMACR_TXDMAE_Msk  (1u << 1)

/* =========================================================================
 * SSP_SSCTRL — nanosoc_spi_ss chip-select control CSR @ wrapper +0x100.
 * Fields per docs/SPI_PL022_INTEGRATION_PLAN.md §5.1. Reset value 0x000
 * (direct one-hot mode, all CS deasserted).
 *   [2:0] ss_sel       active slave (direct: target index; decoder: bin addr)
 *   [4]   ss_enable    master CS enable (0 = all deasserted)
 *   [5]   cs_hold      1 = hold CS for the whole transaction (multi-byte)
 *                      0 = follow PL022 SSPFSSOUT per-frame
 *   [8]   ss_decode_en 0 = direct one-hot CS; 1 = encoded for external decoder
 * ========================================================================= */
#define SPI_PL022_SSCTRL_SSSEL_Pos       0u
#define SPI_PL022_SSCTRL_SSSEL_Msk       (0x7u << 0)
#define SPI_PL022_SSCTRL_SSEN_Msk        (1u << 4)
#define SPI_PL022_SSCTRL_CSHOLD_Msk      (1u << 5)
#define SPI_PL022_SSCTRL_DECODE_EN_Msk   (1u << 8)

/* =========================================================================
 * Driver configuration + handle
 * ========================================================================= */

/* Default SSPCLK feeding the PL022 (== HCLK). Used for bit-rate divider math
 * when not overridden by the generated memmap. */
#ifndef SPI_PL022_SSPCLK_HZ
#  ifdef NANOSOC_SYS_CLK_FREQ_HZ
#    define SPI_PL022_SSPCLK_HZ   NANOSOC_SYS_CLK_FREQ_HZ
#  else
#    define SPI_PL022_SSPCLK_HZ   100000000u
#  endif
#endif

typedef enum {
    SPI_MODE0 = 0,  /* CPOL=0 CPHA=0 */
    SPI_MODE1 = 1,  /* CPOL=0 CPHA=1 */
    SPI_MODE2 = 2,  /* CPOL=1 CPHA=0 */
    SPI_MODE3 = 3   /* CPOL=1 CPHA=1 */
} spi_mode_t;

typedef struct {
    uint32_t   bit_rate_hz;   /* desired SCLK; init() picks CPSDVSR/SCR for <= this */
    uint8_t    data_bits;     /* frame size in bits, 4..16 (8 typical) */
    spi_mode_t mode;          /* CPOL/CPHA */
    uint8_t    frame_format;  /* SPI_PL022_FRF_* (SPI normally) */
    uint8_t    loopback;      /* 1 = internal LBM self-test */
} spi_pl022_cfg_t;

/* Return codes. */
#define SPI_OK         0
#define SPI_EINVAL    (-1)
#define SPI_ETIMEOUT  (-2)

/* Default poll budget (loop iterations) for blocking transfers. 0 = infinite. */
#ifndef SPI_PL022_POLL_TIMEOUT
#define SPI_PL022_POLL_TIMEOUT  0u
#endif

/* =========================================================================
 * Public API (implemented in spi_pl022.c)
 * ========================================================================= */

/* Configure SSPCR0/CR1/CPSR for the requested format and bit rate, leaving the
 * SSP DISABLED (SSE=0); call spi_pl022_enable() when ready. Returns SPI_OK or
 * SPI_EINVAL on an out-of-range field / unreachable bit rate. */
int spi_pl022_init(const spi_pl022_cfg_t *cfg);

/* Enable / disable the SSP (SSPCR1.SSE). Format/CPSR changes only take effect
 * across a disable->enable cycle. */
void spi_pl022_enable(void);
void spi_pl022_disable(void);

/* ---- Chip-select control (SSP_SSCTRL wrapper CSR) ----
 * select() asserts CS for slave `slave` (direct one-hot index, or binary
 * decoder address when in decoder mode), optionally holding it across the
 * whole transaction (hold != 0 => cs_hold). deselect() drops ss_enable.
 * Discipline: always deselect() before changing the selected slave in decoder
 * mode (the CSR momentarily points the decoder elsewhere otherwise). */
void spi_pl022_set_decode_mode(int decoder_enabled);  /* 0 = direct, 1 = decoder */
void spi_pl022_select(uint8_t slave, int hold);
void spi_pl022_deselect(void);

/* ---- Blocking transfers (poll SSPSR) ----
 * transfer() pushes one TX frame and returns the simultaneously-received RX
 * frame (full-duplex). For a half-duplex write, ignore the return; for a read,
 * push a dummy (e.g. 0xFF). data_bits<=8 use the low byte, 9..16 the low 16.
 * Returns the RX frame (>=0) or a negative SPI_E* on timeout. */
int spi_pl022_transfer(uint16_t tx);

/* Full-duplex buffer transfer of `len` frames. tx/rx may be NULL (NULL tx ->
 * pushes dummy 0xFF; NULL rx -> received data discarded) and may alias the
 * same buffer. Frame width follows the last spi_pl022_init(). Returns SPI_OK
 * or SPI_ETIMEOUT. Does NOT touch chip-selects — bracket with select()/
 * deselect() (use hold=1 for multi-frame device protocols). */
int spi_pl022_transfer_buf(const uint8_t *tx, uint8_t *rx, size_t len);

/* Wait until the SSP has drained (TX FIFO empty AND not BSY). */
int spi_pl022_flush(void);

/* ---- IRQ-driven transfer (skeleton) ----
 * Arms the TX/RX FIFO-service interrupts and registers the caller's buffers;
 * the matching ISR body (to be installed on the chosen NVIC line — see the
 * integration plan §7.5 IRQ routing) drains/fills via spi_pl022_irq_handler().
 * This is a non-blocking start; poll spi_pl022_irq_done() for completion. */
void spi_pl022_irq_start(const uint8_t *tx, uint8_t *rx, size_t len);
void spi_pl022_irq_handler(void);     /* call from the SSP NVIC ISR */
int  spi_pl022_irq_done(void);        /* non-zero once the transfer completed */

/* ---- DMA-driven transfer (skeleton) ----
 * Sets SSPDMACR TXDMAE/RXDMAE and expects the DMA-230 channels to already be
 * programmed (descriptor + CHNL_ENABLE_SET) per docs/SPI_PL022_DMA_DESIGN.md.
 * These are intentionally thin: the heavy lifting is DMA-230 channel setup,
 * which is SoC-wiring dependent and documented in the DMA design note. */
void spi_pl022_dma_tx_enable(int en);
void spi_pl022_dma_rx_enable(int en);

#ifdef __cplusplus
}
#endif

#endif /* SPI_PL022_H */
