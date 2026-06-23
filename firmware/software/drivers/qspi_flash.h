/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - qspi_flash.h : reusable AHB-QSPI flash primitives
 *
 * Header-only, no statics-with-state: extracted verbatim (behaviour-for-
 * behaviour) from firmware/apps/qspi_flasher/main.c so a SECOND consumer (the
 * TFTP flash-update service in eth_netapp) can erase/program/verify the
 * external SPI flash without duplicating the CDC-race-hardened command engine.
 *
 * The qspi_flasher app itself is deliberately left untouched (it has its own
 * private copies of these functions); this header exists so new code reuses the
 * same, bench-characterised primitives. All functions are `static inline` so a
 * translation unit that includes this header gets its own copy — there is no
 * global state, the only state is the memory-mapped controller.
 *
 * Targets: Micron N25Q256A (real HW) and SST26VF064B (cocotb VIP). Both use the
 * 0xD8 64 KB sector erase and 0x02 page program. See qspi_flasher/main.c for the
 * full rationale behind the BUSY set->clear wait, the FAST_READ +1 dummy cycle
 * compensation, the sub-word RDATA byte-lane shift, and the ULBPR unlock.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef NANOSOC_QSPI_FLASH_H
#define NANOSOC_QSPI_FLASH_H

#include <stdint.h>
#include <stddef.h>

/* Base-address resolution (portable across nanosoc systems): pull in the
 * generated memory map when present, then resolve NANOSOC_QSPI_APB_BASE from
 * the generated symbol, falling back to the default APB aperture. Define
 * NANOSOC_QSPI_APB_BASE before including this header to override. */
#if defined(__has_include)
#  if __has_include("nanosoc_memmap.h")
#    include "nanosoc_memmap.h"
#  endif
#endif
#ifndef NANOSOC_QSPI_APB_BASE
#  if defined(NANOSOC_MULTICORE_SOC_QSPI_FLASH_0_BASE)
#    define NANOSOC_QSPI_APB_BASE   NANOSOC_MULTICORE_SOC_QSPI_FLASH_0_BASE
#  else
#    define NANOSOC_QSPI_APB_BASE   0x21000000u  /* default QSPI APB cfg aperture */
#  endif
#endif

/* ---- AHB QSPI APB register block (offsets from apb_qspi_regs.rdl) ------ */

#ifndef QSPI_FLASH_REG32
#define QSPI_FLASH_REG32(a)    (*(volatile uint32_t *)(uintptr_t)(a))
#endif
#define QSPI_FLASH_REG(off)    QSPI_FLASH_REG32(NANOSOC_QSPI_APB_BASE + (off))

#define QSPI_FLASH_CTRL          0x0000u
#define QSPI_FLASH_STATUS        0x0004u
#define QSPI_FLASH_SPI_CMD       0x0008u
#define QSPI_FLASH_SPI_ADDR      0x000Cu
#define QSPI_FLASH_RDATA0        0x0010u
#define QSPI_FLASH_RDATA1        0x0014u
#define QSPI_FLASH_RDATA2        0x0018u
#define QSPI_FLASH_RDATA3        0x001Cu
#define QSPI_FLASH_WDATA0        0x0020u
#define QSPI_FLASH_WDATA1        0x0024u
#define QSPI_FLASH_WDATA2        0x0028u
#define QSPI_FLASH_WDATA3        0x002Cu

#define QSPI_FLASH_CTRL_XIP_ACTIVE  (1u << 8)
#define QSPI_FLASH_STATUS_BUSY      (1u << 0)

#define QSPI_FLASH_CMD_CMD_SHIFT    0
#define QSPI_FLASH_CMD_ENABLE       (1u << 8)
#define QSPI_FLASH_CMD_READ         (1u << 9)
#define QSPI_FLASH_CMD_WRITE        (1u << 10)
#define QSPI_FLASH_CMD_ADDR_EN      (1u << 11)
#define QSPI_FLASH_CMD_DUMMY_SHIFT  12   /* 4 bits, N-1 dummy cycles */
#define QSPI_FLASH_CMD_NRW_SHIFT    16   /* 4 bits, N-1 data bytes   */

/* Standard SPI flash opcodes (Micron N25Q256A / SST26VF064B) */
#define QSPI_FLASH_CMD_WREN      0x06u
#define QSPI_FLASH_CMD_RDSR      0x05u
#define QSPI_FLASH_CMD_SE_64K    0xD8u
#define QSPI_FLASH_CMD_PP        0x02u
#define QSPI_FLASH_CMD_READ_OP   0x0Bu  /* FAST_READ */
#define QSPI_FLASH_CMD_READ_DUMMY 9u    /* controller off-by-one: nominal 8 + 1 */
#define QSPI_FLASH_CMD_ULBPR     0x98u  /* SST global block-protection unlock */
#define QSPI_FLASH_SR_WIP        (1u << 0)

