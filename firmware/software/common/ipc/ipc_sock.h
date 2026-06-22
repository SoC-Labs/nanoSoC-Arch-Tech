/*
 *-----------------------------------------------------------------------------
 * nanosoc-multicore-system - libipc_sock: socket-style API over the SPSC rings
 *
 * Phase 2/3 of the IPC data plane (docs/IPC_DATA_PLANE_PLAN.md §3.3). Gives
 * application code a small socket-style interface — open / send / recv / poll /
 * close — multiplexed over the single shared-memory SPSC ring pair from
 * ipc_shm_ring.h. Each logical socket is identified by a 16-bit sock_id carried
 * in the descriptor's flags[31:16] field (reserved there for exactly this).
 *
 *   CPU1 (app core)     : rx_ring = n2a (net->app), tx_ring = a2n (app->net)
 *   CPU0 (network core) : rx_ring = a2n (app->net), tx_ring = n2a (net->app)
 *
 * The library is endpoint-symmetric: ipc_sock_init() takes the (tx, rx) ring
 * pair, so the same code runs on either core — only the ring assignment differs.
 *
 * MULTIPLEXING. One SPSC ring carries traffic for every socket, FIFO-ordered.
 * Because an SPSC ring cannot be consumed out of order, recv() cannot "skip" a
 * head descriptor addressed to another socket. So the consumer DRAINS the whole
 * rx ring in one pump() pass, copying each message into the destination
 * socket's small endpoint-LOCAL rx queue keyed by sock_id; recv()/poll() then
 * work against that local queue. A message whose sock_id has no open socket is
 * counted (ctx->unmatched) and dropped — never silently lost.
 *
 * MEMORY-ACCESS RULES (inherited from ipc_shm_ring.h). The shared ring lives in
 * the cross-core shared SRAM (0x2C000000); every access to it goes through the
 * 32-bit word-safe ipc_shm_send/recv helpers. The per-socket rx queues live in
 * this endpoint's LOCAL memory, so byte-level access to them is fine.
 *
 * Pure layout + ops, no statics, no address-map includes: the same header
 * compiles for the ARM targets and for the native host unit test
 * (firmware/tests/host/test_ipc_sock.c).
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 *-----------------------------------------------------------------------------
 */
#ifndef IPC_SOCK_H
#define IPC_SOCK_H

#include <stdint.h>
#include "ipc_shm_ring.h"

/* ---------------------------------------------------------------------------
 * Geometry (both endpoints must agree on IPC_SOCK_MSG_MAX <= IPC_SHM_BUF_SIZE;
 * IPC_SOCK_MAX / IPC_SOCK_RXQ_DEPTH are per-endpoint and need not match).
 * ------------------------------------------------------------------------ */
#ifndef IPC_SOCK_MAX
#define IPC_SOCK_MAX        8u     /* max concurrent sockets per endpoint     */
#endif
#ifndef IPC_SOCK_RXQ_DEPTH
#define IPC_SOCK_RXQ_DEPTH  2u     /* per-socket buffered rx messages (pow2)  */
#endif
#ifndef IPC_SOCK_MSG_MAX
#define IPC_SOCK_MSG_MAX    IPC_SHM_BUF_SIZE  /* max payload bytes per message */
#endif

#define IPC_SOCK_ID_NONE    0xFFFFu /* not a valid sock_id (16-bit field)     */

/* Protocol hints (carried in the open table; opaque to the ring transport). */
#define IPC_SOCK_PROTO_NONE 0u
#define IPC_SOCK_PROTO_UDP  1u
#define IPC_SOCK_PROTO_TCP  2u

/* Return codes for open/init. */
#define IPC_SOCK_OK         0
#define IPC_SOCK_ERR_FULL  (-1)    /* no free socket slot                     */
#define IPC_SOCK_ERR_DUP   (-2)    /* sock_id already open                    */
#define IPC_SOCK_ERR_ARG   (-3)    /* bad argument                            */

/* ---------------------------------------------------------------------------
 * Per-socket state. The rx queue is a tiny SPSC ring of fixed-size slots in
 * this endpoint's local memory; pump() is the sole producer, recv() the sole
 * consumer, so no locking is needed here either.
 * ------------------------------------------------------------------------ */
