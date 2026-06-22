/*----------------------------------------------------------------------------
 * Generic nanosoc ipc_service backend: SPSC ring (shared SRAM) + mailbox kick.
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *----------------------------------------------------------------------------
 * Reusable across nanosoc dual-core systems. Carries ipc_service messages over
 * the shared-SRAM SPSC ring and notifies the peer via the IPC mailbox doorbell,
 * matching the existing firmware ring contract:
 *   - CONFIG_NANOSOC_IPC_RING_DEPTH slots x CONFIG_NANOSOC_IPC_SLOT_BYTES
 *   - WORD-ONLY accesses to shared SRAM (no byte/halfword)
 *   - mailbox IRQ-enable is RMW-guarded (shared register gates both cores)
 *
 * SKELETON: authored to Zephyr's ipc_service backend model. Build in a west
 * workspace on the dev host. `TODO(board)` marks values the system board fills
 * from devicetree (this file stays board-agnostic). The ring layout/ABI is the
 * shared contract from firmware/include/ipc_shm_ring.h.
 *----------------------------------------------------------------------------*/
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/mbox.h>
#include <zephyr/ipc/ipc_service_backend.h>

#define RING_DEPTH  CONFIG_NANOSOC_IPC_RING_DEPTH
#define SLOT_BYTES  CONFIG_NANOSOC_IPC_SLOT_BYTES

/* SPSC ring header in shared SRAM (mirror of ipc_shm_ring.h; word-aligned). */
struct nanosoc_ring {
	volatile uint32_t head;                 /* producer index */
	volatile uint32_t tail;                 /* consumer index */
	volatile uint32_t len[RING_DEPTH];      /* per-slot payload length */
	uint32_t data[RING_DEPTH][SLOT_BYTES / 4];
};

/* One direction pair lives in the shared-memory region (n2a + a2n). */
struct nanosoc_shm {
	struct nanosoc_ring tx;   /* this endpoint -> peer */
	struct nanosoc_ring rx;   /* peer -> this endpoint */
};

struct nanosoc_ipc_data {
	struct nanosoc_shm *shm;          /* TODO(board): from memory-region */
	const struct device *mbox;        /* TODO(board): from mboxes */
	struct mbox_channel tx_ch, rx_ch; /* doorbell channels */
	const struct ipc_ept_cfg *ept;    /* single endpoint (v1) */
};

/* word-safe copy in/out of shared SRAM (byte/halfword unreliable cross-core). */
static void shm_write(volatile uint32_t *dst, const void *src, size_t len)
{
	const uint8_t *s = src;
	for (size_t i = 0; i < (len + 3) / 4; i++) {
		uint32_t w = 0;
		for (int b = 0; b < 4 && (i * 4 + b) < len; b++)
			w |= (uint32_t)s[i * 4 + b] << (8 * b);
		dst[i] = w;
	}
}

static int ring_push(struct nanosoc_ring *r, const void *buf, size_t len)
{
	uint32_t h = r->head, n = (h + 1) % RING_DEPTH;
	if (n == r->tail) return -ENOMEM;          /* full */
	if (len > SLOT_BYTES) return -EMSGSIZE;
	shm_write(r->data[h], buf, len);
	r->len[h] = len;
	__DMB();                                    /* payload before publish */
	r->head = n;
	return 0;
}

/* ---- ipc_service backend ops ------------------------------------------- */
static int backend_send(const struct device *dev, void *token,
			const void *data, size_t len)
{
	struct nanosoc_ipc_data *d = dev->data;
	int ret = ring_push(&d->shm->tx, data, len);
	if (ret) return ret;
	/* kick the peer (mailbox doorbell). TODO(board): RMW IRQ-enable guard. */
	return mbox_send(&d->tx_ch, NULL);
}

static int backend_register_endpoint(const struct device *dev, void **token,
				     const struct ipc_ept_cfg *cfg)
{
	struct nanosoc_ipc_data *d = dev->data;
	d->ept = cfg;                               /* v1: single endpoint */
	*token = (void *)cfg;
	return 0;
}

/* rx doorbell -> drain the rx ring -> deliver to the endpoint. */
static void rx_doorbell(const struct device *mbox, struct mbox_channel *ch,
			void *ctx, struct mbox_msg *msg)
{
	struct nanosoc_ipc_data *d = ctx;
	struct nanosoc_ring *r = &d->shm->rx;
	ARG_UNUSED(mbox); ARG_UNUSED(ch); ARG_UNUSED(msg);
	while (r->tail != r->head) {
		uint32_t t = r->tail;
		if (d->ept && d->ept->cb.received)
			d->ept->cb.received((const void *)r->data[t], r->len[t],
					    d->ept->priv);
		__DMB();
		r->tail = (t + 1) % RING_DEPTH;
	}
}

static const struct ipc_service_backend nanosoc_backend = {
	.register_endpoint = backend_register_endpoint,
	.send = backend_send,
};

static int nanosoc_ipc_init(const struct device *dev)
{
	struct nanosoc_ipc_data *d = dev->data;
	/* TODO(board): resolve d->shm (memory-region), d->mbox + channels (mboxes),
	 * register rx_doorbell on the rx channel, zero the rings on the producer. */
	mbox_register_callback(&d->rx_ch, rx_doorbell, d);
	mbox_set_enabled(&d->rx_ch, true);
	return 0;
}

/* DT instance wiring (compatible "nanosoc,ipc-spsc") is added by the board's
 * devicetree; the DEVICE_DT_INST_DEFINE glue is completed in the west build. */
