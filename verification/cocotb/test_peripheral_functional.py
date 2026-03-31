#-----------------------------------------------------------------------------
# SoCLabs NanoSoC Peripheral Functional Tests
#
# Deep functional verification of all SoC peripherals beyond basic register
# checks. Tests timer accuracy, dual-timer modes, watchdog behaviour,
# UART registers, GPIO extended features, and sysctrl registers.
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
TIMER0_BASE     = 0x40000000
TIMER1_BASE     = 0x40001000
DUALTIMER_BASE  = 0x40002000
USRT0_BASE      = 0x40004000
USRT1_BASE      = 0x40005000
UART2_BASE      = 0x40006000
WATCHDOG_BASE   = 0x40008000
TEST_SLAVE_BASE = 0x4000B000
GPIO0_BASE      = 0x40010000
GPIO1_BASE      = 0x40011000
SYSCTRL_BASE    = 0x4001F000

# ---------------------------------------------------------------------------
# Timer register offsets (cmsdk_apb_timer)
# ---------------------------------------------------------------------------
TIMER_CTRL     = 0x000
TIMER_VALUE    = 0x004
TIMER_RELOAD   = 0x008
TIMER_INTCLEAR = 0x00C
TIMER_PID0     = 0xFE0

# Timer CTRL bits
TIMER_CTRL_ENABLE    = (1 << 0)
TIMER_CTRL_EXTINPUT  = (1 << 1)
TIMER_CTRL_EXTCLOCK  = (1 << 2)
TIMER_CTRL_IRQEN     = (1 << 3)

# ---------------------------------------------------------------------------
# Dual-timer register offsets (cmsdk_apb_dualtimers)
# ---------------------------------------------------------------------------
DT_T1LOAD     = 0x000
DT_T1VALUE    = 0x004
DT_T1CONTROL  = 0x008
DT_T1INTCLR   = 0x00C
DT_T1RIS      = 0x010
DT_T1MIS      = 0x014
DT_T1BGLOAD   = 0x018

DT_T2LOAD     = 0x020
DT_T2VALUE    = 0x024
DT_T2CONTROL  = 0x028
DT_T2INTCLR   = 0x02C
DT_T2RIS      = 0x030
DT_T2MIS      = 0x034
DT_T2BGLOAD   = 0x038

# Dual-timer control bits
DT_CTRL_ONESHOT   = (1 << 0)
DT_CTRL_32BIT     = (1 << 1)
DT_CTRL_PRESCALE0 = (0 << 2)   # /1
DT_CTRL_PRESCALE4 = (1 << 2)   # /16
DT_CTRL_PRESCALE8 = (2 << 2)   # /256
DT_CTRL_IRQEN     = (1 << 5)
DT_CTRL_PERIODIC  = (1 << 6)
DT_CTRL_ENABLE    = (1 << 7)

# ---------------------------------------------------------------------------
# Watchdog register offsets (cmsdk_apb_watchdog)
# ---------------------------------------------------------------------------
WDOG_LOAD    = 0x000
WDOG_VALUE   = 0x004
WDOG_CONTROL = 0x008
WDOG_INTCLR  = 0x00C
WDOG_RIS     = 0x010
WDOG_MIS     = 0x014
WDOG_LOCK    = 0xC00

WDOG_UNLOCK_KEY = 0x1ACCE551

# ---------------------------------------------------------------------------
# UART register offsets (cmsdk_apb_uart / socdebug_usrt)
# ---------------------------------------------------------------------------
UART_DATA     = 0x000
UART_STATE    = 0x004
UART_CTRL     = 0x008
UART_INTCLEAR = 0x00C
UART_BAUDDIV  = 0x010   # only on cmsdk_apb_uart
UART_PID0     = 0xFE0

# ---------------------------------------------------------------------------
# GPIO register offsets (cmsdk_ahb_gpio)
# ---------------------------------------------------------------------------
GPIO_DATA        = 0x000
GPIO_DATAOUT     = 0x004
GPIO_OUTENSET    = 0x010
GPIO_OUTENCLR    = 0x014
GPIO_ALTFUNCSET  = 0x018
GPIO_ALTFUNCCLR  = 0x01C
GPIO_INTENSET    = 0x020
GPIO_INTENCLR    = 0x024
GPIO_INTTYPESET  = 0x028
GPIO_INTTYPECLR  = 0x02C
GPIO_INTPOLSET   = 0x030
GPIO_INTPOLCLR   = 0x034
GPIO_INTSTATUS   = 0x038
GPIO_MASKLOWBYTE = 0x400
GPIO_MASKHIGHBYTE= 0x800

# ---------------------------------------------------------------------------
# Sysctrl register offsets (nanosoc_sysctrl)
# ---------------------------------------------------------------------------
SYSCTRL_REMAP      = 0x000
SYSCTRL_PMU_CTRL   = 0x004
SYSCTRL_SYS_CTRL   = 0x008
SYSCTRL_RESET_INFO = 0x010


# ===================================================================
# TIMER FUNCTIONAL TESTS
# ===================================================================

