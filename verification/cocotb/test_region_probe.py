#-----------------------------------------------------------------------------
# SoCLabs Cocotb Region Probe Test
#
# Reads the generated Python address map and uses the debug controller (ADP)
# to probe each region with base, end, and random addresses to verify
# accessibility via the interconnect.
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import random
import sys
import os
import logging
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink
from adp_cocotb_driver import ADP

# Add the generated address map to the Python path
sys.path.insert(0, os.path.join(
    os.environ.get("SOCLABS_PROJECT_DIR", ""),
    "build", "rtl", "nanosoc_combined_address_map", "address_maps"
))
from nanosoc_address_map import ADDRESS_MAP, TARGETS

CLK_PERIOD = (10, "ns")
NUM_RANDOM_PROBES = 4
INITIATOR = "debug"


# ---------------------------------------------------------------------------
# Shared setup helpers (matching existing test conventions)
# ---------------------------------------------------------------------------

def setup_adp(dut):
    """Initialise ADP driver with AXI-Stream buses."""
    logging.getLogger("cocotb.nanosoc_tb.rxd8").setLevel(logging.WARNING)
    logging.getLogger("cocotb.nanosoc_tb.txd8").setLevel(logging.WARNING)
    adp_sender = AxiStreamSource(
        AxiStreamBus.from_prefix(dut, "txd8"),
        dut.CLK, dut.NRST, reset_active_level=False
    )
    adp_reciever = AxiStreamSink(
        AxiStreamBus.from_prefix(dut, "rxd8"),
        dut.CLK, dut.NRST, reset_active_level=False
    )
    driver = ADP(dut, adp_sender, adp_reciever)
    driver.write8(0x00)
    return driver


@cocotb.coroutine
async def setup_dut(dut):
    """Start clocks, apply reset, return ADP driver."""
    adp = setup_adp(dut)
    cocotb.start_soon(Clock(dut.CLK, *CLK_PERIOD).start())
    dut.NRST.value = 0
    await ClockCycles(dut.CLK, 2)
    dut.NRST.value = 1
    await ClockCycles(dut.CLK, 2)
    return adp


@cocotb.coroutine
async def wait_bootcode(dut, driver):
    """Wait for bootloader to complete (remap to IMEM)."""
    bootcode_last = "** Remap->IMEM0"
    received_str = ""
    while True:
        read_char = await driver.read8()
        received_str += read_char
        if bootcode_last in received_str:
            break
    dut.log.info(received_str)


# ---------------------------------------------------------------------------
# Probe helpers
# ---------------------------------------------------------------------------

async def probe_read(adp, dut, address, region_name):
    """Set the ADP address pointer and perform a single-word read.

    Returns the raw response string from the ADP 'R' command.
    If the read completes, the region is accessible at *address*.
    If the bus hangs, the test will time-out (expected failure).
    """
    addr_str = f"0x{address:08X}"
    dut.log.info(f"  Probing {region_name} @ {addr_str}")
    await adp.command(f'A{addr_str}\n')
    resp = await adp.command('R\n', debug=True)
    dut.log.info(f"    Read response: {resp}")
    return resp


async def probe_write_read(adp, dut, address, region_name):
    """Write a random word, read it back, and check it matches.

    Only use on regions whose access includes 'w' (writable memory).
    """
    addr_str = f"0x{address:08X}"
    write_val = random.getrandbits(32)
    write_hex = format(write_val, '08x')

    dut.log.info(f"  Write-read {region_name} @ {addr_str}  data=0x{write_hex}")

    # Write
    await adp.command(f'A{addr_str}\n')
    await adp.command(f'W0x{write_hex}\n', debug=True)

    # Read back
    await adp.command(f'A{addr_str}\n')
    resp = await adp.command('R\n', debug=True)
    dut.log.info(f"    Read-back response: {resp}")

    # Extract the 8-char hex value from the response
    # Response format (repr'd): '...0xHHHHHHHH...'
    try:
        # Find the hex value in the response
        idx = resp.find('0x')
        if idx == -1:
            idx = resp.find('0X')
        if idx != -1:
            read_hex = resp[idx+2:idx+10].lower()
            assert read_hex == write_hex, \
                f"Write-read mismatch @ {addr_str}: wrote 0x{write_hex}, read 0x{read_hex}"
            dut.log.info(f"    PASS: 0x{write_hex} == 0x{read_hex}")
        else:
            dut.log.warning(f"    Could not parse hex from response: {resp}")
    except (ValueError, IndexError) as e:
        dut.log.warning(f"    Response parse error @ {addr_str}: {e} — {resp}")


