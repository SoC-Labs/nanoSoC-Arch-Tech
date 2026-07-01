/*----------------------------------------------------------------------------
 * boot_xip — generic QSPI XiP + handshake helpers (implementation)
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------*/
#include "boot_xip.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

uint32_t boot_crc32_words(uintptr_t addr, uint32_t size)
{
    const volatile uint32_t *w = (const volatile uint32_t *)addr;
    uint32_t crc = 0xFFFFFFFFu;
    uint32_t i, j, k;
    /* CRC-32/IEEE 802.3 (reflected, poly 0xEDB88320) over the byte stream, but:
     *  (1) sourced via 32-bit reads ONLY — some on-chip RAMs (IMEM) fault on byte
     *      access yet serve word reads fine, so the byte-wise nanosoc_crc32 can't
     *      run over them; and
     *  (2) TABLE-FREE (bitwise) — a lookup table lands in .rodata at the tail of
     *      the SPL image, which is not reliably reproduced by the stage copy; the
     *      bitwise form depends on nothing but the words it reads.
     * Little-endian: word at addr holds bytes LSB-first, so emit (word>>0,8,16,24).
     * `size` must be a multiple of 4 (mkbootimg 16-aligns every stage). Bit-exact
     * with binascii.crc32 / nanosoc_crc32 for word-multiple sizes. */
    for (i = 0u; i < (size >> 2); i++) {
        uint32_t word = w[i];
        for (j = 0u; j < 4u; j++) {
            crc ^= (word >> (8u * j)) & 0xFFu;
            for (k = 0u; k < 8u; k++) {
                crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1u)));
            }
        }
    }
    return ~crc;
}

int boot_wait_flag(volatile uint32_t *addr, uint32_t expect, uint32_t spins)
{
    if (spins == 0u) {
        while (*addr != expect) { /* wait forever */ }
        return 0;
    }
    for (uint32_t i = 0; i < spins; i++) {
        if (*addr == expect) return 0;
    }
    return -1;
}

void boot_xip_cache_enable(uintptr_t ccr_base)
{
    REG32(ccr_base) |= BOOT_XIP_CCR_EN;
#if defined(__arm__)
    __asm volatile ("dsb" ::: "memory");
    __asm volatile ("isb" ::: "memory");
#endif
}

uint32_t boot_xip_warmup(uintptr_t xip_base)
{
    /* Volatile read primes the cache line; return value forces the load. */
    volatile uint32_t v = REG32(xip_base);
    return v;
}

void boot_copy_qspi_direct(uintptr_t qspi_base, uint32_t flash_off,
                           uintptr_t dst, uint32_t size)
{
    volatile uint32_t *ctrl = (volatile uint32_t *)(uintptr_t)(qspi_base + 0x00u);
    volatile uint32_t *stat = (volatile uint32_t *)(uintptr_t)(qspi_base + 0x04u);
    volatile uint32_t *cmd  = (volatile uint32_t *)(uintptr_t)(qspi_base + 0x08u);
    volatile uint32_t *addr = (volatile uint32_t *)(uintptr_t)(qspi_base + 0x0Cu);
    volatile uint32_t *rd   = (volatile uint32_t *)(uintptr_t)(qspi_base + 0x10u);
    uint32_t *d = (uint32_t *)(uintptr_t)dst;
    uint32_t i;

    /* Direct controller commands need the memory-mapped XiP aperture inactive. */
    *ctrl &= ~(1u << 8);  /* CTRL.XIP_ACTIVE = 0 */

    /* One self-contained FAST_READ per WORD, reading only RDATA0 with a fresh
     * SPI_ADDR each time — this exactly mirrors the host flasher's proven `fread`.
     * (A 4-word burst reading RDATA0..3 latches a per-command result LAG on this
     * controller: command N's RDATA returns command N-1's data, shifting the whole
     * image +16 bytes in the destination and failing the CRC. Reading only RDATA0,
     * one word per command, is the reliable path.) The CG092/XiP multi-line read
     * bug only affects the cached aperture, not these discrete transactions, and
     * RDATA0 already byte-orders to the flash word, so no swap is needed. */
    for (i = 0u; i < size; i += 4u) {
        uint32_t spin;
        *addr = flash_off + i;
        /* FAST_READ(0x0B) | ENABLE(1<<8) | READ(1<<9) | ADDR_EN(1<<11)
         * | 9 dummy cycles (N-1=8 -> 8<<12) | 16 data bytes (N-1=15 -> 15<<16) */
        *cmd = 0x0Bu | (1u << 8) | (1u << 9) | (1u << 11) | (8u << 12) | (15u << 16);
        /* Let STATUS.busy ASSERT before polling it for clear. On the M4's fast
         * native bus the poll can otherwise run in the 1-2 cycle window before
         * the controller raises busy, read busy=0 prematurely, and latch the
         * PREVIOUS command's RDATA — a one-command lag that shifts the whole
         * image by a word. (A debug probe never hits this: its bus accesses are
         * slow enough that busy is long-asserted by the first poll.) The SPI
         * transaction is >100 SCLK, so these few dummy reads can't outrun it. */
        for (spin = 0u; spin < 8u; spin++) { (void)*stat; }
        while ((*stat & 1u) != 0u) { /* wait busy clear */ }
        d[i >> 2] = rd[0];
    }
#if defined(__arm__)
    __asm volatile ("dsb" ::: "memory");
    __asm volatile ("isb" ::: "memory");
#endif
}