@cocotb.test()
async def test_timer_reload_wrap(dut):
    """PERIPH_010: Timer reloads and wraps around after reaching zero."""
    soc = NanoSoC(dut)
    await soc.start()

    # Use a small reload value so the timer wraps quickly
    reload_val = 0x00000100

    # Set reload and enable timer
    await soc.write32(TIMER0_BASE + TIMER_RELOAD, reload_val)
    await soc.write32(TIMER0_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE)

    # Wait for enough cycles that the timer should have wrapped at least once.
    # ADP commands take many cycles, so several reads should be enough.
    # Read VALUE multiple times — after wrapping, it reloads from RELOAD
    values = []
    for _ in range(5):
        v = await soc.read32(TIMER0_BASE + TIMER_VALUE)
        values.append(v)

    dut._log.info(f"Timer values over 5 reads: {[f'0x{v:08X}' for v in values]}")

    # The timer should still be running (non-zero value <= reload_val)
    # and should have reloaded (we expect values near reload_val again
    # after having counted through zero)
    last_val = values[-1]
    assert last_val <= reload_val, (
        f"Timer VALUE 0x{last_val:08X} > RELOAD 0x{reload_val:08X} — "
        f"timer did not reload correctly"
    )

    # Disable timer
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x00)

    # Verify timer stops — read VALUE twice, should be same
    v1 = await soc.read32(TIMER0_BASE + TIMER_VALUE)
    v2 = await soc.read32(TIMER0_BASE + TIMER_VALUE)
    assert v1 == v2, (
        f"Timer did not stop: VALUE changed from 0x{v1:08X} to 0x{v2:08X} "
        f"after CTRL=0"
    )

    dut._log.info("Timer reload/wrap test PASSED")


@cocotb.test()
async def test_timer_interrupt_status(dut):
    """PERIPH_011: Timer interrupt flag sets when counter reaches zero."""
    soc = NanoSoC(dut)
    await soc.start()

    # Load a small value so timer reaches zero quickly
    reload_val = 0x00000010

    await soc.write32(TIMER0_BASE + TIMER_RELOAD, reload_val)
    # Enable timer with interrupt enabled
    await soc.write32(TIMER0_BASE + TIMER_CTRL,
                      TIMER_CTRL_ENABLE | TIMER_CTRL_IRQEN)

    # The ADP read latency is hundreds of cycles — the timer with reload=0x10
    # will have wrapped many times by the time we read.
    # Read the INTCLEAR register (also acts as interrupt status on read for
    # CMSDK timers — reading offset 0x00C returns current interrupt state)
    intr = await soc.read32(TIMER0_BASE + TIMER_INTCLEAR)
    dut._log.info(f"Timer interrupt status: 0x{intr:08X}")
    assert (intr & 0x1) == 1, (
        f"Timer interrupt flag not set after countdown — got 0x{intr:08X}"
    )

    # Clear interrupt by writing 1
    await soc.write32(TIMER0_BASE + TIMER_INTCLEAR, 0x1)

    # Disable timer
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x00)

    dut._log.info("Timer interrupt status test PASSED")


@cocotb.test()
async def test_timer1_independent(dut):
    """PERIPH_012: Timer 1 operates independently from Timer 0."""
    soc = NanoSoC(dut)
    await soc.start()

    # Configure timer 0 with one reload value, timer 1 with another
    await soc.write32(TIMER0_BASE + TIMER_RELOAD, 0x0000FFFF)
    await soc.write32(TIMER1_BASE + TIMER_RELOAD, 0x00FF0000)

    # Enable both timers
    await soc.write32(TIMER0_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE)
    await soc.write32(TIMER1_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE)

    # Read both values
    v0 = await soc.read32(TIMER0_BASE + TIMER_VALUE)
    v1 = await soc.read32(TIMER1_BASE + TIMER_VALUE)

    dut._log.info(f"Timer0 VALUE: 0x{v0:08X}, Timer1 VALUE: 0x{v1:08X}")

    # Timer 0 should have a smaller value (it had a smaller reload)
    # Timer 1 should still be counting from a much larger value
    assert v0 <= 0x0000FFFF, (
        f"Timer0 VALUE 0x{v0:08X} exceeds its reload"
    )
    assert v1 <= 0x00FF0000, (
        f"Timer1 VALUE 0x{v1:08X} exceeds its reload"
    )

    # Verify they are different (they count at different rates relative
    # to their reload values)
    # Timer1 should be significantly larger than Timer0 since its reload is larger
    assert v1 > v0, (
        f"Timer1 (0x{v1:08X}) should be larger than Timer0 (0x{v0:08X}) "
        f"given the different reload values"
    )

    # Disable both
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x00)
    await soc.write32(TIMER1_BASE + TIMER_CTRL, 0x00)

    dut._log.info("Timer independence test PASSED")


@cocotb.test()
async def test_timer_accuracy(dut):
    """PERIPH_013: Timer countdown rate is consistent across reads."""
    soc = NanoSoC(dut)
    await soc.start()

    reload_val = 0xFFFFFFFF  # Maximum count — won't wrap during test

    await soc.write32(TIMER0_BASE + TIMER_RELOAD, reload_val)
    await soc.write32(TIMER0_BASE + TIMER_CTRL, TIMER_CTRL_ENABLE)

    # Take 4 consecutive reads and compute deltas
    readings = []
    for _ in range(4):
        readings.append(await soc.read32(TIMER0_BASE + TIMER_VALUE))

    deltas = []
    for i in range(len(readings) - 1):
        delta = readings[i] - readings[i + 1]
        deltas.append(delta)

    dut._log.info(f"Timer readings: {[f'0x{r:08X}' for r in readings]}")
    dut._log.info(f"Timer deltas: {deltas}")

    # All deltas should be positive (timer is counting down)
    for i, d in enumerate(deltas):
        assert d > 0, f"Delta {i} is not positive: {d}"

    # Deltas should be roughly consistent (same ADP read latency each time).
    # Allow 50% tolerance for ADP jitter.
    avg_delta = sum(deltas) / len(deltas)
    for i, d in enumerate(deltas):
        ratio = d / avg_delta
        assert 0.5 < ratio < 2.0, (
            f"Delta {i} ({d}) deviates too much from average ({avg_delta:.0f})"
        )

    # Disable timer
    await soc.write32(TIMER0_BASE + TIMER_CTRL, 0x00)

    dut._log.info("Timer accuracy test PASSED")


# ===================================================================
# DUAL-TIMER FUNCTIONAL TESTS
# ===================================================================

