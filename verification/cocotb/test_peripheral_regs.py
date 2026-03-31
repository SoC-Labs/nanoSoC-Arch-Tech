#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Peripheral Register Tests
#
# Verifies peripheral register reset values and basic functionality
# using the NanoSoC driver (via HOSTIO4/ADP debug initiator).
#
# Contributors
#   David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2024-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
import random
import cocotb

from nanosoc_cocotb_driver import NanoSoC

# ---------------------------------------------------------------------------
# Peripheral base addresses
# ---------------------------------------------------------------------------
TIMER0_BASE    = 0x40000000
TIMER1_BASE    = 0x40001000
DUALTIMER_BASE = 0x40002000
WATCHDOG_BASE  = 0x40008000
SYSCTRL_BASE   = 0x4001F000
GPIO0_BASE     = 0x40010000
GPIO1_BASE     = 0x40011000
TEST_SLAVE_BASE = 0x4000B000

# ---------------------------------------------------------------------------
# Timer register offsets
# ---------------------------------------------------------------------------
TIMER_CTRL   = 0x000
TIMER_VALUE  = 0x004
TIMER_RELOAD = 0x008

# Dual-timer register offsets
DT_TIMER1_CONTROL = 0x008
DT_TIMER2_CONTROL = 0x028

# Watchdog register offsets
WDOG_LOAD    = 0x000
WDOG_VALUE   = 0x004
WDOG_CONTROL = 0x008
WDOG_LOCK    = 0xC00

# Sysctrl register offsets
REMAP_CTRL = 0x000

# GPIO register offsets
GPIO_DATA      = 0x000
GPIO_DATAOUT   = 0x004
GPIO_OUTENSET  = 0x010
GPIO_OUTENCLR  = 0x014


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_timer_reset_values(dut):
    """PERIPH_001: Verify timer 0 and timer 1 registers are at reset state."""
    soc = NanoSoC(dut)
    await soc.start()

    failures = []

    for name, base in [("timer_0", TIMER0_BASE), ("timer_1", TIMER1_BASE)]:
        for reg_name, offset, expected in [
            ("CTRL",   TIMER_CTRL,   0x00000000),
            ("VALUE",  TIMER_VALUE,  0x00000000),
            ("RELOAD", TIMER_RELOAD, 0x00000000),
        ]:
            val = await soc.read32(base + offset)
            if val != expected:
                msg = (
                    f"{name}.{reg_name} @ 0x{base + offset:08X}: "
                    f"got 0x{val:08X}, expected 0x{expected:08X}"
                )
                dut._log.error(f"  FAIL  {msg}")
                failures.append(msg)
            else:
                dut._log.info(
                    f"  PASS  {name}.{reg_name} = 0x{val:08X}"
                )

    assert not failures, "\n".join(failures)
    dut._log.info("Timer reset values test PASSED")


@cocotb.test()
async def test_timer_countdown(dut):
    """PERIPH_002: Verify timer 0 actually counts down after enable."""
    soc = NanoSoC(dut)
    await soc.start()

    reload_val = 0x0000FFFF

    # Write reload value
    await soc.write32(TIMER0_BASE + TIMER_RELOAD, reload_val)

    # Verify reload was written
    rb = await soc.read32(TIMER0_BASE + TIMER_RELOAD)
    assert rb == reload_val, (
        f"RELOAD write failed: got 0x{rb:08X}, expected 0x{reload_val:08X}"
    )

    # Enable timer (CTRL bit 0 = enable)
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x01)

    # Read VALUE — after enabling, it should have started counting
    # The ADP read takes many clock cycles, so value should have decremented
    value = await soc.read32(TIMER0_BASE + TIMER_VALUE)
    dut._log.info(
        f"Timer VALUE after enable: 0x{value:08X} "
        f"(reload was 0x{reload_val:08X})"
    )
    assert value < reload_val, (
        f"Timer did not count down: VALUE=0x{value:08X} >= "
        f"RELOAD=0x{reload_val:08X}"
    )

    # Disable timer
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x00)

    dut._log.info("Timer countdown test PASSED")


@cocotb.test()
async def test_dualtimer_reset_values(dut):
    """PERIPH_003: Verify dual-timer control registers are at reset value 0x20."""
    soc = NanoSoC(dut)
    await soc.start()

    failures = []

    for reg_name, offset, expected in [
        ("Timer1Control", DT_TIMER1_CONTROL, 0x20),
        ("Timer2Control", DT_TIMER2_CONTROL, 0x20),
    ]:
        val = await soc.read32(DUALTIMER_BASE + offset)
        if val != expected:
            msg = (
                f"dualtimer.{reg_name} @ 0x{DUALTIMER_BASE + offset:08X}: "
                f"got 0x{val:08X}, expected 0x{expected:08X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(
                f"  PASS  dualtimer.{reg_name} = 0x{val:08X}"
            )

    assert not failures, "\n".join(failures)
    dut._log.info("Dual-timer reset values test PASSED")