def word_align(addr):
    """Round down to 32-bit word boundary."""
    return addr & 0xFFFFFFFC


def generate_probe_addresses(region):
    """Return a list of word-aligned addresses to probe within *region*.

    Generates: base, base+4, top-of-physical (or top-of-aperture), and
    NUM_RANDOM_PROBES random addresses within the physical extent.
    """
    base = region.base
    target_meta = TARGETS.get(region.target)

    # Determine the usable size — physical size if known, else cap at a
    # reasonable window to avoid probing into aliased/empty decode space.
    if target_meta and target_meta.phys_size:
        probe_size = target_meta.phys_size
    else:
        # For peripherals / unknown sizes, probe within first 4 KiB
        probe_size = min(region.aperture, 0x1000)

    addrs = []

    # Low boundary
    addrs.append(base)
    if probe_size > 4:
        addrs.append(base + 4)

    # High boundary (last word in physical extent)
    high = word_align(base + probe_size - 4)
    if high > base:
        addrs.append(high)

    # Random addresses within physical extent
    for _ in range(NUM_RANDOM_PROBES):
        offset = random.randint(0, (probe_size // 4) - 1) * 4
        addrs.append(base + offset)

    # De-duplicate and sort
    addrs = sorted(set(addrs))
    return addrs


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_region_probe_read(dut):
    """Probe every debug-visible region with reads at boundary and random
    addresses to verify bus connectivity and decode."""
    adp = await setup_dut(dut)
    dut.log.info("Setup Complete")
    await wait_bootcode(dut, adp)
    dut.log.info("Bootcode Finished")
    await adp.monitorModeEnter()

    regions = ADDRESS_MAP.get_regions(initiator=INITIATOR)
    seen_targets = set()

    dut.log.info(f"Probing {len(regions)} regions visible to '{INITIATOR}'")
    ADDRESS_MAP.print_table(initiator=INITIATOR)

    for region in regions:
        # Skip duplicate targets (e.g. remap aliases of the same target)
        if region.target in seen_targets:
            dut.log.info(f"Skipping duplicate region for target '{region.target}' "
                         f"@ 0x{region.base:08X}")
            continue
        seen_targets.add(region.target)

        dut.log.info(f"--- Region: {region.target}  "
                     f"[0x{region.base:08X} - 0x{region.end:08X}]  "
                     f"access={region.access} ---")

        probe_addrs = generate_probe_addresses(region)

        for addr in probe_addrs:
            await probe_read(adp, dut, addr, region.target)

    dut.log.info("Region probe (read) test PASSED — all regions accessible")


@cocotb.test()
async def test_region_probe_write_read(dut):
    """Write-read-back test on all writable memory regions visible to the
    debug initiator, at boundary and random addresses."""
    adp = await setup_dut(dut)
    dut.log.info("Setup Complete")
    await wait_bootcode(dut, adp)
    dut.log.info("Bootcode Finished")
    await adp.monitorModeEnter()

    regions = ADDRESS_MAP.get_regions(initiator=INITIATOR)
    seen_targets = set()

    dut.log.info(f"Write-read probing writable regions for '{INITIATOR}'")

    for region in regions:
        if region.target in seen_targets:
            continue
        seen_targets.add(region.target)

        # Only write-read-back on writable memory (not peripherals or ROM)
        target_meta = TARGETS.get(region.target)
        is_writable_memory = (
            region.region_type == 'memory'
            and 'w' in region.access
            and target_meta
            and target_meta.role not in ('bootrom',)
        )

        if not is_writable_memory:
            dut.log.info(f"Skipping non-writable/peripheral region: {region.target}")
            continue

        dut.log.info(f"--- Write-Read Region: {region.target}  "
                     f"[0x{region.base:08X} - 0x{region.end:08X}]  "
                     f"access={region.access} ---")

        probe_addrs = generate_probe_addresses(region)

        for addr in probe_addrs:
            await probe_write_read(adp, dut, addr, region.target)

    dut.log.info("Region probe (write-read) test PASSED — all writable regions verified")