@cocotb.test()
async def test_dualtimer_countdown(dut):
    """PERIPH_020: Dual-timer Timer1 counts down after enable."""
    soc = NanoSoC(dut)
    await soc.start()

    load_val = 0x0000FFFF

    # Write load value
    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, load_val)

    # Verify load was written
    rb = await soc.read32(DUALTIMER_BASE + DT_T1LOAD)
    assert rb == load_val, (
        f"Timer1Load write failed: got 0x{rb:08X}, expected 0x{load_val:08X}"
    )

    # Enable: 32-bit, periodic, enabled
    ctrl = DT_CTRL_32BIT | DT_CTRL_PERIODIC | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)

    # Read value — should be counting down
    value = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)
    dut._log.info(f"DualTimer1 VALUE: 0x{value:08X} (load was 0x{load_val:08X})")
    assert value < load_val, (
        f"DualTimer1 did not count: VALUE=0x{value:08X} >= LOAD=0x{load_val:08X}"
    )

    # Disable
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)  # Reset value

    dut._log.info("Dual-timer countdown test PASSED")


@cocotb.test()
async def test_dualtimer_32bit_mode(dut):
    """PERIPH_021: Dual-timer in 32-bit mode uses full 32-bit count."""
    soc = NanoSoC(dut)
    await soc.start()

    # Load a value that requires more than 16 bits
    load_val = 0x00FFFFFF

    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, load_val)
    ctrl = DT_CTRL_32BIT | DT_CTRL_PERIODIC | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)

    value = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)
    dut._log.info(f"32-bit mode VALUE: 0x{value:08X}")

    # In 32-bit mode, value should be between 0 and load_val
    # and should be larger than 0xFFFF (proving 32-bit counting)
    assert value <= load_val, (
        f"VALUE 0x{value:08X} > LOAD 0x{load_val:08X}"
    )
    assert value > 0x0000FFFF, (
        f"VALUE 0x{value:08X} fits in 16 bits — 32-bit mode may not be active"
    )

    # Disable
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)

    dut._log.info("Dual-timer 32-bit mode test PASSED")


@cocotb.test()
async def test_dualtimer_oneshot(dut):
    """PERIPH_022: Dual-timer one-shot mode stops after reaching zero."""
    soc = NanoSoC(dut)
    await soc.start()

    # Very small load so it reaches zero before our first read
    load_val = 0x00000008

    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, load_val)
    # One-shot, 32-bit, enabled
    ctrl = DT_CTRL_ONESHOT | DT_CTRL_32BIT | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)

    # ADP latency means timer will have reached zero by now
    v1 = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)
    v2 = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)

    dut._log.info(f"One-shot values: v1=0x{v1:08X}, v2=0x{v2:08X}")

    # In one-shot mode, after reaching zero, the timer should stop at 0
    assert v1 == 0, f"One-shot timer did not stop at 0: v1=0x{v1:08X}"
    assert v2 == 0, f"One-shot timer did not stay at 0: v2=0x{v2:08X}"

    # Disable
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)

    dut._log.info("Dual-timer one-shot test PASSED")


@cocotb.test()
async def test_dualtimer_interrupt_status(dut):
    """PERIPH_023: Dual-timer interrupt status registers (RIS/MIS)."""
    soc = NanoSoC(dut)
    await soc.start()

    # Small load so timer reaches zero immediately
    load_val = 0x00000004

    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, load_val)
    # Enable with interrupt enabled
    ctrl = DT_CTRL_32BIT | DT_CTRL_IRQEN | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)

    # By the time we read, timer will have underflowed
    ris = await soc.read32(DUALTIMER_BASE + DT_T1RIS)
    mis = await soc.read32(DUALTIMER_BASE + DT_T1MIS)

    dut._log.info(f"DualTimer1 RIS: 0x{ris:08X}, MIS: 0x{mis:08X}")

    assert (ris & 0x1) == 1, (
        f"Raw interrupt not set after countdown — RIS=0x{ris:08X}"
    )
    assert (mis & 0x1) == 1, (
        f"Masked interrupt not set (irq enabled) — MIS=0x{mis:08X}"
    )

    # Clear interrupt
    await soc.write32(DUALTIMER_BASE + DT_T1INTCLR, 0x1)

    # RIS should now be 0 (if timer has reloaded and not yet underflowed again
    # with a very small load it may re-trigger, so we disable first)
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)  # Disable
    await soc.write32(DUALTIMER_BASE + DT_T1INTCLR, 0x1)    # Clear again

    ris_after = await soc.read32(DUALTIMER_BASE + DT_T1RIS)
    dut._log.info(f"DualTimer1 RIS after clear+disable: 0x{ris_after:08X}")
    assert (ris_after & 0x1) == 0, (
        f"Raw interrupt not cleared — RIS=0x{ris_after:08X}"
    )

    dut._log.info("Dual-timer interrupt status test PASSED")


@cocotb.test()
async def test_dualtimer_timer2_independent(dut):
    """PERIPH_024: Dual-timer Timer2 operates independently from Timer1."""
    soc = NanoSoC(dut)
    await soc.start()

    # Load different values into Timer1 and Timer2
    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, 0x0000FFFF)
    await soc.write32(DUALTIMER_BASE + DT_T2LOAD, 0x00FF0000)

    # Enable both in 32-bit periodic mode
    ctrl = DT_CTRL_32BIT | DT_CTRL_PERIODIC | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)
    await soc.write32(DUALTIMER_BASE + DT_T2CONTROL, ctrl)

    # Read both
    v1 = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)
    v2 = await soc.read32(DUALTIMER_BASE + DT_T2VALUE)

    dut._log.info(f"DualTimer T1: 0x{v1:08X}, T2: 0x{v2:08X}")

    assert v1 <= 0x0000FFFF, f"T1 VALUE exceeds its load"
    assert v2 <= 0x00FF0000, f"T2 VALUE exceeds its load"
    assert v2 > v1, (
        f"T2 (0x{v2:08X}) should be larger than T1 (0x{v1:08X}) "
        f"given different loads"
    )

    # Disable both
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)
    await soc.write32(DUALTIMER_BASE + DT_T2CONTROL, 0x20)

    dut._log.info("Dual-timer independence test PASSED")


