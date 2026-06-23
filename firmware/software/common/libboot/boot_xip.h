/*----------------------------------------------------------------------------
 * boot_xip — generic QSPI XiP + manager handshake helpers for staged boot.
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * Reusable across nanosoc systems (lives in arch_tech). Addresses are passed in
 * by the system (e.g. compute_mem.h) so this stays board-agnostic.
 */
#ifndef BOOT_XIP_H
#define BOOT_XIP_H

#include <stdint.h>

/* XiP cache control register (ahb_qspi CG092): bit0 = enable. */
#define BOOT_XIP_CCR_EN  (1u << 0)

/* Poll *addr until it equals `expect`. `spins`==0 -> wait forever.
 * Returns 0 on match, -1 on timeout. Used for the manager's XiP-WARM flag
 * (manager posts e.g. 0xD15C0001 to an IPC slot before releasing the core). */
int  boot_wait_flag(volatile uint32_t *addr, uint32_t expect, uint32_t spins);

/* Enable the QSPI XiP cache (write CCR.EN at the given control base). */
void boot_xip_cache_enable(uintptr_t ccr_base);

/* Dummy read of the XiP aperture to prime the cache and avoid the first-access
 * cache-ready race (HardFault) seen on silicon before the cache is warm. */
uint32_t boot_xip_warmup(uintptr_t xip_base);

#endif /* BOOT_XIP_H */