typedef struct {
    uint8_t  len_div;                       /* unused pad / future            */
    uint8_t  in_use;
    uint16_t sock_id;
    uint16_t port;
    uint8_t  proto;
    uint8_t  _pad;
    uint32_t tx_seq;                        /* outgoing per-socket sequence   */
    uint32_t rx_drops;                      /* messages dropped: rxq full     */
    uint32_t rxq_head, rxq_tail;            /* local rx queue indices         */
    struct {
        uint32_t len;
        uint32_t flags;                     /* descriptor flags[15:0]         */
        uint32_t seq;
        uint8_t  data[IPC_SOCK_MSG_MAX];
    } rxq[IPC_SOCK_RXQ_DEPTH];
} ipc_sock_t;

/* ---------------------------------------------------------------------------
 * Endpoint context. Bind tx/rx rings once via ipc_sock_init(); after that all
 * calls are against this ctx. Lives in endpoint-local memory.
 * ------------------------------------------------------------------------ */
typedef struct {
    ipc_shm_ring_t *tx_ring;                /* this endpoint produces here     */
    ipc_shm_ring_t *rx_ring;                /* this endpoint consumes here     */
    ipc_sock_t      socks[IPC_SOCK_MAX];
    uint32_t        unmatched;              /* rx msgs with no open socket     */
    uint32_t        rx_total;               /* rx msgs pumped (all sockets)    */
    uint32_t        tx_total;               /* tx msgs sent (all sockets)      */
    uint32_t        tx_stalls;              /* send failures: tx ring full     */
} ipc_sock_ctx_t;

/* ---------------------------------------------------------------------------
 * Init
 * ------------------------------------------------------------------------ */
static inline void ipc_sock_init(ipc_sock_ctx_t *ctx,
                                 ipc_shm_ring_t *tx_ring,
                                 ipc_shm_ring_t *rx_ring)
{
    uint32_t i;
    ctx->tx_ring   = tx_ring;
    ctx->rx_ring   = rx_ring;
    ctx->unmatched = 0u;
    ctx->rx_total  = 0u;
    ctx->tx_total  = 0u;
    ctx->tx_stalls = 0u;
    for (i = 0u; i < IPC_SOCK_MAX; i++) {
        ctx->socks[i].in_use   = 0u;
        ctx->socks[i].sock_id  = IPC_SOCK_ID_NONE;
        ctx->socks[i].rxq_head = 0u;
        ctx->socks[i].rxq_tail = 0u;
        ctx->socks[i].tx_seq   = 0u;
        ctx->socks[i].rx_drops = 0u;
    }
}

/* Convenience for the two cores. CPU1 (app): tx=a2n, rx=n2a. */
static inline void ipc_sock_init_app(ipc_sock_ctx_t *ctx, ipc_shm_t *shm)
{
    ipc_sock_init(ctx, &shm->a2n, &shm->n2a);
}
/* CPU0 (network): tx=n2a, rx=a2n. */
static inline void ipc_sock_init_net(ipc_sock_ctx_t *ctx, ipc_shm_t *shm)
{
    ipc_sock_init(ctx, &shm->n2a, &shm->a2n);
}

/* ---------------------------------------------------------------------------
 * Socket table
 * ------------------------------------------------------------------------ */
static inline ipc_sock_t *ipc_sock_find(ipc_sock_ctx_t *ctx, uint16_t sock_id)
{
    uint32_t i;
    for (i = 0u; i < IPC_SOCK_MAX; i++)
        if (ctx->socks[i].in_use && ctx->socks[i].sock_id == sock_id)
            return &ctx->socks[i];
    return (ipc_sock_t *)0;
}

/* Bind a specific sock_id (both endpoints must agree on the id). The id is the
 * wire identifier carried in flags[31:16], so it must fit 16 bits and not be
 * IPC_SOCK_ID_NONE. Returns IPC_SOCK_OK or a negative IPC_SOCK_ERR_*. */