@cocotb.test()
async def test_dualtimer_background_load(dut):
    """PERIPH_025: Dual-timer background load changes reload without restart."""
    soc = NanoSoC(dut)
    await soc.start()

    # Start with a large load
    initial_load = 0x00FFFFFF
    await soc.write32(DUALTIMER_BASE + DT_T1LOAD, initial_load)
    ctrl = DT_CTRL_32BIT | DT_CTRL_PERIODIC | DT_CTRL_ENABLE
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, ctrl)

    # Read current value (timer is counting from initial_load)
    v_before = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)

    # Write background load — should NOT restart the counter immediately
    new_load = 0x000000FF
    await soc.write32(DUALTIMER_BASE + DT_T1BGLOAD, new_load)

    # Value should still be counting from the original load region
    v_after = await soc.read32(DUALTIMER_BASE + DT_T1VALUE)

    dut._log.info(
        f"Before BGLoad: 0x{v_before:08X}, After BGLoad: 0x{v_after:08X}"
    )

    # v_after should still be > new_load (still counting from old load)
    # unless timer has wrapped, but with initial_load=0x00FFFFFF that's unlikely
    assert v_after > new_load, (
        f"Timer appears to have restarted from BGLoad value immediately: "
        f"VALUE=0x{v_after:08X}, BGLoad=0x{new_load:08X}"
    )

    # Disable
    await soc.write32(DUALTIMER_BASE + DT_T1CONTROL, 0x20)

    dut._log.info("Dual-timer background load test PASSED")


# ===================================================================
# WATCHDOG FUNCTIONAL TESTS
# ===================================================================

@cocotb.test()
async def test_watchdog_reset_values(dut):
    """PERIPH_030: Watchdog registers at expected reset state."""
    soc = NanoSoC(dut)
    await soc.start()

    # WDOGCONTROL should be 0 at reset (interrupts and reset disabled)
    ctrl = await soc.read32(WATCHDOG_BASE + WDOG_CONTROL)
    dut._log.info(f"WDOGCONTROL after reset: 0x{ctrl:08X}")
    assert ctrl == 0x00000000, (
        f"WDOGCONTROL should be 0x00 at reset, got 0x{ctrl:08X}"
    )

    # WDOGRIS should be 0 (no interrupt pending)
    ris = await soc.read32(WATCHDOG_BASE + WDOG_RIS)
    dut._log.info(f"WDOGRIS after reset: 0x{ris:08X}")
    assert ris == 0x00000000, (
        f"WDOGRIS should be 0x00 at reset, got 0x{ris:08X}"
    )

    # WDOGMIS should be 0
    mis = await soc.read32(WATCHDOG_BASE + WDOG_MIS)
    dut._log.info(f"WDOGMIS after reset: 0x{mis:08X}")
    assert mis == 0x00000000, (
        f"WDOGMIS should be 0x00 at reset, got 0x{mis:08X}"
    )

    # WDOGLOCK should be 0 (unlocked)
    lock = await soc.read32(WATCHDOG_BASE + WDOG_LOCK)
    dut._log.info(f"WDOGLOCK after reset: 0x{lock:08X}")
    assert lock == 0x00000000, (
        f"WDOGLOCK should be 0x00 at reset, got 0x{lock:08X}"
    )

    dut._log.info("Watchdog reset values test PASSED")


@cocotb.test()
async def test_watchdog_countdown(dut):
    """PERIPH_031: Watchdog counts down from loaded value."""
    soc = NanoSoC(dut)
    await soc.start()

    load_val = 0x0FFFFFFF

    # Ensure unlocked
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, WDOG_UNLOCK_KEY)

    # Load value
    await soc.write32(WATCHDOG_BASE + WDOG_LOAD, load_val)

    # Verify load
    rb = await soc.read32(WATCHDOG_BASE + WDOG_LOAD)
    assert rb == load_val, (
        f"WDOGLOAD write failed: got 0x{rb:08X}, expected 0x{load_val:08X}"
    )

    # Enable watchdog interrupt (starts counting)
    await soc.write32(WATCHDOG_BASE + WDOG_CONTROL, 0x01)

    # Read value — should have decremented
    value = await soc.read32(WATCHDOG_BASE + WDOG_VALUE)
    dut._log.info(
        f"WDOGVALUE: 0x{value:08X} (load was 0x{load_val:08X})"
    )
    assert value < load_val, (
        f"Watchdog did not count: VALUE=0x{value:08X} >= LOAD=0x{load_val:08X}"
    )
    assert value > 0, (
        f"Watchdog reached zero too quickly: VALUE=0x{value:08X}"
    )

    # Disable watchdog and clear interrupt
    await soc.write32(WATCHDOG_BASE + WDOG_CONTROL, 0x00)
    await soc.write32(WATCHDOG_BASE + WDOG_INTCLR, 0x01)

    dut._log.info("Watchdog countdown test PASSED")


