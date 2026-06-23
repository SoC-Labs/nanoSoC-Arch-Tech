# Copyright 2026, SoC Labs (www.soclabs.org)
"""nanosoc_dap_hal — shared CoreSight-DAP register/debug HAL.

Generic, system-agnostic access to a nanosoc over its CoreSight DAP via a
persistent OpenOCD Tcl-RPC server. System-specifics (DAP name, target prefix,
per-core AP map, boot-gate address) are injected, so the same HAL serves the
dual-M0+ multicore and the M0+/M4 compute system.

    from nanosoc_dap_hal import SwdRegisterChannel
    chan = SwdRegisterChannel(dap_name="nanosoc.dap", ap_map={"cpu0": 0, "cpu1": 1})
"""

from nanosoc_dap_hal.channel import (
    Channel,
    CoreStatus,
    RegRead,
    RegisterChannel,
)
from nanosoc_dap_hal.swd import SwdRegisterChannel
from nanosoc_dap_hal.loader import (
    image_words,
    inject_procs,
    launch_imem,
    proc_defs,
)

__all__ = [
    "Channel",
    "RegisterChannel",
    "RegRead",
    "CoreStatus",
    "SwdRegisterChannel",
    "launch_imem",
    "inject_procs",
    "proc_defs",
    "image_words",
]
