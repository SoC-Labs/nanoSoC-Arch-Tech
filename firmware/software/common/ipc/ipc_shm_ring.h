/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - IPC shared-memory SPSC rings (data plane)
 *
 * The IPC mailbox (2 slots x 4 words, ~71-cycle round trip) is a control
 * plane / doorbell, not a pipe. This header is the normative layout + ops for
 * the shared-memory data plane between CPU0 (eth_ss, network processor) and
 * CPU1 (chip-control, application core) — see docs/IPC_DATA_PLANE_PLAN.md.
 *
 * One ipc_shm_t holds two single-producer/single-consumer rings:
 *
 *   n2a  net -> app   CPU0 produces, CPU1 consumes
 *   a2n  app -> net   CPU1 produces, CPU0 consumes
 *
 * The whole structure lives in the dedicated top-level SHARED SRAM
 * (NANOSOC_SHARED_SRAM_BASE = 0x2D000000) — the only RAM both CPU cores can
 * reach at a COMMON address. (Each core's local DMEM at 0x18000000 is
 * PRIVATE: CPU1's subsystem matrix shadows 0x00-0x1FFFFFFF with its own
 * memories, and CPU0 has no path into CPU1, so a ring in either DMEM is
 * invisible to the other core.) The owner (CPU0) hands the base address to
 * CPU1 once over the mailbox (IPC_RPC_OP_RING_ATTACH); after that the mailbox
 * is only needed for doorbells/control, never payload.
 *
 * SPSC means no locks: each ring index has exactly one writer. head counts
 * descriptors ever produced, tail descriptors ever consumed (free-running
 * uint32, slot = idx & (DESCS-1)); empty <=> head == tail, full <=>
 * head - tail == DESCS. The mailbox LOCK register is not used.
 *
 * MEMORY-ACCESS RULES (hard requirements, not style):
 *  - Every access to the shared structure is a 32-bit word access. CPU1
 *    byte/halfword reads of remote memory over the matrix are unreliable
 *    (the M0+ back-to-back sub-word issue behind the LDRB string corruption,
 *    docs/IPC_MATRIX_FIX.md notes). The copy helpers below assemble/scatter
 *    bytes only on the caller's core-LOCAL buffer.
 *  - Each control word has exactly one writer core. Producer-owned and
 *    consumer-owned words sit in separate 32-byte groups on principle.
 *  - Payload + descriptor are written before the head update that publishes
 *    them; a DMB sits between (in-order M0+ cores over AHB make this nearly
 *    free, and it keeps the code honest).
 *
 * Pure layout + ops: no address-map includes, no statics. The same file
 * compiles for ARM targets and for the native host unit test
 * (firmware/tests/host/).
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef IPC_SHM_RING_H
#define IPC_SHM_RING_H

#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Geometry (v1 smoke/bring-up sizing; both sides must agree — the attach
 * handshake checks magic+geometry words, so a mismatch fails loudly).
 * DESCS must be a power of two.
 * ------------------------------------------------------------------------ */
#ifndef IPC_SHM_DESCS
#define IPC_SHM_DESCS      8u
#endif
#ifndef IPC_SHM_BUF_SIZE
#define IPC_SHM_BUF_SIZE   256u    /* bytes per payload slot, multiple of 4 */
#endif

#define IPC_SHM_MAGIC      0x4E535231u   /* 'N','S','R','1' */
#define IPC_SHM_VERSION    1u

/* Descriptor flags [15:0]; [31:16] free for a sock_id when libipc_sock
 * lands. v1 smoke uses ECHO only. */
#define IPC_SHM_F_ECHO     (1u << 0)
#define IPC_SHM_F_DMA      (1u << 1)    /* payload moved out-of-band (bulk) */

/* ---------------------------------------------------------------------------
 * Layout — everything volatile uint32_t so every generated access is a
 * 32-bit load/store on both cores.
 * ------------------------------------------------------------------------ */