/* Flash geometry. */
#define QSPI_FLASH_SECTOR_SIZE   0x10000u   /* 64 KB sector erase (0xD8) */
#define QSPI_FLASH_PAGE_SIZE     256u
#define QSPI_FLASH_CHUNK_SIZE    16u        /* QSPI controller FIFO depth */

/* ---- Command engine (see qspi_flasher/main.c for the full rationale) ----- */

/* Wait for the just-issued SPI command to COMPLETE: fence the CMD write, then
 * wait BUSY set->clear. The set-wait is bounded so an absent controller can't
 * hang. The CDC chain means BUSY is not 1 immediately after the CMD write, so
 * the bare `while(BUSY)` poll on a fast M0+ core can fall straight through. */
static inline void qspi_flash_wait_busy(void)
{
    (void)QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD);   /* read-back: ensure CMD landed */
    __asm volatile("dsb" ::: "memory");
    uint32_t g = 0;
    while (!(QSPI_FLASH_REG(QSPI_FLASH_STATUS) & QSPI_FLASH_STATUS_BUSY) && ++g < 100000u) { }
    uint32_t c = 0;
    while ( (QSPI_FLASH_REG(QSPI_FLASH_STATUS) & QSPI_FLASH_STATUS_BUSY) && ++c < 1000000u) { }
}

/* No-data command (e.g. WREN). Auto-clears ENABLE in HW. */
static inline void qspi_flash_cmd0(uint8_t opcode)
{
    QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD) =
        ((uint32_t)opcode << QSPI_FLASH_CMD_CMD_SHIFT) | QSPI_FLASH_CMD_ENABLE;
    qspi_flash_wait_busy();
}

/* Read command with N data bytes (<= 16), right-justified in the low bytes. */
static inline uint32_t qspi_flash_cmd_read(uint8_t opcode, uint8_t n_bytes)
{
    QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD) =
        ((uint32_t)opcode << QSPI_FLASH_CMD_CMD_SHIFT) |
        QSPI_FLASH_CMD_ENABLE | QSPI_FLASH_CMD_READ |
        ((uint32_t)(n_bytes - 1u) << QSPI_FLASH_CMD_NRW_SHIFT);
    qspi_flash_wait_busy();
    uint32_t raw = QSPI_FLASH_REG(QSPI_FLASH_RDATA0);
    if (n_bytes < 4u) raw >>= 8u * (4u - n_bytes);   /* sub-word: top-justified */
    return raw;
}

/* Read with address phase (FAST_READ 0x0B + 24-bit addr + dummy). Up to 16 B. */
static inline void qspi_flash_cmd_read_addr(uint8_t opcode, uint32_t addr,
                                            uint8_t n_bytes, uint32_t out[4])
{
    QSPI_FLASH_REG(QSPI_FLASH_SPI_ADDR) = addr;
    QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD) =
        ((uint32_t)opcode << QSPI_FLASH_CMD_CMD_SHIFT) |
        QSPI_FLASH_CMD_ENABLE | QSPI_FLASH_CMD_READ | QSPI_FLASH_CMD_ADDR_EN |
        ((uint32_t)(QSPI_FLASH_CMD_READ_DUMMY - 1u) << QSPI_FLASH_CMD_DUMMY_SHIFT) |
        ((uint32_t)(n_bytes - 1u) << QSPI_FLASH_CMD_NRW_SHIFT);
    qspi_flash_wait_busy();
    out[0] = QSPI_FLASH_REG(QSPI_FLASH_RDATA0);
    out[1] = QSPI_FLASH_REG(QSPI_FLASH_RDATA1);
    out[2] = QSPI_FLASH_REG(QSPI_FLASH_RDATA2);
    out[3] = QSPI_FLASH_REG(QSPI_FLASH_RDATA3);
}

/* Write with address phase (PP 0x02 + 24-bit addr + up to 16 bytes). */
static inline void qspi_flash_cmd_write_addr(uint8_t opcode, uint32_t addr,
                                             uint8_t n_bytes, const uint8_t *data)
{
    uint32_t w[4] = {0, 0, 0, 0};
    for (uint8_t i = 0; i < n_bytes; ++i)
        w[i / 4] |= ((uint32_t)data[i]) << ((i % 4) * 8);
    QSPI_FLASH_REG(QSPI_FLASH_WDATA0) = w[0];
    QSPI_FLASH_REG(QSPI_FLASH_WDATA1) = w[1];
    QSPI_FLASH_REG(QSPI_FLASH_WDATA2) = w[2];
    QSPI_FLASH_REG(QSPI_FLASH_WDATA3) = w[3];
    QSPI_FLASH_REG(QSPI_FLASH_SPI_ADDR) = addr;
    QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD) =
        ((uint32_t)opcode << QSPI_FLASH_CMD_CMD_SHIFT) |
        QSPI_FLASH_CMD_ENABLE | QSPI_FLASH_CMD_WRITE | QSPI_FLASH_CMD_ADDR_EN |
        ((uint32_t)(n_bytes - 1u) << QSPI_FLASH_CMD_NRW_SHIFT);
    qspi_flash_wait_busy();
}

