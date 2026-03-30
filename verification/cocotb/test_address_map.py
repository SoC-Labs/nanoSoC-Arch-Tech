#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Address Map Verification Test
#
# System-level test that uses the generated Python address map model and
# the simplified NanoSoC driver (via HOSTIO4) to verify:
#
#   1. Peripheral identity — read PID/CID registers at each peripheral
#      and compare against expected values from the register map model.
#
#   2. Memory write-read — write random data to writable memory regions
#      and read it back to verify interconnect and memory decode.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

import random
import sys
import os

import cocotb

from nanosoc_cocotb_driver import NanoSoC

# Add the generated address map to the Python path
sys.path.insert(0, os.path.join(
    os.environ.get("SOCLABS_PROJECT_DIR", ""),
    "build", "rtl", "nanosoc_combined_address_map", "address_maps",
))
from nanosoc_address_map import ADDRESS_MAP, TARGETS


# ---------------------------------------------------------------------------
# Expected peripheral identity values (from register-map YAML definitions)
# ---------------------------------------------------------------------------
#
# Standard ARM CMSDK Component ID (same for all PrimeCell peripherals):
CMSDK_CID = [0x0D, 0xF0, 0x05, 0xB1]

# PID/CID register offsets within each 4 KB peripheral block
PID_OFFSETS = {
    "PID4": 0xFD0, "PID5": 0xFD4, "PID6": 0xFD8, "PID7": 0xFDC,
    "PID0": 0xFE0, "PID1": 0xFE4, "PID2": 0xFE8, "PID3": 0xFEC,
}
CID_OFFSETS = {
    "CID0": 0xFF0, "CID1": 0xFF4, "CID2": 0xFF8, "CID3": 0xFFC,
}

# Peripheral test points: (name, base_address, expected_pid0, expected_cid)
# PID0 uniquely identifies each peripheral type.
PERIPHERALS = [
    ("timer_0",   0x40000000, 0x22, CMSDK_CID),
    ("timer_1",   0x40001000, 0x22, CMSDK_CID),
    ("dualtimer", 0x40002000, 0x23, CMSDK_CID),
    ("uart_2",    0x40006000, 0x21, CMSDK_CID),
    ("watchdog",  0x40008000, 0x24, CMSDK_CID),
    ("gpio_0",    0x40010000, 0x20, CMSDK_CID),
    ("gpio_1",    0x40011000, 0x20, CMSDK_CID),
    ("sysctrl",   0x4001F000, 0x26, CMSDK_CID),
]

# Writable memory regions for write-read-back testing
# (name, base_address, size_bytes, num_test_words)
MEMORY_REGIONS = [
    ("dmem_0", 0x18000000, 0x4000,   4),
    ("sram_0", 0x80000000, 0x100000, 4),
    ("sram_1", 0x90000000, 0x100000, 4),
]

# Number of random addresses to probe within each memory region
NUM_RANDOM_PROBES = 4


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_peripheral_identity(dut):
    """Verify each peripheral's identity by reading PID/CID registers
    and comparing against values from the register-map model.

    This validates:
      - Debug initiator bus connectivity through the interconnect
      - Address decode to each peripheral target
      - Correct peripheral instantiation (right IP at right address)
    """
    soc = NanoSoC(dut)
    await soc.start()

    failures = []

    for name, base, expected_pid0, expected_cid in PERIPHERALS:
        dut._log.info(f"--- Checking {name} @ 0x{base:08X} ---")

        # Read CID0-CID3
        cid = []
        for reg_name, offset in CID_OFFSETS.items():
            val = await soc.read32(base + offset)
            cid.append(val & 0xFF)

        # Read PID0
        pid0 = (await soc.read32(base + PID_OFFSETS["PID0"])) & 0xFF

        # Check CID
        cid_ok = (cid == expected_cid)
        pid_ok = (pid0 == expected_pid0)

        if cid_ok and pid_ok:
            dut._log.info(
                f"  PASS  CID={[f'0x{c:02X}' for c in cid]}  "
                f"PID0=0x{pid0:02X}"
            )
        else:
            msg = f"  FAIL  {name} @ 0x{base:08X}: "
            if not cid_ok:
                msg += (
                    f"CID={[f'0x{c:02X}' for c in cid]} "
                    f"expected {[f'0x{c:02X}' for c in expected_cid]}  "
                )
            if not pid_ok:
                msg += (
                    f"PID0=0x{pid0:02X} expected 0x{expected_pid0:02X}"
                )
            dut._log.error(msg)
            failures.append(msg)

    assert not failures, (
        f"{len(failures)} peripheral(s) failed identity check:\n"
        + "\n".join(failures)
    )
    dut._log.info(
        f"All {len(PERIPHERALS)} peripheral identity checks PASSED"
    )


@cocotb.test()
async def test_memory_write_read(dut):
    """Write random data to writable memory regions and read it back.

    Tests boundary addresses (base, base+4, top) and random addresses
    within the physical extent of each memory region.

    This validates:
      - Write path through the debug initiator and interconnect
      - Read-back through the same path
      - Memory decode and data integrity
    """
    soc = NanoSoC(dut)
    await soc.start()

    failures = []

    for name, base, size, num_tests in MEMORY_REGIONS:
        dut._log.info(
            f"--- Write-read test: {name} "
            f"[0x{base:08X} - 0x{base + size - 1:08X}] ---"
        )

        # Generate test addresses: boundaries + random
        addrs = [base, base + 4]
        top = (base + size - 4) & 0xFFFFFFFC
        if top > base + 4:
            addrs.append(top)
        for _ in range(NUM_RANDOM_PROBES):
            offset = random.randint(0, (size // 4) - 1) * 4
            addrs.append(base + offset)
        addrs = sorted(set(addrs))

        for addr in addrs:
            write_val = random.getrandbits(32)

            await soc.write32(addr, write_val)
            read_val = await soc.read32(addr)

            if read_val == write_val:
                dut._log.info(
                    f"  PASS  0x{addr:08X}: "
                    f"wrote 0x{write_val:08X} read 0x{read_val:08X}"
                )
            else:
                msg = (
                    f"  FAIL  {name} @ 0x{addr:08X}: "
                    f"wrote 0x{write_val:08X} read 0x{read_val:08X}"
                )
                dut._log.error(msg)
                failures.append(msg)

    assert not failures, (
        f"{len(failures)} memory write-read check(s) failed:\n"
        + "\n".join(failures)
    )
    dut._log.info("All memory write-read checks PASSED")


@cocotb.test()
async def test_address_map_regions(dut):
    """Use the generated Python address map to probe every region visible
    to the debug initiator with a single read, verifying bus connectivity
    and decode across the full address space.

    This is a fast smoke test — it does not check data values, only that
    the read completes without hanging (i.e. the bus responds).
    """
    soc = NanoSoC(dut)
    await soc.start()

    regions = ADDRESS_MAP.get_regions(initiator="debug")
    seen = set()

    dut._log.info(f"Probing {len(regions)} address regions")
    ADDRESS_MAP.print_table(initiator="debug")

    for region in regions:
        if region.target in seen:
            continue
        seen.add(region.target)

        target_meta = TARGETS.get(region.target)
        probe_addr = region.base

        dut._log.info(
            f"  Probing {region.target} @ 0x{probe_addr:08X} "
            f"(type={region.region_type}, access={region.access})"
        )

        val = await soc.read32(probe_addr)
        dut._log.info(f"    Read 0x{val:08X} — bus responded OK")

    dut._log.info(
        f"All {len(seen)} unique targets responded to debug reads"
    )
