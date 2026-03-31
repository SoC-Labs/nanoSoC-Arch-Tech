#-----------------------------------------------------------------------------
# SoCLabs Cocotb DMEM Fill Test
#
# Writes a fill pattern to a range of DMEM addresses and reads them
# all back to verify data integrity.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import random
import cocotb

from nanosoc_cocotb_driver import NanoSoC

DMEM_BASE = 0x30000000
FILL_WORDS = 16


@cocotb.test()
async def test_fill(dut):
    """Fill a range of DMEM with a random value and verify all words match."""
    soc = NanoSoC(dut)
    await soc.start()

    fill_value = random.getrandbits(32)
    dut._log.info(
        f"Filling {FILL_WORDS} words at 0x{DMEM_BASE:08X} "
        f"with 0x{fill_value:08X}"
    )

    # Write fill pattern
    for i in range(FILL_WORDS):
        addr = DMEM_BASE + (i * 4)
        await soc.write32(addr, fill_value)

    # Read back and verify
    failures = []
    for i in range(FILL_WORDS):
        addr = DMEM_BASE + (i * 4)
        val = await soc.read32(addr)
        if val != fill_value:
            msg = (
                f"@ 0x{addr:08X}: expected 0x{fill_value:08X}, "
                f"got 0x{val:08X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  0x{addr:08X}: 0x{val:08X}")

    assert not failures, (
        f"{len(failures)} fill check(s) failed:\n" + "\n".join(failures)
    )
    dut._log.info("DMEM fill test PASSED")