static inline int ipc_sock_open(ipc_sock_ctx_t *ctx, uint16_t sock_id,
                                uint8_t proto, uint16_t port)
{
    uint32_t i;
    if (sock_id == IPC_SOCK_ID_NONE)        return IPC_SOCK_ERR_ARG;
    if (ipc_sock_find(ctx, sock_id))        return IPC_SOCK_ERR_DUP;
    for (i = 0u; i < IPC_SOCK_MAX; i++) {
        if (!ctx->socks[i].in_use) {
            ipc_sock_t *s = &ctx->socks[i];
            s->in_use   = 1u;
            s->sock_id  = sock_id;
            s->proto    = proto;
            s->port     = port;
            s->tx_seq   = 0u;
            s->rx_drops = 0u;
            s->rxq_head = 0u;
            s->rxq_tail = 0u;
            return IPC_SOCK_OK;
        }
    }
    return IPC_SOCK_ERR_FULL;
}

/* Auto-allocate the next free sock_id in [base, base+IPC_SOCK_MAX). Useful on
 * the side that owns id allocation; returns the id or IPC_SOCK_ID_NONE. The
 * peer learns the id out-of-band (e.g. the open RPC / first message). */
static inline uint16_t ipc_sock_open_auto(ipc_sock_ctx_t *ctx, uint16_t base,
                                          uint8_t proto, uint16_t port)
{
    uint16_t id;
    for (id = base; id < (uint16_t)(base + IPC_SOCK_MAX); id++) {
        if (id == IPC_SOCK_ID_NONE) continue;
        if (!ipc_sock_find(ctx, id)) {
            if (ipc_sock_open(ctx, id, proto, port) == IPC_SOCK_OK)
                return id;
        }
    }
    return IPC_SOCK_ID_NONE;
}

static inline int ipc_sock_close(ipc_sock_ctx_t *ctx, uint16_t sock_id)
{
    ipc_sock_t *s = ipc_sock_find(ctx, sock_id);
    if (!s) return IPC_SOCK_ERR_ARG;
    s->in_use  = 0u;
    s->sock_id = IPC_SOCK_ID_NONE;
    return IPC_SOCK_OK;
}

/* ---------------------------------------------------------------------------
 * Send: tag the descriptor with the socket's id (flags[31:16]) and push to the
 * tx ring. Non-blocking — returns 1 on success, 0 if the ring is full (caller
 * owns the wait/drop policy; the stall is counted).
 * ------------------------------------------------------------------------ */
static inline int ipc_sock_send(ipc_sock_ctx_t *ctx, uint16_t sock_id,
                                const uint8_t *buf, uint32_t len, uint16_t flags)
{
    ipc_sock_t *s = ipc_sock_find(ctx, sock_id);
    uint32_t    wire_flags;
    if (!s)                         return 0;
    /* Bug A3 fix: reject oversize messages at SEND against the per-message cap
     * (IPC_SOCK_MSG_MAX, the rx-queue slot size) rather than the larger ring
     * buffer size. Previously the gate used IPC_SHM_BUF_SIZE, so a payload in
     * (IPC_SOCK_MSG_MAX, IPC_SHM_BUF_SIZE] passed here and was then SILENTLY
     * truncated to IPC_SOCK_MSG_MAX by the receive pump. Now the caller gets a
     * clean failure (return 0) it can see + retry/chunk, and it is counted. */
    if (len > IPC_SOCK_MSG_MAX)  { ctx->tx_stalls++; return 0; }
    wire_flags = ((uint32_t)sock_id << 16) | (uint32_t)flags;
    if (!ipc_shm_send(ctx->tx_ring, buf, len, wire_flags, s->tx_seq)) {
        ctx->tx_stalls++;
        return 0;
    }
    s->tx_seq++;
    ctx->tx_total++;
    return 1;
}

/* ---------------------------------------------------------------------------
 * Pump: drain the rx ring, dispatching each message to its socket's local rx
 * queue by sock_id. Returns the number of messages consumed from the ring.
 * Messages for an unknown/closed socket, or for a socket whose local queue is
 * full, are dropped and counted (ctx->unmatched / socket rx_drops). Always
 * fully drains so the shared ring can't back up on one slow socket.
 * ------------------------------------------------------------------------ */
