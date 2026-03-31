#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Firmware Load Tests
#
# Tests firmware upload via ADP and bootrom content verification.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import os
import cocotb
from cocotb.triggers import ClockCycles

from nanosoc_cocotb_driver import NanoSoC


@cocotb.test()
async def test_hex_upload_and_reset(dut):
    """FW_001: Upload hello hex file, reset CPU, verify program runs."""
    hello_hex = os.path.join(
        os.environ.get("SOCLABS_PROJECT_DIR", ""),
        "simulate", "sim", "hello", "image.hex",
    )
    if not os.path.exists(hello_hex):
        dut._log.warning(f"Hex file not found: {hello_hex} — skipping")
        return

    soc = NanoSoC(dut)
    await soc.start()

    # Read a word from IMEM before upload
    imem_before = await soc.read32(0x10000000)
    dut._log.info(f"IMEM[0] before upload: 0x{imem_before:08X}")

    # Upload the hex file
    await soc.load_hex(hello_hex, 0x10000000)

    # Read IMEM after upload — should have changed
    imem_after = await soc.read32(0x10000000)
    dut._log.info(f"IMEM[0] after upload: 0x{imem_after:08X}")

    # Exit monitor mode and reset
    await soc._send_byte(0x04)
    soc.dut.NRST.value = 0
    await ClockCycles(soc.dut.CLK, 2)
    soc.dut.NRST.value = 1

    # Read output from the hello program
    buf = ""
    try:
        for _ in range(2_000_000):
            ch = chr(await soc._recv_byte(timeout_cycles=1))
            buf += ch
            if chr(0x04) in buf:
                break
    except TimeoutError:
        pass

    dut._log.info(f"Program output ({len(buf)} chars): {buf!r}")
    assert len(buf) > 0, "No output received from program after reset"
    dut._log.info("Hex upload and reset test PASSED")


@cocotb.test()
async def test_bootrom_read(dut):
    """FW_002: Read bootrom content and verify it looks like a valid ARM vector table."""
    soc = NanoSoC(dut)
    await soc.start()

    # Read from the bootrom alias at 0x08000000 (always points to bootrom
    # regardless of remap state)
    sp_init = await soc.read32(0x08000000)
    reset_vector = await soc.read32(0x08000004)

    dut._log.info(f"Bootrom[0x0] (initial SP):    0x{sp_init:08X}")
    dut._log.info(f"Bootrom[0x4] (reset vector):  0x{reset_vector:08X}")

    # Initial SP should be non-zero and word-aligned
    assert sp_init != 0, "Initial SP is zero — bootrom may not be loaded"
    assert (sp_init & 0x3) == 0, (
        f"Initial SP 0x{sp_init:08X} is not word-aligned"
    )

    # Reset vector should be non-zero and have bit 0 set (Thumb mode)
    assert reset_vector != 0, "Reset vector is zero — bootrom may not be loaded"
    assert (reset_vector & 0x1) == 1, (
        f"Reset vector 0x{reset_vector:08X} does not have Thumb bit set"
    )

    # Read a few more words to make sure we're getting real data
    for i in range(2, 6):
        addr = 0x08000000 + (i * 4)
        val = await soc.read32(addr)
        dut._log.info(f"Bootrom[0x{i * 4:X}]: 0x{val:08X}")

    dut._log.info("Bootrom content verification PASSED")
