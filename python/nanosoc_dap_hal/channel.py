# Copyright 2026, SoC Labs (www.soclabs.org)
"""Generic DAP/register channel interfaces + data classes (stdlib only).

Promoted from nanosoc-multicore-system's HAL so every nanosoc system shares one
CoreSight-DAP access layer. This module is the transport-agnostic ABI; the
OpenOCD/SWD implementation lives in :mod:`nanosoc_dap_hal.swd`. Kept
dependency-free so it imports on any host (no board, no openocd).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional


@dataclass
class RegRead:
    """Result of a register access (read or write-back)."""

    addr: int
    value: Optional[int] = None
    ok: bool = True
    fault: bool = False
    note: str = ""

    def to_dict(self) -> Dict:
        return {
            "addr": self.addr,
            "addr_hex": f"0x{self.addr:08X}",
            "value": self.value,
            "value_hex": None if self.value is None else f"0x{self.value:08X}",
            "ok": self.ok,
            "fault": self.fault,
            "note": self.note,
        }


@dataclass
class CoreStatus:
    """Per-core debug state, read non-intrusively over the core's AHB-AP."""

    core: str              # core name, e.g. "cpu0" / "cpu1" / "compute"
    present: bool = True
    halted: bool = False
    pc: Optional[int] = None
    cpuid: Optional[int] = None
    # True when a managed/boot-gated core is held in hardware reset (its boot-gate
    # not yet released) and so is not examinable over its AP — surface as a prompt
    # to release the core rather than an error. See core_remap_ctrl (BOOTGATE).
    reset_held: bool = False
    note: str = ""

    def to_dict(self) -> Dict:
        return {
            "core": self.core,
            "present": self.present,
            "halted": self.halted,
            "pc": self.pc,
            "pc_hex": None if self.pc is None else f"0x{self.pc:08X}",
            "cpuid": self.cpuid,
            "cpuid_hex": None if self.cpuid is None else f"0x{self.cpuid:08X}",
            "reset_held": self.reset_held,
            "note": self.note,
        }


class Channel:
    """Base for every HAL channel. Override open/close for real transports."""

    name: str = "channel"

    def __init__(self) -> None:
        self._connected = False

    @property
    def connected(self) -> bool:
        return self._connected

    async def open(self) -> None:
        self._connected = True

    async def close(self) -> None:
        self._connected = False


class RegisterChannel(Channel):
    """Arbitrary register/memory access and per-core debug state."""

    name = "regs"

    async def read32(self, addr: int) -> RegRead:
        raise NotImplementedError

    async def write32(self, addr: int, value: int) -> RegRead:
        raise NotImplementedError

    async def core_status(self, core: str) -> CoreStatus:
        raise NotImplementedError

    async def halt(self, core: str) -> CoreStatus:
        raise NotImplementedError

    async def resume(self, core: str) -> CoreStatus:
        raise NotImplementedError

    async def release_bootgate(self, addr: int, value: int = 0x2) -> RegRead:
        """Release a managed core from hardware reset via its boot-gate register.

        Writes ``value`` (default ``0x2`` = BOOTGATE release, no remap — see
        core_remap_ctrl bit1) to ``addr`` then reads it back so the caller can
        confirm the gate latched. The boot-gate register address is
        system-specific, so it is passed in rather than hard-coded. Implemented
        on the base in terms of :meth:`write32`/:meth:`read32` so it works on
        every channel (sim overlay and the real SWD path) without an override.
        """
        wr = await self.write32(addr, value)
        if wr.fault:
            return wr
        return await self.read32(addr)
