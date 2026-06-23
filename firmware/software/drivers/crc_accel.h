/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - CRC-32/IEEE accelerator driver (eth_crc_checker)
 *
 * Thin driver for the u_crc_checker_0 AHB register block in the ethernet
 * subsystem (CPU0 local map @ 0x48000000, see
 * ethernet-subsystem-ahb/sys_desc/ethernet_ss_ahb_rmii.yaml). The block
 * computes CRC-32/IEEE 802.3 one bus-word per HCLK cycle and is bit-exact
 * with the nibble-table software reference in include/nanosoc_crc32.h
 * (and Python binascii/zlib.crc32 — the flash_pack.py BOOT-table oracle).
 *
 * crc32_hw() transparently falls back to nanosoc_crc32() when the block
 * is absent (ID-register probe mismatch) or when no base address is known
 * at compile time, so callers can use it unconditionally.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef CRC_ACCEL_H
#define CRC_ACCEL_H

#include <stdint.h>

/* Register offsets (see src/rtl/crc_checker/eth_crc_checker.v) */
#define CRC_ACCEL_ID     0x00u  /* RO: 0x43524301 ("CRC" + version 1)       */
#define CRC_ACCEL_CTRL   0x04u  /* WO: bit0 INIT (seed 0xFFFFFFFF, clr CNT) */
#define CRC_ACCEL_DATA   0x08u  /* WO: CRC input (word/half/byte writes)    */
#define CRC_ACCEL_RESULT 0x0Cu  /* RO: ~CRC (post-inverted per IEEE)        */
#define CRC_ACCEL_COUNT  0x10u  /* RO: DATA-write update cycles since INIT  */

#define CRC_ACCEL_ID_VALUE  0x43524301u
#define CRC_ACCEL_CTRL_INIT (1u << 0)

/* Returns 1 when the accelerator is present (ID probe match), else 0. */
int crc_accel_present(void);

/* CRC-32/IEEE over buf[0..len) — hardware-accelerated when the block is
 * present, nanosoc_crc32() otherwise. Identical result either way. */
uint32_t crc32_hw(const void *buf, uint32_t len);

#endif /* CRC_ACCEL_H */
