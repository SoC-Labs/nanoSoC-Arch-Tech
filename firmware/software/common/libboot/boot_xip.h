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

/* Copy `size` bytes from QSPI flash offset `flash_off` to `dst` using direct
 * controller FAST_READ commands (one self-contained command per word via
 * SPI_CMD/SPI_ADDR/RDATA0), bypassing the memory-mapped XiP read aperture.
 *
 * WHY: on this SoC the CG092/XiP multi-line cache read corrupts large transfers
 * — a single word (e.g. the boot-table magic at flash off 0) reads fine, but a
 * multi-KB image copy through the 0x24000000 aperture comes back corrupted, so
 * the staged image fails its CRC and never runs. Each direct FAST_READ is an
 * independent controller transaction (the same path the host flasher's `fread`
 * uses, proven reliable), so this reads correctly. Clears CTRL.XIP_ACTIVE for
 * direct access and leaves it cleared (a RAM-exec OS does not need the aperture).
 *
 * qspi_base = ahb_qspi APB block (CTRL@0 / STATUS@4 / SPI_CMD@8 / SPI_ADDR@C /
 * RDATA0 @10). `size` is rounded up to a word on read; dst needs room for the
 * rounded size (the extra <4 bytes lie outside the image CRC). */
void boot_copy_qspi_direct(uintptr_t qspi_base, uint32_t flash_off,
                           uintptr_t dst, uint32_t size);

/* CRC-32/IEEE 802.3 over [addr, addr+size) using 32-bit reads ONLY (no byte
 * accesses). Use to verify an image copied into a RAM that faults on byte reads
 * but serves word reads (IMEM on this SoC). Bit-exact with nanosoc_crc32 /
 * binascii.crc32 for word-multiple sizes. `size` must be a multiple of 4. */
uint32_t boot_crc32_words(uintptr_t addr, uint32_t size);

#endif /* BOOT_XIP_H */
