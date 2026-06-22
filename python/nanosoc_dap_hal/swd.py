# Copyright 2026, SoC Labs (www.soclabs.org)
"""Register/debug channel over a persistent OpenOCD Tcl-RPC server.

OpenOCD runs on the dev-host (probe -> SoC CoreSight DAP) as a long-lived server
exposing its Tcl port (default 6666). Reads/writes go through the DAP's AHB-APs
directly (CSW/TAR/DRW via ``<dap> apreg``), which access system memory WITHOUT
examining or halting the cortex_m targets — so continuous register polling never
disturbs a freely-running image.

Promoted from nanosoc-multicore-system. System-specifics are injected via the
constructor (DAP name, target prefix, per-core AP map, optional USB-reset
recovery callback), so it works for any nanosoc with a CoreSight DAP — the
dual-M0+ multicore and the M0+/M4 compute system alike.

    chan = SwdRegisterChannel(host="localhost", port=6666,
                              dap_name="nanosoc.dap", target_prefix="nanosoc",
                              ap_map={"cpu0": 0, "cpu1": 1})
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Callable, Dict, Optional

from nanosoc_dap_hal.channel import CoreStatus, RegisterChannel, RegRead

_ERR_MARKERS = ("error", "failed", "timeout", "invalid", "cannot", "not halted")

# Direct AHB-AP access (CSW/TAR/DRW via `<dap> apreg`) reads/writes system memory
# WITHOUT examining or halting the cortex_m target — proven on hw to sustain long
# read bursts on a marginal link where the target-mediated `mdw` path wedges.
_CSW_WORD = 0x23000002          # 32-bit access size, address auto-increment off


async def _ap_read_held(tcl, dap: str, ap: int, addr: int) -> str:
    """One direct AHB-AP word read; caller holds the connection lock.

    Returns the raw DRW reply (the 32-bit value, e.g. ``0x18003c00``).
    """
    await tcl.command_held(f"{dap} apreg {ap} 0x00 0x{_CSW_WORD:08x}")
    await tcl.command_held(f"{dap} apreg {ap} 0x04 0x{addr:08x}")
    return await tcl.command_held(f"{dap} apreg {ap} 0x0c")


async def _ap_write_held(tcl, dap: str, ap: int, addr: int, value: int) -> None:
    """One direct AHB-AP word write; caller holds the connection lock."""
    await tcl.command_held(f"{dap} apreg {ap} 0x00 0x{_CSW_WORD:08x}")
    await tcl.command_held(f"{dap} apreg {ap} 0x04 0x{addr:08x}")
    await tcl.command_held(f"{dap} apreg {ap} 0x0c 0x{value:08x}")


class _TclClient:
    """Minimal async OpenOCD Tcl-RPC client (commands framed by 0x1a).

    A single :class:`asyncio.Lock` serialises access to the one TCP connection.
    :meth:`command` takes it per-call so request/reply framing can never desync.
    For a multi-command transaction that must stay atomic on the wire, :meth:`hold`
    acquires the same lock for the whole sequence and :meth:`command_held` issues
    commands without re-acquiring it (the lock is non-reentrant).
    """

    SEP = b"\x1a"

    def __init__(self, host: str, port: int):
        self.host, self.port = host, port
        self._r: Optional[asyncio.StreamReader] = None
        self._w: Optional[asyncio.StreamWriter] = None
        # Created lazily inside the running loop so py3.8/3.9 (Lock binds the loop
        # at construction) matches py3.10+ (binds at first await); __init__ may run
        # from sync code with no loop running.
        self._lock: Optional[asyncio.Lock] = None

    def _serial_lock(self) -> asyncio.Lock:
        """The connection lock, created inside the running loop (py3.8-safe)."""
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    async def connect(self) -> None:
        self._r, self._w = await asyncio.open_connection(self.host, self.port)

    async def close(self) -> None:
        if self._w is not None:
            self._w.close()
            try:
                await self._w.wait_closed()
            except Exception:
                pass
        self._r = self._w = None

    async def command_held(self, cmd: str) -> str:
        """Issue one command WITHOUT taking the lock (caller must hold it).

        Only valid inside an ``async with tcl.hold():`` block. Self-healing: a
        dead/closed transport (OpenOCD restarted underneath us) triggers one
        transparent reconnect before the command is retried.
        """
        for attempt in (0, 1):
            if self._w is None or self._r is None or self._w.is_closing():
                await self._reconnect()
            try:
                self._w.write(cmd.encode() + self.SEP)
                await asyncio.wait_for(self._w.drain(), timeout=2.5)
                data = await asyncio.wait_for(self._r.readuntil(self.SEP),
                                              timeout=2.5)
                return data[:-1].decode("ascii", "replace").strip()
            except (RuntimeError, ConnectionError, OSError,
                    asyncio.IncompleteReadError, asyncio.TimeoutError):
                if attempt:
                    raise
                await self._reconnect()
        raise ConnectionError("OpenOCD Tcl unreachable")

    async def _reconnect(self) -> None:
        try:
            if self._w is not None:
                self._w.close()
        except Exception:
            pass
        # Bounded connect: while the daemon is briefly absent (restart) a bare
        # open_connection can hang the loop; fail fast so the caller faults and
        # the poller retries on its next tick.
        self._r, self._w = await asyncio.wait_for(
            asyncio.open_connection(self.host, self.port), timeout=2.5)

    async def command(self, cmd: str) -> str:
        async with self._serial_lock():
            return await self.command_held(cmd)

    @asynccontextmanager
    async def hold(self):
        """Hold the connection lock across a whole multi-command transaction."""
        async with self._serial_lock():
            yield self


class SwdRegisterChannel(RegisterChannel):
    """OpenOCD/SWD register channel over the CoreSight DAP's AHB-APs.

    System-specifics are injected:
      dap_name      OpenOCD DAP object name (from the openocd cfg), e.g. "nanosoc.dap"
      target_prefix cortex_m target name prefix, e.g. "nanosoc" -> "nanosoc.cpu0"
      ap_map        per-core AHB-AP index, e.g. {"cpu0": 0, "cpu1": 1}
      managed_cores cores that may be held in reset by a boot-gate (reset_held)
      usb_reset_cb  optional callable(serial)->bool to USB-reset the probe on a
                    wedged link (no system import; default no-op)
    """

    def __init__(self, host: str = "localhost", port: int = 6666,
                 stlink_serial: Optional[str] = None,
                 dap_name: str = "nanosoc.dap",
                 target_prefix: str = "nanosoc",
                 ap_map: Optional[Dict[str, int]] = None,
                 managed_cores=("cpu1",),
                 usb_reset_cb: Optional[Callable[[str], bool]] = None):
        super().__init__()
        self._tcl = _TclClient(host, port)
        self._dap = dap_name
        self._target_prefix = target_prefix
        self._ap_map = dict(ap_map) if ap_map else {"cpu0": 0, "cpu1": 1}
        self._managed_cores = set(managed_cores)
        self._ap = self._ap_map.get("cpu0", 0)   # default AHB-AP
        self._stlink_serial = stlink_serial
        self._usb_reset_cb = usb_reset_cb

    def _ap_for(self, core: str) -> int:
        # Accept bare ("cpu0") or prefixed ("nanosoc.cpu0") core names.
        key = core.split(".")[-1] if core else "cpu0"
        return self._ap_map.get(key, 0)

    async def open(self) -> None:
        # Reads/writes go through the DAP's AHB-AP directly (apreg CSW/TAR/DRW),
        # accessing system memory WITHOUT examining or halting the cortex_m
        # targets — so there is deliberately NO arp_examine here. The only places
        # that intentionally examine/halt are explicit halt()/resume()/loader ops.
        await self._tcl.connect()
        self._connected = True

    async def close(self) -> None:
        await self._tcl.close()
        self._connected = False

    async def recover_adapter(self) -> bool:
        """Recover a wedged SWD link by USB-resetting the probe (opt-in).

        A USB re-enumeration of the probe forces OpenOCD to re-acquire the DAP,
        which drives a fresh SWD line reset — which RESETS a running baked image
        on -defer-examine cores. So this is enabled only when
        ``NANOSOC_USB_RESET_RECOVER=1`` and a ``usb_reset_cb`` + serial are
        configured; otherwise it is a no-op and the channel stays strictly
        non-disruptive to a freely-running core.
        """
        import os
        if os.environ.get("NANOSOC_USB_RESET_RECOVER", "0") != "1":
            return False
        if not self._stlink_serial or self._usb_reset_cb is None:
            return False
        loop = asyncio.get_event_loop()
        ok = await loop.run_in_executor(
            None, self._usb_reset_cb, self._stlink_serial)
        if ok:
            # Let the device re-enumerate and the held-open daemon re-acquire it.
            # The python<->openocd tcl socket is untouched; do NOT close it.
            await asyncio.sleep(2.5)
        return bool(ok)

    @staticmethod
    def _is_error(out: str) -> bool:
        low = out.lower()
        return any(m in low for m in _ERR_MARKERS)

    def _parse_ap_read(self, addr: int, out: str) -> RegRead:
        """Turn a direct ``apreg`` DRW reply (a bare hex value) into a RegRead."""
        tok = out.strip().split()[0] if (out and not self._is_error(out)) else ""
        for base in (0, 16):
            try:
                return RegRead(addr, value=int(tok, base), note=out)
            except ValueError:
                continue
        return RegRead(addr, ok=False, fault=True, note=out or "no response")

    async def read32(self, addr: int) -> RegRead:
        try:
            async with self._tcl.hold():
                out = await _ap_read_held(self._tcl, self._dap, self._ap, addr)
        except Exception as exc:  # connection / readuntil failure
            return RegRead(addr, ok=False, fault=True, note=str(exc))
        return self._parse_ap_read(addr, out)

    async def write32(self, addr: int, value: int) -> RegRead:
        try:
            async with self._tcl.hold():
                await _ap_write_held(self._tcl, self._dap, self._ap, addr, value)
        except Exception as exc:
            return RegRead(addr, ok=False, fault=True, note=str(exc))
        return RegRead(addr, value=value, note="ok")

    # ── Atomic multi-command transactions (e.g. an IPC RPC handshake) ─────────
    @asynccontextmanager
    async def transaction(self, core: str = "cpu0"):
        """Hold the connection lock for a whole transaction, ops pinned to a core's AP."""
        async with self._tcl.hold():
            yield _SwdTxn(self._tcl, self, self._dap, self._ap_for(core))

    @asynccontextmanager
    async def raw_session(self):
        """Hold the lock and yield a raw Tcl command runner (load_image/apreg/resume…)."""
        async with self._tcl.hold():
            yield _RawSession(self._tcl, self)

    async def core_status(self, core: str) -> CoreStatus:
        # READ-ONLY core status via the raw AHB-AP (apreg CSW/TAR/DRW) — the SAME
        # path read32 uses. It NEVER examines or halts the cortex_m target, so
        # polling against a freely-running baked image does not disturb run state.
        ap = self._ap_for(core)

        async def _ap_word(addr: int):
            out = await _ap_read_held(self._tcl, self._dap, ap, addr)
            rr = self._parse_ap_read(addr, out)
            return rr.value if (rr.ok and not rr.fault) else None

        try:
            async with self._tcl.hold():
                # DHCSR (0xE000EDF0): debug/halt status. CPUID (0xE000ED00).
                dhcsr = await _ap_word(0xE000EDF0)
                cpuid = await _ap_word(0xE000ED00)
        except Exception:
            return CoreStatus(core=core, present=False)

        # A boot-gated managed core is held in hardware reset until its bootgate
        # is released; while held its AHB-AP returns nothing. Surface as
        # reset_held so the UI prompts a release rather than showing a dead core.
        if dhcsr is None and cpuid is None:
            bare = core.split(".")[-1]
            if bare in self._managed_cores:
                return CoreStatus(core=core, present=False, reset_held=True,
                                  note="held in reset (bootgate not released)")
            return CoreStatus(core=core, present=False)

        # Run state from DHCSR (ARMv6-M / ARMv7-M):
        #   bit17 S_HALT, bit19 S_LOCKUP, bit25 S_RESET_ST
        halted = bool(dhcsr is not None and (dhcsr & (1 << 17)))
        lockup = bool(dhcsr is not None and (dhcsr & (1 << 19)))
        note = ""
        if lockup:
            note = "lockup"
        elif dhcsr is not None and (dhcsr & (1 << 25)):
            note = "reset"
        elif not halted:
            note = "running"

        # PC is only meaningful when HALTED (no non-intrusive PC sampling); only
        # read it when DHCSR already shows halted, never halt to obtain it. The
        # DCRSR/DCRDR transfer goes through the SAME raw AHB-AP: write DCRSR
        # (0xE000EDF4)=0xF (reg 15 = PC), poll DHCSR.S_REGRDY (bit16), read DCRDR.
        pc = None
        if halted:
            try:
                async with self._tcl.hold():
                    await _ap_write_held(self._tcl, self._dap, ap, 0xE000EDF4, 0x0000000F)
                    for _ in range(10):
                        d = self._parse_ap_read(
                            0xE000EDF0,
                            await _ap_read_held(self._tcl, self._dap, ap, 0xE000EDF0))
                        if d.ok and not d.fault and d.value is not None \
                                and (d.value & (1 << 16)):
                            break
                    out = await _ap_read_held(self._tcl, self._dap, ap, 0xE000EDF8)
                rr = self._parse_ap_read(0xE000EDF8, out)
                if rr.ok and not rr.fault:
                    pc = rr.value
            except Exception:
                pass
        return CoreStatus(core=core, present=True, halted=halted,
                          cpuid=cpuid, pc=pc, note=note)

    async def halt(self, core: str) -> CoreStatus:
        await self._tcl.command(f"targets {self._target_prefix}.{core.split('.')[-1]}")
        await self._tcl.command("halt")
        return await self.core_status(core)

    async def resume(self, core: str) -> CoreStatus:
        await self._tcl.command(f"targets {self._target_prefix}.{core.split('.')[-1]}")
        await self._tcl.command("resume")
        return await self.core_status(core)


