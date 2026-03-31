#-----------------------------------------------------------------------------
# SoCLabs NanoSoC System Table (CoreSight ROM Table) Tests
#
# Verifies the CoreSight ROM table at 0xF0000000 which contains the
# SoC's JEDEC manufacturer ID, part number, and debug component pointers.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import cocotb

from nanosoc_cocotb_driver import NanoSoC

# ---------------------------------------------------------------------------
# System table base address and expected identity values
# ---------------------------------------------------------------------------
SYSTABLE_BASE = 0xF0000000

# Parameters from nanosoc_m0_soc.yaml:
#   SOCLABS_JEPID      = 0x51
#   NANOSOC_PARTNUMBER = 0x001
#   NANOSOC_REVISION   = 0x1
#   JEPCONTINUATION    = 0x0

JEPID          = 0x51
PARTNUMBER     = 0x001
REVISION       = 0x1
JEPCONTINUATION = 0x0

# CoreSight ROM table CID (class = 0x1 for ROM table)
EXPECTED_CID = [0x0D, 0x10, 0x05, 0xB1]

# PID calculation from nanosoc_coresight_systable.v:
#   PID0 = PARTNUMBER[7:0]
#   PID1 = {JEPID[3:0], PARTNUMBER[11:8]}
#   PID2 = {REVISION[3:0], 1'b1, JEPID[6:4]}
#   PID3 = {ECOREVNUM[3:0], 4'b0000}  (ECOREVNUM=0)
#   PID4 = {4'b0000, JEPCONTINUATION[3:0]}
EXPECTED_PID = [
    PARTNUMBER & 0xFF,                                          # PID0
    ((JEPID & 0x0F) << 4) | ((PARTNUMBER >> 8) & 0x0F),       # PID1
    ((REVISION & 0x0F) << 4) | (1 << 3) | ((JEPID >> 4) & 0x07),  # PID2
    0x00,                                                       # PID3 (ECOREVNUM=0)
    JEPCONTINUATION & 0x0F,                                     # PID4
]

# ROM table entry offsets
ENTRY0_OFFSET = 0x000
ENTRY1_OFFSET = 0x004

# PID/CID offsets
PID_OFFSETS = [0xFE0, 0xFE4, 0xFE8, 0xFEC, 0xFD0]  # PID0-PID3, PID4
CID_OFFSETS = [0xFF0, 0xFF4, 0xFF8, 0xFFC]            # CID0-CID3


@cocotb.test()
async def test_systable_coresight_id(dut):
    """SYS_001: Verify CoreSight ROM table PID/CID at 0xF0000000."""
    soc = NanoSoC(dut)
    await soc.start()

    failures = []

    # Read and check CID0-CID3
    dut._log.info("Checking CID registers:")
    for i, offset in enumerate(CID_OFFSETS):
        val = await soc.read32(SYSTABLE_BASE + offset) & 0xFF
        expected = EXPECTED_CID[i]
        status = "PASS" if val == expected else "FAIL"
        dut._log.info(
            f"  {status}  CID{i} @ 0x{SYSTABLE_BASE + offset:08X}: "
            f"0x{val:02X} (expected 0x{expected:02X})"
        )
        if val != expected:
            failures.append(
                f"CID{i}: got 0x{val:02X}, expected 0x{expected:02X}"
            )

    # Read and check PID0-PID4
    pid_names = ["PID0", "PID1", "PID2", "PID3", "PID4"]
    dut._log.info("Checking PID registers:")
    for i, offset in enumerate(PID_OFFSETS):
        val = await soc.read32(SYSTABLE_BASE + offset) & 0xFF
        expected = EXPECTED_PID[i]
        status = "PASS" if val == expected else "FAIL"
        dut._log.info(
            f"  {status}  {pid_names[i]} @ 0x{SYSTABLE_BASE + offset:08X}: "
            f"0x{val:02X} (expected 0x{expected:02X})"
        )
        if val != expected:
            failures.append(
                f"{pid_names[i]}: got 0x{val:02X}, expected 0x{expected:02X}"
            )

    assert not failures, (
        f"Systable identity check failed:\n" + "\n".join(failures)
    )
    dut._log.info("CoreSight ROM table identity test PASSED")


@cocotb.test()
async def test_systable_rom_entries(dut):
    """SYS_002: Verify ROM table entries point to expected debug components."""
    soc = NanoSoC(dut)
    await soc.start()

    # Entry 0: should be present (bit[0]=1) and point to Cortex-M0 debug ROM
    # Expected: ENTRY0BASEADDR = 0xE00FF000, relative to SYSTABLE_BASE
    entry0 = await soc.read32(SYSTABLE_BASE + ENTRY0_OFFSET)
    entry0_present = entry0 & 0x1
    entry0_format = (entry0 >> 1) & 0x1
    entry0_addr_offset = (entry0 >> 12) & 0xFFFFF

    dut._log.info(
        f"Entry 0: 0x{entry0:08X} "
        f"(present={entry0_present}, format={entry0_format}, "
        f"offset=0x{entry0_addr_offset:05X})"
    )

    assert entry0_present == 1, (
        f"Entry 0 should be present (bit[0]=1), got 0x{entry0:08X}"
    )
    assert entry0_format == 1, (
        f"Entry 0 should be 32-bit format (bit[1]=1), got 0x{entry0:08X}"
    )

    # Compute the component address
    component_addr = (SYSTABLE_BASE + (entry0_addr_offset << 12)) & 0xFFFFFFFF
    dut._log.info(f"  Entry 0 component address: 0x{component_addr:08X}")

    # Entry 1: should NOT be present
    entry1 = await soc.read32(SYSTABLE_BASE + ENTRY1_OFFSET)
    entry1_present = entry1 & 0x1
    dut._log.info(f"Entry 1: 0x{entry1:08X} (present={entry1_present})")
    assert entry1_present == 0, (
        f"Entry 1 should not be present, got 0x{entry1:08X}"
    )

    # End-of-table: entries after the last should be 0x00000000
    entry_eot = await soc.read32(SYSTABLE_BASE + 0x010)
    dut._log.info(f"Entry @ 0x010: 0x{entry_eot:08X} (should be end-of-table)")
    assert entry_eot == 0x00000000, (
        f"Expected end-of-table (0x00000000), got 0x{entry_eot:08X}"
    )

    dut._log.info("ROM table entry test PASSED")