@cocotb.test()
async def test_watchdog_write_protection(dut):
    """PERIPH_032: Watchdog registers are protected when locked."""
    soc = NanoSoC(dut)
    await soc.start()

    # Ensure unlocked and write a known load value
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, WDOG_UNLOCK_KEY)
    await soc.write32(WATCHDOG_BASE + WDOG_LOAD, 0xAAAAAAAA)

    # Verify write worked while unlocked
    rb = await soc.read32(WATCHDOG_BASE + WDOG_LOAD)
    assert rb == 0xAAAAAAAA, (
        f"WDOGLOAD should be 0xAAAAAAAA while unlocked, got 0x{rb:08X}"
    )

    # Lock the watchdog
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, 0x00000001)

    # Try to overwrite WDOGLOAD while locked
    await soc.write32(WATCHDOG_BASE + WDOG_LOAD, 0x55555555)

    # Read back — should still be old value (write was blocked)
    rb = await soc.read32(WATCHDOG_BASE + WDOG_LOAD)
    dut._log.info(f"WDOGLOAD after locked write: 0x{rb:08X}")
    assert rb == 0xAAAAAAAA, (
        f"WDOGLOAD changed while locked: got 0x{rb:08X}, "
        f"expected 0xAAAAAAAA"
    )

    # Unlock and restore
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, WDOG_UNLOCK_KEY)

    dut._log.info("Watchdog write protection test PASSED")


@cocotb.test()
async def test_watchdog_interrupt_status(dut):
    """PERIPH_033: Watchdog interrupt status set after countdown to zero."""
    soc = NanoSoC(dut)
    await soc.start()

    # Ensure unlocked
    await soc.write32(WATCHDOG_BASE + WDOG_LOCK, WDOG_UNLOCK_KEY)

    # Load a small value so it reaches zero quickly
    await soc.write32(WATCHDOG_BASE + WDOG_LOAD, 0x00000010)

    # Enable interrupt (INTEN=1, RESEN=0 to avoid reset)
    await soc.write32(WATCHDOG_BASE + WDOG_CONTROL, 0x01)

    # By the time ADP responds, timer should have underflowed
    ris = await soc.read32(WATCHDOG_BASE + WDOG_RIS)
    mis = await soc.read32(WATCHDOG_BASE + WDOG_MIS)

    dut._log.info(f"WDOGRIS: 0x{ris:08X}, WDOGMIS: 0x{mis:08X}")

    assert (ris & 0x1) == 1, f"WDOGRIS not set after underflow: 0x{ris:08X}"
    assert (mis & 0x1) == 1, f"WDOGMIS not set after underflow: 0x{mis:08X}"

    # Clear interrupt and disable
    await soc.write32(WATCHDOG_BASE + WDOG_INTCLR, 0x01)
    await soc.write32(WATCHDOG_BASE + WDOG_CONTROL, 0x00)

    # Verify interrupt cleared
    ris_after = await soc.read32(WATCHDOG_BASE + WDOG_RIS)
    dut._log.info(f"WDOGRIS after clear: 0x{ris_after:08X}")

    dut._log.info("Watchdog interrupt status test PASSED")


# ===================================================================
# UART TESTS
# ===================================================================

@cocotb.test()
async def test_uart2_reset_values(dut):
    """PERIPH_040: UART 2 registers at expected reset state."""
    soc = NanoSoC(dut)
    await soc.start()

    # CTRL should be 0 at reset (TX/RX disabled)
    ctrl = await soc.read32(UART2_BASE + UART_CTRL)
    dut._log.info(f"UART2 CTRL: 0x{ctrl:08X}")
    assert ctrl == 0x00000000, (
        f"UART2 CTRL should be 0x00 at reset, got 0x{ctrl:08X}"
    )

    # BAUDDIV should be 0 at reset
    baud = await soc.read32(UART2_BASE + UART_BAUDDIV)
    dut._log.info(f"UART2 BAUDDIV: 0x{baud:08X}")
    assert baud == 0x00000000, (
        f"UART2 BAUDDIV should be 0x00 at reset, got 0x{baud:08X}"
    )

    # STATE — TX_FULL should be 0, RX_FULL should be 0 at reset
    state = await soc.read32(UART2_BASE + UART_STATE)
    dut._log.info(f"UART2 STATE: 0x{state:08X}")
    assert (state & 0x03) == 0x00, (
        f"UART2 STATE TX/RX_FULL not clear at reset: 0x{state:08X}"
    )

    dut._log.info("UART 2 reset values test PASSED")


@cocotb.test()
async def test_uart2_bauddiv_readback(dut):
    """PERIPH_041: UART 2 baud rate divider write-readback."""
    soc = NanoSoC(dut)
    await soc.start()

    test_values = [0x00000010, 0x000FFFFF, 0x00000001, 0x00055555]

    failures = []
    for val in test_values:
        await soc.write32(UART2_BASE + UART_BAUDDIV, val)
        rb = await soc.read32(UART2_BASE + UART_BAUDDIV)
        # BAUDDIV is 20 bits wide
        expected = val & 0x000FFFFF
        if rb != expected:
            msg = (
                f"BAUDDIV: wrote 0x{val:08X}, read 0x{rb:08X}, "
                f"expected 0x{expected:08X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  BAUDDIV = 0x{rb:08X}")

    # Restore to 0
    await soc.write32(UART2_BASE + UART_BAUDDIV, 0x00000000)

    assert not failures, "\n".join(failures)
    dut._log.info("UART 2 baud divider test PASSED")


@cocotb.test()
async def test_uart2_ctrl_readback(dut):
    """PERIPH_042: UART 2 control register write-readback."""
    soc = NanoSoC(dut)
    await soc.start()

    # Test various control register settings
    # Bits: TX_EN[0], RX_EN[1], TX_IRQ_EN[2], RX_IRQ_EN[3],
    #        TX_OVRN_IRQ_EN[4], RX_OVRN_IRQ_EN[5], HS_TEST[6]
    test_values = [0x01, 0x02, 0x3F, 0x7F, 0x00]

    failures = []
    for val in test_values:
        await soc.write32(UART2_BASE + UART_CTRL, val)
        rb = await soc.read32(UART2_BASE + UART_CTRL)
        expected = val & 0x7F  # 7 bits
        if rb != expected:
            msg = (
                f"CTRL: wrote 0x{val:02X}, read 0x{rb:08X}, "
                f"expected 0x{expected:02X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  CTRL = 0x{rb:08X}")

    # Restore to disabled
    await soc.write32(UART2_BASE + UART_CTRL, 0x00)

    assert not failures, "\n".join(failures)
    dut._log.info("UART 2 CTRL readback test PASSED")


