/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - CRC-32/IEEE helper
 *
 * Nibble-at-a-time (16-entry table) implementation of CRC-32/IEEE 802.3
 * (polynomial 0xEDB88320, reflected, init/xor 0xFFFFFFFF). Matches
 * Python's `binascii.crc32`, which is what flash_pack.py uses when it
 * populates the BOOT-table entries. Stage-0 bootroms use this to
 * verify the DMA-copied image before branching into it.
 *
 * Size footprint: 64 B table + ~50 B code. Small enough to live inside
 * the 2 KB stage-0 bootrom budget.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef NANOSOC_CRC32_H
#define NANOSOC_CRC32_H

#include <stdint.h>
#include <stddef.h>

/* 16-entry nibble table for the reflected IEEE 802.3 polynomial. */
static const uint32_t nanosoc_crc32_tab[16] = {
    0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu,
    0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
    0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu,
    0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu,
};

static uint32_t nanosoc_crc32(const void *data, uint32_t n_bytes)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFFu;
    while (n_bytes--) {
        uint8_t b = *p++;
        crc ^= (uint32_t)b;
        crc = (crc >> 4) ^ nanosoc_crc32_tab[crc & 0xFu];
        crc = (crc >> 4) ^ nanosoc_crc32_tab[crc & 0xFu];
    }
    return ~crc;
}

#endif /* NANOSOC_CRC32_H */
