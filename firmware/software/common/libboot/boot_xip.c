/*----------------------------------------------------------------------------
 * boot_xip — generic QSPI XiP + handshake helpers (implementation)
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------*/
#include "boot_xip.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

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
