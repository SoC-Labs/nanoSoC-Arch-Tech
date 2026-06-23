"""
uart_rx — shared cocotb helper for decoding a CMSDK-UART TX line.

Promoted from nanosoc-multicore-system, where uart_rx_byte()/collect_uart()
were copy-pasted across ~32 test environments. Generalised to take the TXD
signal handle and baud rate as arguments so any nanosoc test (M0+, M4, …) can
`from uart_rx import collect_uart` instead of re-implementing the decode.

LSB-first, 1 start bit, 8 data bits, 1 stop bit, no parity. The bit period is
derived from `baud`; the default 38400 matches the CMSDK debug UART running
against a 100 MHz hclk in the standard nanosoc testbenches.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

from cocotb.triggers import FallingEdge, Timer, with_timeout

UART_BAUD_DEFAULT = 38400


async def uart_rx_byte(txd, baud: int = UART_BAUD_DEFAULT):
    """Capture one byte from a UART TX line (`txd` is a signal handle).

    LSB-first, 1 start / 8 data / 1 stop, no parity. Samples each bit at its
    centre (1.5 bit-times after the start-bit falling edge for bit 0).
    """
    bit_ns = int(1_000_000_000 / baud)
    # Wait for the start bit (falling edge on the idle-high line).
    await FallingEdge(txd)
    # Land in the centre of bit 0.
    await Timer(bit_ns + bit_ns // 2, unit="ns")
    byte = 0
    for i in range(8):
        byte |= (int(txd.value) & 1) << i
        await Timer(bit_ns, unit="ns")
    # Stop bit — not validated; the line just returns to idle.
    return byte


async def collect_uart(txd, target: bytes, baud: int = UART_BAUD_DEFAULT,
                       timeout_us: int = 5000) -> bytes:
    """Collect UART bytes from `txd` until `target` appears, or until timeout.

    Returns the bytes collected so far (which contain `target` on success).
    """
    bit_ns = int(1_000_000_000 / baud)
    buf = bytearray()
    deadline_ns = timeout_us * 1000
    elapsed = 0
    while elapsed < deadline_ns:
        try:
            b = await with_timeout(uart_rx_byte(txd, baud),
                                   deadline_ns - elapsed, "ns")
        except Exception:
            break
        buf.append(b)
        if target in bytes(buf):
            return bytes(buf)
        elapsed += bit_ns * 10
    return bytes(buf)