@cocotb.test()
async def test_watchdog_identity(dut):
    """PERIPH_004: Verify watchdog lock register and lock/unlock mechanism."""
    soc = NanoSoC(dut)
    await soc.start()

    UNLOCK_KEY = 0x1ACCE551

    # After reset, WDOGLOCK should be 0 (unlocked)
    lock_val = await soc.read32(WATCHDOG_BASE + WDOG_LOCK)
    dut._log.info(f"WDOGLOCK after reset: 0x{lock_val:08X}")
    assert lock_val == 0, (
        f"WDOGLOCK should be 0 (unlocked) after reset, got 0x{lock_val:08X}"
    )

    # Lock the watchdog (write anything except the unlock key)
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, 0x00000001)
    lock_val = await soc.read32(WATCHDOG_BASE + WDOG_LOCK)
    dut._log.info(f"WDOGLOCK after lock: 0x{lock_val:08X}")
    assert lock_val == 1, (
        f"WDOGLOCK should be 1 (locked), got 0x{lock_val:08X}"
    )

    # Unlock the watchdog
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, UNLOCK_KEY)
    lock_val = await soc.read32(WATCHDOG_BASE + WDOG_LOCK)
    dut._log.info(f"WDOGLOCK after unlock: 0x{lock_val:08X}")
    assert lock_val == 0, (
        f"WDOGLOCK should be 0 (unlocked) after key, got 0x{lock_val:08X}"
    )

    dut._log.info("Watchdog lock test PASSED")


@cocotb.test()
async def test_sysctrl_remap(dut):
    """PERIPH_005: Verify REMAP_CTRL changes address 0x00000000 mapping."""
    soc = NanoSoC(dut)
    await soc.start()

    # After boot, remap should be active (bootloader sets REMAP_CTRL=1)
    remap = await soc.read32(SYSCTRL_BASE + REMAP_CTRL)
    dut._log.info(f"REMAP_CTRL after boot: 0x{remap:08X}")

    # Read from address 0 (should be IMEM after remap) and from IMEM alias
    val_at_0 = await soc.read32(0x00000000)
    val_at_imem = await soc.read32(0x10000000)
    dut._log.info(
        f"With remap=1: [0x00000000]=0x{val_at_0:08X}, "
        f"[0x10000000]=0x{val_at_imem:08X}"
    )

    if remap & 0x1:
        # Remap is active — address 0 should match IMEM
        assert val_at_0 == val_at_imem, (
            f"Remap active but 0x00000000 (0x{val_at_0:08X}) != "
            f"0x10000000 (0x{val_at_imem:08X})"
        )
        dut._log.info("  Remap=1: address 0x0 matches IMEM")

    # Clear remap to point address 0 back to bootrom
    await soc.write32(SYSCTRL_BASE + REMAP_CTRL, 0x00000000)
    val_at_0_noremap = await soc.read32(0x00000000)
    val_at_bootrom = await soc.read32(0x08000000)
    dut._log.info(
        f"With remap=0: [0x00000000]=0x{val_at_0_noremap:08X}, "
        f"[0x08000000]=0x{val_at_bootrom:08X}"
    )
    assert val_at_0_noremap == val_at_bootrom, (
        f"Remap cleared but 0x00000000 (0x{val_at_0_noremap:08X}) != "
        f"0x08000000 (0x{val_at_bootrom:08X})"
    )
    dut._log.info("  Remap=0: address 0x0 matches bootrom")

    # Restore remap
    await soc.write32(SYSCTRL_BASE + REMAP_CTRL, 0x00000001)

    dut._log.info("Sysctrl remap test PASSED")


@cocotb.test()
async def test_gpio_data_loopback(dut):
    """PERIPH_006: Write to GPIO DATAOUT and verify DATA register reflects it."""
    soc = NanoSoC(dut)
    await soc.start()

    # Enable some GPIO0 pins as outputs
    await soc.write32(GPIO0_BASE + GPIO_OUTENSET, 0x000000FF)

    # Write a pattern
    test_pattern = 0x000000A5
    await soc.write32(GPIO0_BASE + GPIO_DATAOUT, test_pattern)

    # Read back DATAOUT register (latch value)
    dataout = await soc.read32(GPIO0_BASE + GPIO_DATAOUT)
    dut._log.info(f"GPIO0 DATAOUT: 0x{dataout:08X}")
    assert (dataout & 0xFF) == (test_pattern & 0xFF), (
        f"DATAOUT mismatch: got 0x{dataout:08X}, "
        f"expected low byte 0x{test_pattern & 0xFF:02X}"
    )

    # Clear output enables to restore state
    await soc.write32(GPIO0_BASE + GPIO_OUTENCLR, 0x000000FF)

    dut._log.info("GPIO data loopback test PASSED")


@cocotb.test()
async def test_test_slave_scratchpad(dut):
    """PERIPH_007: Write-read random data to the APB test slave scratchpad."""
    soc = NanoSoC(dut)
    await soc.start()

    NUM_WORDS = 8
    test_data = []

    # Write random values to scratchpad
    for i in range(NUM_WORDS):
        addr = TEST_SLAVE_BASE + (i * 4)
        val = random.getrandbits(32)
        test_data.append((addr, val))
        await soc.write32(addr, val)

    # Read all back and verify
    failures = []
    for addr, expected in test_data:
        got = await soc.read32(addr)
        if got != expected:
            msg = (
                f"@ 0x{addr:08X}: got 0x{got:08X}, "
                f"expected 0x{expected:08X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  0x{addr:08X}: 0x{got:08X}")

    assert not failures, "\n".join(failures)
    dut._log.info("Test slave scratchpad test PASSED")
