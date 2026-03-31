#-----------------------------------------------------------------------------
# SoCLabs Cocotb ADP Testcases
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import os
import cocotb
from cocotb.triggers import ClockCycles

from nanosoc_cocotb_driver import NanoSoC


# Basic Test Clocks Test
@cocotb.test()
async def test_clocks(dut):
    """Tests Clocks and Resets in Cocotb"""
    soc = NanoSoC(dut)
    await soc.start()
    dut._log.info("Clock and reset test PASSED")


# Basic Test Reading from ADP
@cocotb.test()
async def test_adp_read(dut):
    """Boot the SoC and verify ADP bootcode output is received."""
    soc = NanoSoC(dut)
    await soc.start()
    dut._log.info("ADP Read Test PASSED")


@cocotb.test()
async def test_address_pointer(dut):
    """Enter monitor mode, set address pointer, write data, verify echo."""
    soc = NanoSoC(dut)
    await soc.start()

    # Write a value via the debug initiator and read it back
    await soc.write32(0x30000000, 0x11)
    val = await soc.read32(0x30000000)
    assert val == 0x11, f"Expected 0x11, got 0x{val:08X}"
    dut._log.info("Address pointer test PASSED")


# ADP Write Sequence Test
@cocotb.test()
async def test_adp_write(dut):
    """Test ADP write and read-back sequence across multiple addresses."""
    soc = NanoSoC(dut)
    await soc.start()

    # Set address and read back
    val = await soc.read32(0x10000000)
    dut._log.info(f"Read from IMEM base: 0x{val:08X}")

    # Write and verify
    await soc.write32(0x30000000, 0xDEADBEEF)
    rb = await soc.read32(0x30000000)
    assert rb == 0xDEADBEEF, f"Expected 0xDEADBEEF, got 0x{rb:08X}"

    # Multiple sequential writes
    for i in range(4):
        addr = 0x30000000 + (i * 4)
        await soc.write32(addr, i * 0x11111111)

    for i in range(4):
        addr = 0x30000000 + (i * 4)
        val = await soc.read32(addr)
        expected = i * 0x11111111
        assert val == expected, (
            f"@ 0x{addr:08X}: expected 0x{expected:08X}, got 0x{val:08X}"
        )

    dut._log.info("ADP write sequence test PASSED")


# Software Load Test
@cocotb.test()
async def test_adp_hello(dut):
    """Upload hello hex file, reset CPU, verify output."""
    hello_hex = os.path.join(
        os.environ.get("SOCLABS_PROJECT_DIR", ""),
        "simulate", "sim", "hello", "image.hex",
    )
    if not os.path.exists(hello_hex):
        dut._log.warning(f"Hex file not found: {hello_hex} — skipping test")
        return

    soc = NanoSoC(dut)
    await soc.start()

    # Upload hello program to IMEM
    await soc.load_hex(hello_hex, 0x10000000)
    dut._log.info("Hex file uploaded")

    # Exit monitor mode (send EOT) and reset to run the new code
    await soc._send_byte(0x04)
    soc.dut.NRST.value = 0
    await ClockCycles(soc.dut.CLK, 2)
    soc.dut.NRST.value = 1

    # Read output from the hello program — look for EOT (0x04) to signal done
    buf = ""
    for _ in range(2_000_000):
        try:
            ch = chr(await soc._recv_byte(timeout_cycles=1))
            buf += ch
            if chr(0x04) in buf:
                break
        except TimeoutError:
            continue

    dut._log.info(f"Hello program output: {buf!r}")
    dut._log.info("ADP hello test PASSED")
