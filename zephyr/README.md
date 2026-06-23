# Generic Zephyr enablement for nanosoc cores

This directory is the **reusable** Zephyr flow for any nanosoc system — it lives
in `nanosoc_arch_tech` so every system shares one implementation. The
**system‑specific board** (concrete memory map, peripherals, pins) and the
**application** live in the *system* project (e.g. the compute‑system repo), not
here. See `docs/PROJECT_SEPARATION.md` in the system project.

## What is generic (here) vs system‑specific (the system repo)

| Generic — here (`arch_tech/zephyr/`) | System‑specific — system repo |
|---|---|
| SoC **family** skeleton (`soc/arm/nanosoc/`): CM4/CM0+ Kconfig, FPU/MPU selects | the **board** (`boards/arm/<name>/`) + its DTS (concrete RAM/flash/peripheral addresses), `*_defconfig` |
| Generic **DTS fragments** (`dts/*.dtsi`): IPC mailbox, shared‑SRAM, cmsdk‑uart shapes | the application + its prj.conf |
| The **`ipc_service` backend** over the IPC mailbox + shared‑SRAM SPSC ring (`ipc/`) | MCUboot board config + signing keys |
| West/CMake + MCUboot **integration glue** (parameterised) | flash image / boot‑table content |

Rule: if any nanosoc system would reuse it → here. If it encodes *this* SoC's
addresses, peripherals, board, app, or secrets → the system repo.

## Topology (AMP)

The M4 compute core runs Zephyr as the application core; the M0+ manager stays
bare‑metal (boot/clock master, IPC producer). Inter‑core comms reuse the existing
**IPC mailbox** (doorbell) + **shared SRAM** (SPSC ring) via the `ipc_service`
backend in `ipc/` — the one genuinely reusable transport. The OS runs **XiP from
QSPI** (see the system's `BOOT_ARCHITECTURE.md`).

## Build (in a west workspace, on the dev/EDA host)

```bash
west init -l <system-repo>            # the system repo carries west.yml + the board
west update                            # pulls Zephyr + this arch_tech as a module
west build -b <system_board>_cm4 <app> # board defined in the system repo
```
`arch_tech/zephyr/` is consumed as a **Zephyr module** (see `zephyr/module.yml`)
that contributes the SoC family, the DTS fragments, and the IPC backend; the
board + app come from the system repo.

## Status
Skeleton (authored to Zephyr's SoC/board porting model). Not west‑built here — no
SDK/workspace in this environment; build on the dev host. Files are marked with
`TODO(board)` where the system repo must fill concrete values.
