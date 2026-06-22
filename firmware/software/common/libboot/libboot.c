/*----------------------------------------------------------------------------
 * libboot — shared staged-boot primitives (implementation)
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------*/
#include "libboot.h"

#define SCB_VTOR (*(volatile uint32_t *)0xE000ED08u)

uint32_t boot_crc32(const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1u)));
    }
    return ~crc;
}

boot_status_t boot_table_get(const boot_table_t *t, uint32_t stage,
                             boot_entry_t *out)
{
    if (t->magic != BOOT_MAGIC)   return BOOT_E_MAGIC;
    if (t->version != BOOT_VERSION) return BOOT_E_VERSION;
    if (stage >= t->n_stages || stage >= BOOT_MAX_STAGES) return BOOT_E_RANGE;
    *out = t->entry[stage];
    return BOOT_OK;
}

void boot_copy(const void *flash_base, const boot_entry_t *e)
{
    if (e->load_addr == 0u)
        return;  /* run-in-place (e.g. XiP): nothing to copy */
    const uint8_t *src = (const uint8_t *)flash_base + e->off;
    uint8_t *dst = (uint8_t *)(uintptr_t)e->load_addr;
    /* TODO(EDA): replace with the DMA-250 boot-copy path (CPU copy fallback).
     * Word copy where aligned (the shared-SRAM/IMEM word-access rule). */
    size_t n = e->size;
    if ((((uintptr_t)src | (uintptr_t)dst | n) & 3u) == 0u) {
        const uint32_t *s = (const uint32_t *)src;
        uint32_t *d = (uint32_t *)dst;
        for (size_t i = 0; i < (n >> 2); i++) d[i] = s[i];
    } else {
        for (size_t i = 0; i < n; i++) dst[i] = src[i];
    }
}

boot_status_t boot_verify(const void *flash_base, const boot_entry_t *e)
{
    const void *img = (e->load_addr != 0u)
        ? (const void *)(uintptr_t)e->load_addr
        : (const void *)((const uint8_t *)flash_base + e->off);
    /* TODO(v2): signature check over `img` using e->sig + a root key. */
    return (boot_crc32(img, e->size) == e->crc32) ? BOOT_OK : BOOT_E_CRC;
}

void boot_handoff(uint32_t vtor)
{
#if defined(__arm__)
    uint32_t sp = *(volatile uint32_t *)(uintptr_t)vtor;
    uint32_t pc = *(volatile uint32_t *)(uintptr_t)(vtor + 4u);
    SCB_VTOR = vtor;
    __asm volatile ("dsb");
    __asm volatile ("isb");
    __asm volatile ("msr msp, %0" : : "r" (sp) : );
    __asm volatile ("bx  %0"      : : "r" (pc) : );
#else
    (void)vtor;   /* host build (unit tests): hand-off is ARM/MMIO-only */
#endif
    for (;;) { }
}
