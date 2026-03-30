#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Cocotb Driver
#
# Simplified interface to the NanoSoC via HOSTIO4 channel 0 (ADP).
# Drives the HOSTIO4 target AXI-Stream signals directly, providing
# clean read32/write32 methods for system-level verification.
#
# HOSTIO4 signal mapping (from hostio4_target perspective):
#   axis_rx0 = data FROM external host TO SoC (ADP stdin)
#   axis_tx0 = data FROM SoC TO external host (ADP stdout)
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10


class NanoSoC:
    """High-level cocotb driver for the NanoSoC via HOSTIO4.

    Uses HOSTIO4 channel 0 (ADP debug port) to perform bus reads and
    writes through the SoC's debug initiator.

    Usage::

        soc = NanoSoC(dut)
        await soc.start()
        val = await soc.read32(0x40000FF0)
        await soc.write32(0x80000000, 0xDEADBEEF)
    """

    BOOT_MARKER = "** Remap->IMEM0"
    PROMPT = "\n\r]"

    def __init__(self, dut):
        self.dut = dut
        self.log = dut._log

    async def start(self):
        """Boot the SoC: start clock, reset, wait for bootcode, enter
        ADP monitor mode.  After this returns the SoC is ready for
        read32/write32 calls."""

        # Start system clock
        cocotb.start_soon(Clock(self.dut.CLK, CLK_PERIOD_NS, "ns").start())

        # Initialise HOSTIO4 channel 0 AXI-Stream handshake signals
        #   rx0 = host-to-SoC (we are the source)
        #   tx0 = SoC-to-host (we are the sink, always ready)
        self.dut.axis_rx0_tvalid.value = 0
        self.dut.axis_rx0_tdata8.value = 0
        self.dut.axis_tx0_tready.value = 1

        # Apply reset
        self.dut.NRST.value = 0
        await ClockCycles(self.dut.CLK, 2)
        self.dut.NRST.value = 1
        await ClockCycles(self.dut.CLK, 2)

        # Wait for bootcode to complete
        self.log.info("Waiting for bootcode to complete...")
        await self._read_until(self.BOOT_MARKER)
        self.log.info("Bootcode complete")

        # Enter ADP monitor mode (send ESC character)
        self.log.info("Entering ADP monitor mode")
        await self._send_byte(0x1B)
        await self._read_until(self.PROMPT)
        self.log.info("NanoSoC ready for bus access")

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def read32(self, address: int) -> int:
        """Read a 32-bit word from *address* via the debug initiator."""
        await self._adp_command(f"A0x{address:08X}\n")
        resp = await self._adp_command("R\n")
        return self._parse_hex(resp)

    async def write32(self, address: int, data: int):
        """Write a 32-bit word *data* to *address* via the debug initiator."""
        await self._adp_command(f"A0x{address:08X}\n")
        await self._adp_command(f"W0x{data:08X}\n")

    async def load_hex(self, filepath: str, address: int = 0x10000000):
        """Upload a hex file into SoC memory using ADP bulk-upload mode."""
        file_size = os.stat(filepath).st_size
        byte_count = file_size // 3  # hex file: "HH\n" per byte

        await self._adp_command(f"A0x{address:08X}\n")
        await self._send_string(f"U {hex(byte_count)}\n")

        with open(filepath, "r") as f:
            for _ in range(byte_count):
                line = f.readline().strip()
                await self._send_byte(int(line, 16))

        await self._send_byte(0x0A)
        await self._read_until(self.PROMPT)
        self.log.info(f"Loaded {byte_count} bytes to 0x{address:08X}")

    async def reset(self):
        """Pulse reset and re-enter monitor mode."""
        self.dut.NRST.value = 0
        await ClockCycles(self.dut.CLK, 2)
        self.dut.NRST.value = 1
        await ClockCycles(self.dut.CLK, 2)
        await self._read_until(self.BOOT_MARKER)
        await self._send_byte(0x1B)
        await self._read_until(self.PROMPT)

    # ------------------------------------------------------------------
    # HOSTIO4 AXI-Stream byte-level transport
    # ------------------------------------------------------------------

    async def _send_byte(self, value: int):
        """Send one byte to the SoC on HOSTIO4 channel 0 (axis_rx0).

        AXI-Stream handshake: hold tdata+tvalid, wait for tready on a
        rising clock edge, then deassert tvalid.
        """
        self.dut.axis_rx0_tdata8.value = value & 0xFF
        self.dut.axis_rx0_tvalid.value = 1
        while True:
            await RisingEdge(self.dut.CLK)
            if self.dut.axis_rx0_tready.value:
                break
        self.dut.axis_rx0_tvalid.value = 0

    async def _recv_byte(self, timeout_cycles: int = 500_000) -> int:
        """Receive one byte from the SoC on HOSTIO4 channel 0 (axis_tx0).

        Keeps tready asserted and waits for tvalid.  Raises TimeoutError
        if no data arrives within *timeout_cycles* clock cycles.
        """
        self.dut.axis_tx0_tready.value = 1
        for _ in range(timeout_cycles):
            await RisingEdge(self.dut.CLK)
            if self.dut.axis_tx0_tvalid.value:
                return int(self.dut.axis_tx0_tdata8.value)
        raise TimeoutError(
            f"HOSTIO4 rx timeout after {timeout_cycles} cycles"
        )

    # ------------------------------------------------------------------
    # ADP protocol helpers
    # ------------------------------------------------------------------

    async def _send_string(self, s: str):
        """Send a string as individual bytes."""
        for c in s:
            await self._send_byte(ord(c))

    async def _read_until(self, marker: str) -> str:
        """Accumulate received characters until *marker* appears."""
        buf = ""
        while marker not in buf:
            buf += chr(await self._recv_byte())
        return buf

    async def _adp_command(self, cmd: str) -> str:
        """Send an ADP command and wait for the prompt response."""
        await self._send_string(cmd)
        return await self._read_until(self.PROMPT)

    @staticmethod
    def _parse_hex(response: str) -> int:
        """Extract the last 32-bit hex value from an ADP response.

        The ADP 'R' response contains the read data as ``0xHHHHHHHH``.
        We use rfind to skip any hex values in the echoed command and
        pick up only the response data.
        """
        resp_lower = response.lower()
        idx = resp_lower.rfind("0x")
        if idx < 0:
            raise ValueError(
                f"No hex value in ADP response: {response!r}"
            )
        hex_chars = ""
        for c in resp_lower[idx + 2:]:
            if c in "0123456789abcdef":
                hex_chars += c
            else:
                break
        if not hex_chars:
            raise ValueError(
                f"No hex digits after '0x' in ADP response: {response!r}"
            )
        return int(hex_chars, 16)
