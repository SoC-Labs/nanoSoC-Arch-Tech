# nanosoc_dap_hal

Shared CoreSight-DAP register/debug HAL for nanosoc systems, promoted from the
nanosoc-multicore-system GUI HAL so every system shares one implementation.

- `channel.py` — transport-agnostic ABI: `RegRead`, `CoreStatus`, `Channel`,
  `RegisterChannel` (read32/write32/core_status/halt/resume/release_bootgate).
- `swd.py` — `SwdRegisterChannel`: register/debug access over a persistent
  OpenOCD Tcl-RPC server, reading/writing system memory through the DAP's
  AHB-APs (`<dap> apreg` CSW/TAR/DRW) **without** examining or halting a running
  core. Atomic `transaction()` / `raw_session()` for multi-command sequences.

System-specifics are injected, not hard-coded:

```python
from nanosoc_dap_hal import SwdRegisterChannel

# dual-M0+ multicore
chan = SwdRegisterChannel(dap_name="nanosoc.dap", target_prefix="nanosoc",
                          ap_map={"cpu0": 0, "cpu1": 1}, managed_cores=("cpu1",))

# M0+ manager + M4 compute
chan = SwdRegisterChannel(dap_name="compute.dap", target_prefix="compute",
                          ap_map={"cpu0": 0, "compute": 1}, managed_cores=("compute",))
```

Run OpenOCD as a long-lived Tcl server first:

    openocd -f <board>.cfg -c "tcl_port 6666; gdb_port 3333; telnet_port 4444"

Optional probe recovery: pass `usb_reset_cb=callable(serial)->bool` and set
`NANOSOC_USB_RESET_RECOVER=1` to USB-reset a wedged probe (opt-in; disruptive to
a running baked image, so off by default).

Dependency-free (stdlib `asyncio` only); imports on any host without a board.