typedef struct {
    volatile uint32_t len;        /* payload bytes (0..IPC_SHM_BUF_SIZE)     */
    volatile uint32_t flags;      /* [15:0] IPC_SHM_F_*, [31:16] sock_id     */
    volatile uint32_t seq;        /* producer sequence (drop/dup detection)  */
    volatile uint32_t rsvd;       /* future: external buffer addr (DMA path) */
} ipc_shm_desc_t;

typedef struct {
    volatile uint32_t head;       /* producer-owned: descriptors produced    */
    volatile uint32_t _pad0[7];   /* keep the consumer's word group apart    */
    volatile uint32_t tail;       /* consumer-owned: descriptors consumed    */
    volatile uint32_t _pad1[7];
    ipc_shm_desc_t    desc[IPC_SHM_DESCS];
    volatile uint32_t buf[IPC_SHM_DESCS][IPC_SHM_BUF_SIZE / 4u];
} ipc_shm_ring_t;

typedef struct {
    volatile uint32_t magic;      /* IPC_SHM_MAGIC once initialised          */
    volatile uint32_t version;
    volatile uint32_t desc_count; /* geometry echo — attach() cross-checks   */
    volatile uint32_t buf_size;
    /* Owner-maintained stats, one writer each (CPU0: [0..3], CPU1: [4..7]).
     * [0] n2a produced  [1] n2a full-stalls  [4] a2n produced  [5] a2n
     * full-stalls; rest reserved. Telemetry only — never load-bearing. */
    volatile uint32_t stats[8];
    ipc_shm_ring_t    n2a;        /* CPU0 -> CPU1 */
    ipc_shm_ring_t    a2n;        /* CPU1 -> CPU0 */
} ipc_shm_t;

#define IPC_SHM_STAT_N2A_MSGS    0u
#define IPC_SHM_STAT_N2A_STALLS  1u
#define IPC_SHM_STAT_A2N_MSGS    4u
#define IPC_SHM_STAT_A2N_STALLS  5u

/* ---------------------------------------------------------------------------
 * Barrier — DMB on ARM (ARMv6-M has it), compiler barrier on the host.
 * ------------------------------------------------------------------------ */
static inline void ipc_shm_dmb(void)
{
#if defined(__arm__) || defined(__thumb__)
    __asm volatile ("dmb" ::: "memory");
#else
    __asm volatile ("" ::: "memory");
#endif
}

/* ---------------------------------------------------------------------------
 * Init / attach
 * ------------------------------------------------------------------------ */
static inline void ipc_shm_init(ipc_shm_t *shm)
{
    uint32_t i;
    shm->magic = 0u;              /* not valid while we scrub */
    shm->n2a.head = 0u; shm->n2a.tail = 0u;
    shm->a2n.head = 0u; shm->a2n.tail = 0u;
    for (i = 0u; i < 8u; i++) shm->stats[i] = 0u;
    shm->version    = IPC_SHM_VERSION;
    shm->desc_count = IPC_SHM_DESCS;
    shm->buf_size   = IPC_SHM_BUF_SIZE;
    ipc_shm_dmb();
    shm->magic = IPC_SHM_MAGIC;   /* publish last */
}

/* Returns 0 on success, negative on magic/geometry mismatch. */
static inline int ipc_shm_attach(const ipc_shm_t *shm)
{
    if (shm->magic      != IPC_SHM_MAGIC)   return -1;
    if (shm->version    != IPC_SHM_VERSION) return -2;
    if (shm->desc_count != IPC_SHM_DESCS)   return -3;
    if (shm->buf_size   != IPC_SHM_BUF_SIZE) return -4;
    return 0;
}

/* ---------------------------------------------------------------------------
 * Ring state
 * ------------------------------------------------------------------------ */
static inline uint32_t ipc_shm_ring_pending(const ipc_shm_ring_t *r)
{
    return r->head - r->tail;                 /* mod-2^32 arithmetic is exact */
}
static inline uint32_t ipc_shm_ring_space(const ipc_shm_ring_t *r)
{
    return IPC_SHM_DESCS - ipc_shm_ring_pending(r);
}

