/*----------------------------------------------------------------------------
 * libboot — shared staged-boot primitives for the M0+/M4 compute system
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * One boot-table format + verify + hand-off, shared by every core/stage
 * (BootROM, SPL, ... ). See compute-subsystem/docs/BOOT_ARCHITECTURE.md and
 * docs/BOOT_ALIGNMENT_M0PLUS_M4.md. v1 = CRC32 integrity; v2 adds signatures.
 */
#ifndef LIBBOOT_H
#define LIBBOOT_H

#include <stdint.h>
#include <stddef.h>

#define BOOT_MAGIC    0x544F4F42u   /* 'B','O','O','T' little-endian */
#define BOOT_VERSION  1u
#define BOOT_MAX_STAGES 8u
#define BOOT_SIG_BYTES 64u          /* reserved for v2 signatures */

/* One staged image descriptor in the flash boot table. */
typedef struct {
    uint32_t off;        /* image byte offset from flash base                */
    uint32_t size;       /* image size in bytes                              */
    uint32_t load_addr;  /* where to place it (e.g. IMEM); 0 = run in place  */
    uint32_t entry_vtor; /* vector-table base to hand off to (VTOR)          */
    uint32_t crc32;      /* zlib/CRC-32 of the image bytes                   */
    uint8_t  sig[BOOT_SIG_BYTES];   /* v2: signature (zero in v1)            */
} boot_entry_t;

typedef struct {
    uint32_t magic;      /* BOOT_MAGIC                                       */
    uint32_t version;    /* BOOT_VERSION                                     */
    uint32_t n_stages;   /* number of valid boot_entry_t that follow        */
    uint32_t reserved;
    boot_entry_t entry[BOOT_MAX_STAGES];
} boot_table_t;

typedef enum {
    BOOT_OK = 0,
    BOOT_E_MAGIC = -1,
    BOOT_E_VERSION = -2,
    BOOT_E_RANGE = -3,
    BOOT_E_CRC = -4,
} boot_status_t;

/* zlib-compatible CRC-32 (reflected, poly 0xEDB88320) — matches the
 * binascii.crc32 used by flash_pack.py. */
uint32_t boot_crc32(const void *data, size_t len);

/* Validate the table header + return the requested stage's descriptor. */
boot_status_t boot_table_get(const boot_table_t *t, uint32_t stage,
                             boot_entry_t *out);

/* Copy an image to its load address (CPU memcpy; DMA-250 path is a TODO hook).
 * No-op when load_addr == 0 (run-in-place). */
void boot_copy(const void *flash_base, const boot_entry_t *e);

/* CRC-verify an image at its resident location. */
boot_status_t boot_verify(const void *flash_base, const boot_entry_t *e);

/* Set VTOR to vtor, load MSP from vtor[0], branch to vtor[1]. Never returns. */
void boot_handoff(uint32_t vtor) __attribute__((noreturn));

#endif /* LIBBOOT_H */