class _SwdTxn:
    """Target-qualified, lock-free register ops valid inside ``transaction()``."""

    def __init__(self, tcl: "_TclClient", chan: "SwdRegisterChannel",
                 dap: str, ap: int):
        self._tcl = tcl
        self._chan = chan
        self._dap = dap
        self._ap = ap

    async def read32(self, addr: int) -> RegRead:
        try:
            out = await _ap_read_held(self._tcl, self._dap, self._ap, addr)
        except Exception as exc:
            return RegRead(addr, ok=False, fault=True, note=str(exc))
        return self._chan._parse_ap_read(addr, out)

    async def write32(self, addr: int, value: int) -> RegRead:
        try:
            await _ap_write_held(self._tcl, self._dap, self._ap, addr, value)
        except Exception as exc:
            return RegRead(addr, ok=False, fault=True, note=str(exc))
        return RegRead(addr, value=value, note="ok")


class _RawSession:
    """Raw OpenOCD Tcl command runner valid inside ``raw_session()``."""

    def __init__(self, tcl: "_TclClient", chan: "SwdRegisterChannel"):
        self._tcl = tcl
        self._chan = chan

    async def command(self, cmd: str) -> str:
        return await self._tcl.command_held(cmd)

    def is_error(self, out: str) -> bool:
        return self._chan._is_error(out)