/* ---------------------------------------------------------------------------
 * Word-safe payload copies.
 *
 * send: assemble each word from the LOCAL src bytes, store whole words to
 *       the shared slot buffer.
 * recv: load whole words from the shared slot buffer, scatter bytes into
 *       the LOCAL dst.
 * Neither direction ever issues a sub-word access on shared memory.
 * ------------------------------------------------------------------------ */
static inline void ipc_shm_copy_in(volatile uint32_t *dst_words,
                                   const uint8_t *src, uint32_t len)
{
    uint32_t i, w, b;
    for (i = 0u; i < len / 4u; i++) {
        w  = (uint32_t)src[i * 4u + 0u];
        w |= (uint32_t)src[i * 4u + 1u] << 8;
        w |= (uint32_t)src[i * 4u + 2u] << 16;
        w |= (uint32_t)src[i * 4u + 3u] << 24;
        dst_words[i] = w;
    }
    if (len & 3u) {
        w = 0u;
        for (b = 0u; b < (len & 3u); b++)
            w |= (uint32_t)src[(len & ~3u) + b] << (8u * b);
        dst_words[len / 4u] = w;
    }
}

static inline void ipc_shm_copy_out(uint8_t *dst,
                                    const volatile uint32_t *src_words,
                                    uint32_t len)
{
    uint32_t i, w, b;
    for (i = 0u; i < len / 4u; i++) {
        w = src_words[i];
        dst[i * 4u + 0u] = (uint8_t)(w);
        dst[i * 4u + 1u] = (uint8_t)(w >> 8);
        dst[i * 4u + 2u] = (uint8_t)(w >> 16);
        dst[i * 4u + 3u] = (uint8_t)(w >> 24);
    }
    if (len & 3u) {
        w = src_words[len / 4u];
        for (b = 0u; b < (len & 3u); b++)
            dst[(len & ~3u) + b] = (uint8_t)(w >> (8u * b));
    }
}

/* ---------------------------------------------------------------------------
 * Produce / consume. Non-blocking: return 0 when full/empty so the caller
 * owns the wait policy (poll, WFE, or drop-and-count). Returns 1 on success.
 * ------------------------------------------------------------------------ */
static inline int ipc_shm_send(ipc_shm_ring_t *r, const uint8_t *payload,
                               uint32_t len, uint32_t flags, uint32_t seq)
{
    uint32_t slot;
    if (len > IPC_SHM_BUF_SIZE)        return 0;
    if (ipc_shm_ring_space(r) == 0u)   return 0;

    slot = r->head & (IPC_SHM_DESCS - 1u);
    if (len != 0u)
        ipc_shm_copy_in(r->buf[slot], payload, len);
    r->desc[slot].len   = len;
    r->desc[slot].flags = flags;
    r->desc[slot].seq   = seq;

    ipc_shm_dmb();                     /* payload+desc before publication */
    r->head = r->head + 1u;
    return 1;
}

static inline int ipc_shm_recv(ipc_shm_ring_t *r, uint8_t *payload,
                               uint32_t max_len, uint32_t *len,
                               uint32_t *flags, uint32_t *seq)
{
    uint32_t slot, n;
    if (ipc_shm_ring_pending(r) == 0u) return 0;

    ipc_shm_dmb();                     /* observe payload no older than head */
    slot = r->tail & (IPC_SHM_DESCS - 1u);
    n = r->desc[slot].len;
    if (n > IPC_SHM_BUF_SIZE) n = IPC_SHM_BUF_SIZE;   /* defensive clamp */
    if (n > max_len)          n = max_len;
    if (n != 0u)
        ipc_shm_copy_out(payload, r->buf[slot], n);
    if (len)   *len   = n;
    if (flags) *flags = r->desc[slot].flags;
    if (seq)   *seq   = r->desc[slot].seq;

    ipc_shm_dmb();                     /* drain slot before releasing it */
    r->tail = r->tail + 1u;
    return 1;
}

#endif /* IPC_SHM_RING_H */