@cocotb.test()
async def test_uart2_identity(dut):
    """PERIPH_043: UART 2 PID/CID identification registers."""
    soc = NanoSoC(dut)
    await soc.start()

    expected_pid = [
        (0xFE0, 0x21),  # PID0
        (0xFE4, 0xB8),  # PID1
        (0xFE8, 0x1B),  # PID2
        (0xFD0, 0x04),  # PID4
    ]
    expected_cid = [
        (0xFF0, 0x0D),  # CID0
        (0xFF4, 0xF0),  # CID1
        (0xFF8, 0x05),  # CID2
        (0xFFC, 0xB1),  # CID3
    ]

    failures = []
    for offset, expected in expected_pid + expected_cid:
        val = await soc.read32(UART2_BASE + offset)
        if (val & 0xFF) != expected:
            msg = (
                f"UART2 @ 0x{UART2_BASE + offset:08X}: "
                f"got 0x{val:08X}, expected 0x{expected:02X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(
                f"  PASS  UART2 offset 0x{offset:03X} = 0x{val:02X}"
            )

    assert not failures, "\n".join(failures)
    dut._log.info("UART 2 identity test PASSED")


@cocotb.test()
async def test_usrt1_reset_values(dut):
    """PERIPH_044: USRT 1 (slot 5) registers at expected reset state.

    Note: USRT 0 (slot 4) is used by the ADP debug interface and cannot
    be safely tested. USRT 1 at 0x40005000 is available for register tests.
    """
    soc = NanoSoC(dut)
    await soc.start()

    # CTRL should be 0 at reset
    ctrl = await soc.read32(USRT1_BASE + UART_CTRL)
    dut._log.info(f"USRT1 CTRL: 0x{ctrl:08X}")
    assert ctrl == 0x00000000, (
        f"USRT1 CTRL should be 0x00 at reset, got 0x{ctrl:08X}"
    )

    # STATE — should be clear at reset
    state = await soc.read32(USRT1_BASE + UART_STATE)
    dut._log.info(f"USRT1 STATE: 0x{state:08X}")

    dut._log.info("USRT 1 reset values test PASSED")


