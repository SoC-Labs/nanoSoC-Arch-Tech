#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Memory Stress Tests
#
# Systematic memory testing to catch stuck bits, address line faults,
# and aliasing issues that random-probe tests may miss.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import cocotb

from nanosoc_cocotb_driver import NanoSoC

# ---------------------------------------------------------------------------
# Memory region parameters
# ---------------------------------------------------------------------------
SRAM0_BASE      = 0x80000000
SRAM0_PHYS_SIZE = 0x00100000  # 1 MB

SRAM1_BASE      = 0x90000000
SRAM1_PHYS_SIZE = 0x00100000  # 1 MB


@cocotb.test()
async def test_sram_full_write_read(dut):
    """MSTRESS_001: Write address-as-data pattern to SRAM, read back all.

    Writes the word's own address as its data value, stepping through
    SRAM_0 at 1 KB intervals to cover the full physical range in
    manageable time.  Catches stuck-bit and address-decode faults.
    """
    soc = NanoSoC(dut)
    await soc.start()

    STEP = 0x400  # 1 KB stride
    num_locations = SRAM0_PHYS_SIZE // STEP
    dut._log.info(
        f"Writing {num_locations} locations in SRAM_0 "
        f"(0x{SRAM0_BASE:08X}, step=0x{STEP:X})"
    )

    # Write phase
    for i in range(num_locations):
        addr = SRAM0_BASE + (i * STEP)
        await soc.write32(addr, addr)

    # Read phase
    failures = []
    for i in range(num_locations):
        addr = SRAM0_BASE + (i * STEP)
        val = await soc.read32(addr)
        if val != addr:
            msg = f"@ 0x{addr:08X}: got 0x{val:08X}, expected 0x{addr:08X}"
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
            if len(failures) >= 10:
                dut._log.error("  Too many failures, stopping early")
                break

    if not failures:
        dut._log.info(
            f"All {num_locations} locations verified in SRAM_0"
        )

    assert not failures, (
        f"{len(failures)} SRAM write-read failure(s):\n" + "\n".join(failures)
    )
    dut._log.info("SRAM full write-read test PASSED")


@cocotb.test()
async def test_sram_address_uniqueness(dut):
    """MSTRESS_002: Walking-1 through address bits to detect address shorts.

    Writes a unique value to each power-of-2 offset within SRAM_0,
    then reads them all back to verify no address aliased onto another.
    Catches shorted or floating address lines.
    """
    soc = NanoSoC(dut)
    await soc.start()

    # Generate power-of-2 offsets that fit within physical size
    # Start at offset 4 (skip 0 since we use it as a sentinel)
    test_addrs = [SRAM0_BASE]  # offset 0
    offset = 4
    while offset < SRAM0_PHYS_SIZE:
        test_addrs.append(SRAM0_BASE + offset)
        offset <<= 1

    dut._log.info(
        f"Testing {len(test_addrs)} power-of-2 addresses in SRAM_0"
    )

    # Write phase: each address gets a unique pattern
    for i, addr in enumerate(test_addrs):
        pattern = 0xA5000000 | i
        await soc.write32(addr, pattern)

    # Read phase: verify each retained its unique value
    failures = []
    for i, addr in enumerate(test_addrs):
        expected = 0xA5000000 | i
        val = await soc.read32(addr)
        if val != expected:
            msg = (
                f"@ 0x{addr:08X}: got 0x{val:08X}, "
                f"expected 0x{expected:08X} — possible address aliasing"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  0x{addr:08X}: 0x{val:08X}")

    assert not failures, "\n".join(failures)
    dut._log.info("SRAM address uniqueness test PASSED")


@cocotb.test()
async def test_memory_alias_boundary(dut):
    """MSTRESS_003: Verify memory aliasing at the physical/aperture boundary.

    SRAM_0 has 1 MB physical memory but a 256 MB aperture.  Writes at
    the base address should alias at base + physical_size since the
    upper address bits are not decoded by the SRAM.
    """
    soc = NanoSoC(dut)
    await soc.start()

    # Write a known value at SRAM_0 base
    test_val = 0xCAFEBABE
    await soc.write32(SRAM0_BASE, test_val)

    # Verify the base read
    base_val = await soc.read32(SRAM0_BASE)
    assert base_val == test_val, (
        f"Base read failed: got 0x{base_val:08X}, "
        f"expected 0x{test_val:08X}"
    )

    # Read from the alias address (base + physical_size)
    alias_addr = SRAM0_BASE + SRAM0_PHYS_SIZE
    alias_val = await soc.read32(alias_addr)
    dut._log.info(
        f"Base 0x{SRAM0_BASE:08X}: 0x{base_val:08X}, "
        f"Alias 0x{alias_addr:08X}: 0x{alias_val:08X}"
    )

    assert alias_val == test_val, (
        f"Alias mismatch: 0x{alias_addr:08X} returned 0x{alias_val:08X}, "
        f"expected 0x{test_val:08X} (alias of 0x{SRAM0_BASE:08X})"
    )

    # Write a different value at the alias and check it changed at the base
    test_val2 = 0xDEAD1234
    await soc.write32(alias_addr, test_val2)
    base_val2 = await soc.read32(SRAM0_BASE)
    dut._log.info(
        f"After alias write: Base 0x{SRAM0_BASE:08X}: 0x{base_val2:08X}"
    )
    assert base_val2 == test_val2, (
        f"Alias write did not propagate: base returned 0x{base_val2:08X}, "
        f"expected 0x{test_val2:08X}"
    )

    dut._log.info("Memory alias boundary test PASSED")
