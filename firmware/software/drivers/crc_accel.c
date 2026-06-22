/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - CRC-32/IEEE accelerator driver (eth_crc_checker)
 *
 * Word-at-a-time feed with byte head/tail handling:
 *   - unaligned head bytes are fed as single STRB writes to DATA (lane 0);
 *   - the aligned body is fed as 32-bit STR writes (4 bytes / 1 HCLK cycle
 *     in hardware — the block is zero-wait-state);
 *   - the tail (len % 4) is fed as STRB writes.
 * Byte-lane decode in hardware consumes the addressed lanes in ascending
 * (little-endian byte-stream) order, so this reproduces nanosoc_crc32()
 * exactly for any alignment/length.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#include "crc_accel.h"

#include "nanosoc_crc32.h"  /* software fallback (CRC-32/IEEE nibble table) */

#if defined(__has_include)
#  if __has_include("nanosoc_memmap.h")
#    include "nanosoc_memmap.h"  /* NANOSOC_MULTICORE_SOC_CRC_CHECKER_0_BASE */
#  endif
#endif

/* Base address: generated memmap macro (CPU0 / eth_ss local view), with a
 * CRC_ACCEL_BASE override hook for non-default integrations. */
#ifndef CRC_ACCEL_BASE
#  ifdef NANOSOC_MULTICORE_SOC_CRC_CHECKER_0_BASE
#    define CRC_ACCEL_BASE NANOSOC_MULTICORE_SOC_CRC_CHECKER_0_BASE
#  endif
#endif

#ifdef CRC_ACCEL_BASE

#define CRC_REG32(off) (*(volatile uint32_t *)(uintptr_t)(CRC_ACCEL_BASE + (off)))
#define CRC_REG8(off)  (*(volatile uint8_t  *)(uintptr_t)(CRC_ACCEL_BASE + (off)))

int crc_accel_present(void)
{
    return CRC_REG32(CRC_ACCEL_ID) == CRC_ACCEL_ID_VALUE;
}

uint32_t crc32_hw(const void *buf, uint32_t len)
{
    const uint8_t *p = (const uint8_t *)buf;

    if (!crc_accel_present())
        return nanosoc_crc32(buf, len);

    CRC_REG32(CRC_ACCEL_CTRL) = CRC_ACCEL_CTRL_INIT;

    /* Head: bytes until the source pointer is word-aligned (Cortex-M0+
     * has no unaligned loads). */
    while (len && ((uintptr_t)p & 0x3u)) {
        CRC_REG8(CRC_ACCEL_DATA) = *p++;
        len--;
    }

    /* Body: one bus word per write (one CRC update cycle each). */
    const uint32_t *w = (const uint32_t *)(const void *)p;
    while (len >= 4u) {
        CRC_REG32(CRC_ACCEL_DATA) = *w++;
        len -= 4u;
    }

    /* Tail: remaining 1..3 bytes. */
    p = (const uint8_t *)(const void *)w;
    while (len--)
        CRC_REG8(CRC_ACCEL_DATA) = *p++;

    return CRC_REG32(CRC_ACCEL_RESULT);
}

#else /* !CRC_ACCEL_BASE — no accelerator in this memory map */

int crc_accel_present(void)
{
    return 0;
}

uint32_t crc32_hw(const void *buf, uint32_t len)
{
    return nanosoc_crc32(buf, len);
}

#endif /* CRC_ACCEL_BASE */