/* Spin until the flash internal write/erase finishes (RDSR.WIP = 0). Bounded so
 * a flash that never clears WIP (e.g. a program/erase the device silently
 * aborted — as the cocotb SST26VF064B VIP does for a write-protected page) cannot
 * wedge the caller forever. The bound is generous (a real 64 KB sector erase is
 * ~700 ms, a page program ~ms); on real hardware WIP always clears well within
 * it, so HW behaviour is unchanged. Returns when WIP clears or the bound trips. */
#ifndef QSPI_FLASH_WIP_LIMIT
#define QSPI_FLASH_WIP_LIMIT  (1u << 24)
#endif
static inline void qspi_flash_wait_wip(void)
{
    for (uint32_t i = 0u; i < QSPI_FLASH_WIP_LIMIT; i++) {
        uint32_t sr = qspi_flash_cmd_read(QSPI_FLASH_CMD_RDSR, 1);
        if ((sr & QSPI_FLASH_SR_WIP) == 0u) return;
    }
}

/* ---- High-level operations --------------------------------------------- */

/* Put the controller in APB-driven mode and clear SST global block protection.
 * Call once before any erase/program. ULBPR is a no-op on N25Q256A. */
static inline void qspi_flash_unlock(void)
{
    QSPI_FLASH_REG(QSPI_FLASH_CTRL) &= ~QSPI_FLASH_CTRL_XIP_ACTIVE;
    qspi_flash_cmd0(QSPI_FLASH_CMD_WREN);
    qspi_flash_cmd0(QSPI_FLASH_CMD_ULBPR);
}

/* Erase one 64 KB sector at the given flash byte offset. */
static inline void qspi_flash_sector_erase(uint32_t addr)
{
    qspi_flash_cmd0(QSPI_FLASH_CMD_WREN);
    QSPI_FLASH_REG(QSPI_FLASH_SPI_ADDR) = addr;
    QSPI_FLASH_REG(QSPI_FLASH_SPI_CMD) =
        ((uint32_t)QSPI_FLASH_CMD_SE_64K << QSPI_FLASH_CMD_CMD_SHIFT) |
        QSPI_FLASH_CMD_ENABLE | QSPI_FLASH_CMD_ADDR_EN;
    qspi_flash_wait_busy();
    qspi_flash_wait_wip();
}

/* Program up to QSPI_FLASH_CHUNK_SIZE (16) bytes at a flash offset. */
static inline void qspi_flash_program_chunk(uint32_t addr, const uint8_t *data, uint8_t n)
{
    qspi_flash_cmd0(QSPI_FLASH_CMD_WREN);
    qspi_flash_cmd_write_addr(QSPI_FLASH_CMD_PP, addr, n, data);
    qspi_flash_wait_wip();
}

/* Program an arbitrary-length buffer to flash, 16-byte chunks. Page-program
 * frames never cross a 256-byte page because 16 divides 256. */
static inline void qspi_flash_program(uint32_t addr, const uint8_t *data, uint32_t len)
{
    for (uint32_t off = 0u; off < len; off += QSPI_FLASH_CHUNK_SIZE) {
        uint32_t rem = len - off;
        uint8_t  n   = (rem >= QSPI_FLASH_CHUNK_SIZE) ? (uint8_t)QSPI_FLASH_CHUNK_SIZE
                                                      : (uint8_t)rem;
        qspi_flash_program_chunk(addr + off, data + off, n);
    }
}

/* Read-back verify a buffer. Returns 0 on full match, else (offset+1) of first
 * mismatch. NB the SST26VF064B VIP returns 0x00 for protected reads in sim, so
 * cocotb cross-checks the flash model directly (see soc_qspi_flasher). */
static inline int qspi_flash_verify(uint32_t addr, const uint8_t *expected, uint32_t len)
{
    for (uint32_t off = 0u; off < len; off += QSPI_FLASH_CHUNK_SIZE) {
        uint32_t rem = len - off;
        uint8_t  n   = (rem >= QSPI_FLASH_CHUNK_SIZE) ? (uint8_t)QSPI_FLASH_CHUNK_SIZE
                                                      : (uint8_t)rem;
        uint32_t got[4];
        qspi_flash_cmd_read_addr(QSPI_FLASH_CMD_READ_OP, addr + off, n, got);
        const uint8_t *gb = (const uint8_t *)got;
        for (uint8_t i = 0; i < n; ++i)
            if (gb[i] != expected[off + i]) return (int)(off + i) + 1;
    }
    return 0;
}

/* Erase the smallest whole number of 64 KB sectors covering [0, len). */
static inline void qspi_flash_erase_range(uint32_t base, uint32_t len)
{
    uint32_t n_sectors = (len + QSPI_FLASH_SECTOR_SIZE - 1u) / QSPI_FLASH_SECTOR_SIZE;
    for (uint32_t s = 0u; s < n_sectors; ++s)
        qspi_flash_sector_erase(base + s * QSPI_FLASH_SECTOR_SIZE);
}

#endif /* NANOSOC_QSPI_FLASH_H */