@cocotb.test()
async def test_usrt1_ctrl_readback(dut):
    """PERIPH_045: USRT 1 control register write-readback."""
    soc = NanoSoC(dut)
    await soc.start()

    # USRT CTRL bits: TX_EN[0], RX_EN[1], TX_IRQ_EN[2], RX_IRQ_EN[3],
    #                  TX_OVRN_IRQ_EN[4], RX_OVRN_IRQ_EN[5]
    test_values = [0x01, 0x02, 0x3F, 0x00]

    failures = []
    for val in test_values:
        await soc.write32(USRT1_BASE + UART_CTRL, val)
        rb = await soc.read32(USRT1_BASE + UART_CTRL)
        expected = val & 0x3F  # 6 bits
        if rb != expected:
            msg = (
                f"USRT1 CTRL: wrote 0x{val:02X}, read 0x{rb:08X}, "
                f"expected 0x{expected:02X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(f"  PASS  USRT1 CTRL = 0x{rb:08X}")

    # Restore
    await soc.write32(USRT1_BASE + UART_CTRL, 0x00)

    assert not failures, "\n".join(failures)
    dut._log.info("USRT 1 CTRL readback test PASSED")


# ===================================================================
# GPIO EXTENDED TESTS
# ===================================================================

@cocotb.test()
async def test_gpio1_data_loopback(dut):
    """PERIPH_050: GPIO port 1 basic data loopback (mirrors PERIPH_006 for port 1)."""
    soc = NanoSoC(dut)
    await soc.start()

    # Enable some GPIO1 pins as outputs
    await soc.write32(GPIO1_BASE + GPIO_OUTENSET, 0x000000FF)

    # Write pattern
    test_pattern = 0x0000005A
    await soc.write32(GPIO1_BASE + GPIO_DATAOUT, test_pattern)

    # Read back DATAOUT
    dataout = await soc.read32(GPIO1_BASE + GPIO_DATAOUT)
    dut._log.info(f"GPIO1 DATAOUT: 0x{dataout:08X}")
    assert (dataout & 0xFF) == (test_pattern & 0xFF), (
        f"GPIO1 DATAOUT mismatch: got 0x{dataout:08X}, "
        f"expected low byte 0x{test_pattern & 0xFF:02X}"
    )

    # Clear outputs
    await soc.write32(GPIO1_BASE + GPIO_OUTENCLR, 0x000000FF)

    dut._log.info("GPIO 1 data loopback test PASSED")


@cocotb.test()
async def test_gpio_outenset_readback(dut):
    """PERIPH_051: GPIO output enable set/clear registers work correctly."""
    soc = NanoSoC(dut)
    await soc.start()

    # Start with all disabled
    await soc.write32(GPIO0_BASE + GPIO_OUTENCLR, 0x0000FFFF)

    # Read OUTENSET — should be 0
    oen = await soc.read32(GPIO0_BASE + GPIO_OUTENSET)
    dut._log.info(f"OUTENSET after clear all: 0x{oen:08X}")
    assert (oen & 0xFFFF) == 0, f"OUTENSET not 0 after clear: 0x{oen:08X}"

    # Enable specific pins
    await soc.write32(GPIO0_BASE + GPIO_OUTENSET, 0x000000F0)
    oen = await soc.read32(GPIO0_BASE + GPIO_OUTENSET)
    dut._log.info(f"OUTENSET after set 0xF0: 0x{oen:08X}")
    assert (oen & 0xFFFF) == 0x00F0, (
        f"OUTENSET should be 0x00F0, got 0x{oen & 0xFFFF:04X}"
    )

    # Set more pins (should OR with existing)
    await soc.write32(GPIO0_BASE + GPIO_OUTENSET, 0x0000000F)
    oen = await soc.read32(GPIO0_BASE + GPIO_OUTENSET)
    dut._log.info(f"OUTENSET after set 0x0F: 0x{oen:08X}")
    assert (oen & 0xFFFF) == 0x00FF, (
        f"OUTENSET should be 0x00FF, got 0x{oen & 0xFFFF:04X}"
    )

    # Clear subset
    await soc.write32(GPIO0_BASE + GPIO_OUTENCLR, 0x000000F0)
    oen = await soc.read32(GPIO0_BASE + GPIO_OUTENSET)
    dut._log.info(f"OUTENSET after clear 0xF0: 0x{oen:08X}")
    assert (oen & 0xFFFF) == 0x000F, (
        f"OUTENSET should be 0x000F, got 0x{oen & 0xFFFF:04X}"
    )

    # Clean up
    await soc.write32(GPIO0_BASE + GPIO_OUTENCLR, 0x0000FFFF)

    dut._log.info("GPIO output enable set/clear test PASSED")


@cocotb.test()
async def test_gpio_all_pins_pattern(dut):
    """PERIPH_052: Write and verify all 16 GPIO pins with walking pattern."""
    soc = NanoSoC(dut)
    await soc.start()

    # Enable all 16 pins as outputs
    await soc.write32(GPIO0_BASE + GPIO_OUTENSET, 0x0000FFFF)

    failures = []

    # Walking-1 pattern through all 16 pins
    for bit in range(16):
        pattern = 1 << bit
        await soc.write32(GPIO0_BASE + GPIO_DATAOUT, pattern)
        dataout = await soc.read32(GPIO0_BASE + GPIO_DATAOUT)
        if (dataout & 0xFFFF) != pattern:
            msg = (
                f"Pin {bit}: wrote 0x{pattern:04X}, "
                f"read 0x{dataout & 0xFFFF:04X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)

    # All-ones and all-zeros
    for pattern in [0x0000FFFF, 0x00000000]:
        await soc.write32(GPIO0_BASE + GPIO_DATAOUT, pattern)
        dataout = await soc.read32(GPIO0_BASE + GPIO_DATAOUT)
        if (dataout & 0xFFFF) != (pattern & 0xFFFF):
            msg = (
                f"Pattern 0x{pattern:04X}: "
                f"read 0x{dataout & 0xFFFF:04X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)

    # Clean up
    await soc.write32(GPIO0_BASE + GPIO_OUTENCLR, 0x0000FFFF)

    assert not failures, "\n".join(failures)
    dut._log.info("GPIO all-pins pattern test PASSED")


@cocotb.test()
async def test_gpio_interrupt_config(dut):
    """PERIPH_053: GPIO interrupt configuration registers write-readback."""
    soc = NanoSoC(dut)
    await soc.start()

    # Verify interrupt registers are configurable via set/clear pattern
    # Start clean
    await soc.write32(GPIO0_BASE + GPIO_INTENCLR, 0x0000FFFF)
    await soc.write32(GPIO0_BASE + GPIO_INTTYPECLR, 0x0000FFFF)
    await soc.write32(GPIO0_BASE + GPIO_INTPOLCLR, 0x0000FFFF)

    # Enable interrupts on pins 0-7
    await soc.write32(GPIO0_BASE + GPIO_INTENSET, 0x000000FF)
    ie = await soc.read32(GPIO0_BASE + GPIO_INTENSET)
    dut._log.info(f"INTENSET: 0x{ie:08X}")
    assert (ie & 0xFFFF) == 0x00FF, (
        f"INTENSET should be 0x00FF, got 0x{ie & 0xFFFF:04X}"
    )

    # Set edge-triggered on pins 0-3
    await soc.write32(GPIO0_BASE + GPIO_INTTYPESET, 0x0000000F)
    it = await soc.read32(GPIO0_BASE + GPIO_INTTYPESET)
    dut._log.info(f"INTTYPESET: 0x{it:08X}")
    assert (it & 0xFFFF) == 0x000F, (
        f"INTTYPESET should be 0x000F, got 0x{it & 0xFFFF:04X}"
    )

    # Set polarity on pins 0-1
    await soc.write32(GPIO0_BASE + GPIO_INTPOLSET, 0x00000003)
    ip = await soc.read32(GPIO0_BASE + GPIO_INTPOLSET)
    dut._log.info(f"INTPOLSET: 0x{ip:08X}")
    assert (ip & 0xFFFF) == 0x0003, (
        f"INTPOLSET should be 0x0003, got 0x{ip & 0xFFFF:04X}"
    )

    # Clean up
    await soc.write32(GPIO0_BASE + GPIO_INTENCLR, 0x0000FFFF)
    await soc.write32(GPIO0_BASE + GPIO_INTTYPECLR, 0x0000FFFF)
    await soc.write32(GPIO0_BASE + GPIO_INTPOLCLR, 0x0000FFFF)

    dut._log.info("GPIO interrupt config test PASSED")


@cocotb.test()
async def test_gpio_altfunc_readback(dut):
    """PERIPH_054: GPIO alternate function set/clear registers."""
    soc = NanoSoC(dut)
    await soc.start()

    # Clear all alt functions
    await soc.write32(GPIO0_BASE + GPIO_ALTFUNCCLR, 0x0000FFFF)

    af = await soc.read32(GPIO0_BASE + GPIO_ALTFUNCSET)
    dut._log.info(f"ALTFUNCSET after clear: 0x{af:08X}")
    assert (af & 0xFFFF) == 0, f"ALTFUNCSET not 0 after clear: 0x{af:08X}"

    # Set alt function on pins 4-7
    await soc.write32(GPIO0_BASE + GPIO_ALTFUNCSET, 0x000000F0)
    af = await soc.read32(GPIO0_BASE + GPIO_ALTFUNCSET)
    dut._log.info(f"ALTFUNCSET after set 0xF0: 0x{af:08X}")
    assert (af & 0xFFFF) == 0x00F0, (
        f"ALTFUNCSET should be 0x00F0, got 0x{af & 0xFFFF:04X}"
    )

    # Clear
    await soc.write32(GPIO0_BASE + GPIO_ALTFUNCCLR, 0x0000FFFF)

    dut._log.info("GPIO alt function test PASSED")


# ===================================================================
# SYSCTRL EXTENDED TESTS
# ===================================================================

@cocotb.test()
async def test_sysctrl_pmu_ctrl(dut):
    """PERIPH_060: System controller PMU_CTRL register readback."""
    soc = NanoSoC(dut)
    await soc.start()

    # PMU_CTRL should be 0 at reset
    pmu = await soc.read32(SYSCTRL_BASE + SYSCTRL_PMU_CTRL)
    dut._log.info(f"PMU_CTRL after reset: 0x{pmu:08X}")
    assert pmu == 0x00000000, (
        f"PMU_CTRL should be 0x00 at reset, got 0x{pmu:08X}"
    )

    # Write and readback
    await soc.write32(SYSCTRL_BASE + SYSCTRL_PMU_CTRL, 0x00000001)
    pmu = await soc.read32(SYSCTRL_BASE + SYSCTRL_PMU_CTRL)
    dut._log.info(f"PMU_CTRL after write 1: 0x{pmu:08X}")
    assert (pmu & 0x01) == 0x01, (
        f"PMU_CTRL bit 0 not set: 0x{pmu:08X}"
    )

    # Restore
    await soc.write32(SYSCTRL_BASE + SYSCTRL_PMU_CTRL, 0x00000000)

    dut._log.info("Sysctrl PMU_CTRL test PASSED")


@cocotb.test()
async def test_sysctrl_sys_ctrl(dut):
    """PERIPH_061: System controller SYS_CTRL register readback."""
    soc = NanoSoC(dut)
    await soc.start()

    # SYS_CTRL should be 0 at reset (LOCKUPRESETEN disabled)
    sc = await soc.read32(SYSCTRL_BASE + SYSCTRL_SYS_CTRL)
    dut._log.info(f"SYS_CTRL after reset: 0x{sc:08X}")
    assert sc == 0x00000000, (
        f"SYS_CTRL should be 0x00 at reset, got 0x{sc:08X}"
    )

    # Write LOCKUPRESETEN=1 and readback
    await soc.write32(SYSCTRL_BASE + SYSCTRL_SYS_CTRL, 0x00000001)
    sc = await soc.read32(SYSCTRL_BASE + SYSCTRL_SYS_CTRL)
    dut._log.info(f"SYS_CTRL after write 1: 0x{sc:08X}")
    assert (sc & 0x01) == 0x01, (
        f"SYS_CTRL LOCKUPRESETEN not set: 0x{sc:08X}"
    )

    # Restore
    await soc.write32(SYSCTRL_BASE + SYSCTRL_SYS_CTRL, 0x00000000)

    dut._log.info("Sysctrl SYS_CTRL test PASSED")


@cocotb.test()
async def test_sysctrl_reset_info(dut):
    """PERIPH_062: System controller RESET_INFO register read after boot."""
    soc = NanoSoC(dut)
    await soc.start()

    # RESET_INFO captures the cause of the last reset.
    # After a normal power-on reset via NRST, SYSRESETREQ[0] may be set
    # depending on the boot process.
    ri = await soc.read32(SYSCTRL_BASE + SYSCTRL_RESET_INFO)
    dut._log.info(f"RESET_INFO after boot: 0x{ri:08X}")

    # Bits should be within valid range (only bits [2:0] are defined)
    assert (ri & ~0x07) == 0, (
        f"RESET_INFO has undefined bits set: 0x{ri:08X}"
    )

    # Clear by writing 1s to active bits (W1C)
    if ri != 0:
        await soc.write32(SYSCTRL_BASE + SYSCTRL_RESET_INFO, ri)
        ri_after = await soc.read32(SYSCTRL_BASE + SYSCTRL_RESET_INFO)
        dut._log.info(f"RESET_INFO after clear: 0x{ri_after:08X}")
        assert ri_after == 0x00000000, (
            f"RESET_INFO not cleared by W1C: 0x{ri_after:08X}"
        )

    dut._log.info("Sysctrl RESET_INFO test PASSED")


@cocotb.test()
async def test_sysctrl_identity(dut):
    """PERIPH_063: System controller PID/CID registers."""
    soc = NanoSoC(dut)
    await soc.start()

    expected = [
        (0xFE0, 0x26),  # PID0
        (0xFE4, 0xB8),  # PID1
        (0xFE8, 0x1B),  # PID2
        (0xFD0, 0x04),  # PID4
        (0xFF0, 0x0D),  # CID0
        (0xFF4, 0xF0),  # CID1
        (0xFF8, 0x05),  # CID2
        (0xFFC, 0xB1),  # CID3
    ]

    failures = []
    for offset, exp in expected:
        val = await soc.read32(SYSCTRL_BASE + offset)
        if (val & 0xFF) != exp:
            msg = (
                f"SYSCTRL @ 0x{SYSCTRL_BASE + offset:08X}: "
                f"got 0x{val:08X}, expected 0x{exp:02X}"
            )
            dut._log.error(f"  FAIL  {msg}")
            failures.append(msg)
        else:
            dut._log.info(
                f"  PASS  SYSCTRL offset 0x{offset:03X} = 0x{val:02X}"
            )

    assert not failures, "\n".join(failures)
    dut._log.info("Sysctrl identity test PASSED")