static inline uint32_t ipc_sock_pump(ipc_sock_ctx_t *ctx)
{
    uint32_t consumed = 0u;
    uint8_t  tmp[IPC_SHM_BUF_SIZE];
    uint32_t len, flags, seq;

    while (ipc_shm_recv(ctx->rx_ring, tmp, sizeof(tmp), &len, &flags, &seq)) {
        uint16_t    sid = (uint16_t)(flags >> 16);
        ipc_sock_t *s   = ipc_sock_find(ctx, sid);
        consumed++;
        ctx->rx_total++;
        if (!s) { ctx->unmatched++; continue; }

        if ((s->rxq_head - s->rxq_tail) >= IPC_SOCK_RXQ_DEPTH) {
            s->rx_drops++;                      /* local queue full -> drop    */
            continue;
        }
        {
            uint32_t slot = s->rxq_head & (IPC_SOCK_RXQ_DEPTH - 1u);
            uint32_t n    = (len > IPC_SOCK_MSG_MAX) ? IPC_SOCK_MSG_MAX : len;
            uint32_t b;
            s->rxq[slot].len   = n;
            s->rxq[slot].flags = flags & 0xFFFFu;
            s->rxq[slot].seq   = seq;
            for (b = 0u; b < n; b++) s->rxq[slot].data[b] = tmp[b];
            s->rxq_head++;
        }
    }
    return consumed;
}

/* Pending buffered messages for a socket (call ipc_sock_pump() first to refill
 * from the ring; ipc_sock_recv() does that for you). */
static inline uint32_t ipc_sock_pending(const ipc_sock_ctx_t *ctx,
                                        uint16_t sock_id)
{
    const ipc_sock_t *s = ipc_sock_find((ipc_sock_ctx_t *)ctx, sock_id);
    return s ? (s->rxq_head - s->rxq_tail) : 0u;
}

/* ---------------------------------------------------------------------------
 * Recv: pump the ring, then dequeue one buffered message for this socket.
 * Returns 1 on a message (payload copied to buf; len, flags, seq out-params set
 * if non-NULL), 0 if none available. Non-blocking — caller owns the wait policy.
 * ------------------------------------------------------------------------ */
static inline int ipc_sock_recv(ipc_sock_ctx_t *ctx, uint16_t sock_id,
                                uint8_t *buf, uint32_t max_len,
                                uint32_t *len, uint32_t *flags, uint32_t *seq)
{
    ipc_sock_t *s;
    uint32_t slot, n, b;

    (void)ipc_sock_pump(ctx);                 /* refill local queues          */

    s = ipc_sock_find(ctx, sock_id);
    if (!s)                              return 0;
    if (s->rxq_head == s->rxq_tail)      return 0;   /* empty                  */

    slot = s->rxq_tail & (IPC_SOCK_RXQ_DEPTH - 1u);
    n    = s->rxq[slot].len;
    if (n > max_len) n = max_len;
    for (b = 0u; b < n; b++) buf[b] = s->rxq[slot].data[b];
    /* Bug #4 (round 5): report the bytes ACTUALLY copied into buf (n), not the
     * stored length — else a caller that sized its buffer by *len over-reads the
     * truncated tail (matches the sibling ipc_shm_recv contract). */
    if (len)   *len   = n;
    if (flags) *flags = s->rxq[slot].flags;
    if (seq)   *seq   = s->rxq[slot].seq;
    s->rxq_tail++;
    return 1;
}

/* ---------------------------------------------------------------------------
 * Poll: pump then return a bitmask of sockets (by table index) with pending
 * rx, plus tx-ring writability. Cheap status inspection, no extra IPC.
 * ------------------------------------------------------------------------ */
#define IPC_SOCK_POLL_TX_OK   (1u << 31)   /* tx ring has space               */

static inline uint32_t ipc_sock_poll(ipc_sock_ctx_t *ctx)
{
    uint32_t mask = 0u, i;
    (void)ipc_sock_pump(ctx);
    for (i = 0u; i < IPC_SOCK_MAX; i++) {
        ipc_sock_t *s = &ctx->socks[i];
        if (s->in_use && (s->rxq_head != s->rxq_tail))
            mask |= (1u << i);
    }
    if (ipc_shm_ring_space(ctx->tx_ring) > 0u)
        mask |= IPC_SOCK_POLL_TX_OK;
    return mask;
}

#endif /* IPC_SOCK_H */
