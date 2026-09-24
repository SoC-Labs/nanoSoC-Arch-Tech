# nanoSoC Arch Tech

The shared building blocks of SoC Labs' nanoSoC designs: the RTL, SoC description files,
generator, firmware, testbenches and build flows that every nanoSoC project is assembled from.

This repository does not build a chip on its own. A SoC project adds it as a submodule,
supplies its own configuration, and includes this repository's `makefile`. For a project
that builds without licence-gated Arm IP, start from
[nanoSoC-M0-QuickStart-SoC](https://github.com/SoC-Labs/nanoSoC-M0-QuickStart-SoC).

## Getting the source

```bash
git clone --recurse-submodules https://github.com/SoC-Labs/nanoSoC-Arch-Tech.git
```

This works without credentials. Most submodules are still hosted on `git.soton.ac.uk`,
and all of them can be read anonymously over https.

## How a project uses it

[nanoSoC-M0-QuickStart-SoC](https://github.com/SoC-Labs/nanoSoC-M0-QuickStart-SoC) is the
reference. A project:

1. Adds this repository as a submodule.
2. Exports `SOCLABS_PROJECT_DIR` and `SOCLABS_NANOSOC_ARCH_TECH_DIR` from its `set_env.sh`.
3. Provides `nanosoc.config` and `autoconfig` (toolchain and simulator) at its root.
4. Includes this repository's makefile from its own:
   `include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/makefile`

The flow targets then run from the project root, for example `make sim TESTNAME=hello`,
`make regression`, `make lint_xm` and `make build_fpga`. They live in [`flows/`](flows/).

**The Arm Cortex-M0 core and Corstone-101 (CMSDK) RTL are not in this repository.** By
default the build looks for them under `ARM_IP_LIBRARY_PATH`, your own Arm Academic Access
or Arm Quickstart delivery; `QUICKSTART=yes` selects the Quickstart layout. A project can
set `ARM_CORTEX_M0_DIR` and `ARM_CORSTONE_101_DIR` directly instead.

## Layout

| Path | Contents |
|---|---|
| [`rtl/src/`](rtl/src/) | nanoSoC's own RTL: boot ROM, memories, reset control, SoC peripherals, CoreSight system table, clock and pin-mux control |
| `rtl/flist/` | File lists |
| [`sys_desc/`](sys_desc/) | YAML descriptions of regions, subsystems and register maps, read by the generator |
| `nanosoc_gen/` | The generator (submodule): builds the interconnect, glue RTL, register maps and linker scripts from YAML |
| [`flows/`](flows/) | Make flows: software, simulation, regression, lint, FPGA and ASIC |
| [`firmware/`](firmware/README.md) | Device headers, drivers and test programs, with Make and CMake builds |
| [`verification/`](verification/) | Verilog testbench, cocotb tests and UVM |
| [`fpga/`](fpga/) | FPGA targets (Arm MPS3, PYNQ-Z2, KR260, KV260, ZCU104), OpenOCD configurations, CI harness |
| [`asic/`](asic/) | Per-node ASIC setup for TSMC 65, 28 and 16 nm: pad rings, memory specifications, constraints |
| [`zephyr/`](zephyr/README.md) | Zephyr module: SoC family, device-tree fragments, inter-core IPC backend |
| [`python/nanosoc_dap_hal/`](python/nanosoc_dap_hal/README.md) | CoreSight debug-port register and debug library |
| [`docs/roadmap/`](docs/roadmap/00-overview.md) | Design notes for the generator and flows |

## Submodules

| Path | Contents | Hosted on |
|---|---|---|
| `nanosoc_gen` | SoC generator | git.soton.ac.uk |
| `rtl/coresight_soc400_tech` | Wrapper around Arm CoreSight SoC-400 | [GitHub](https://github.com/SoC-Labs/SoC-Labs-SoC400-Tech) |
| `rtl/socdebug_tech` | SoCDebug controller: system-bus access over FT1248 or USRT | git.soton.ac.uk |
| `rtl/hostio4` | Host I/O controller and target | git.soton.ac.uk |
| `rtl/extio8x4-axis` | EXTIO interface: 4 virtual channels over a 7-pin link | git.soton.ac.uk |
| `rtl/slcorem0_tech` | SoC Labs wrapper around Arm Cortex-M0 | git.soton.ac.uk |
| `rtl/slcorem0p_tech` | SoC Labs wrapper around Arm Cortex-M0+ | git.soton.ac.uk |
| `rtl/sldma230_tech` | SoC Labs wrapper around Arm PL230 DMA | git.soton.ac.uk |
| `rtl/sldma350_tech` | SoC Labs wrapper around Arm DMA-350 | git.soton.ac.uk |
| `rtl/sl_ams_tech` | 8-bit ADC | git.soton.ac.uk |
| `rtl/synopsys_28nm_slm_integration` | Synopsys 28 nm SLM IP integration | git.soton.ac.uk |

## Working on this repository

- Several SoC projects use this repository, including the nanoSoC M0 SoC, the QuickStart
  SoC and the multicore chiplet designs. A commit to `main` reaches each of them at its next
  submodule update. Work on a branch, open a pull request, and keep existing defaults
  unchanged unless a change is meant for every project.
- `main`, and the branches that tapeouts depend on, are protected against force-push and
  deletion. Do not rewrite their history.

## History

Development moved here from `git.soton.ac.uk/soclabs/nanosoc-m0/nanosoc_arch_tech` on
24 September 2026. This repository is now the source of truth. The GitLab copy is being
retired; projects whose submodules still point at it keep working.

## Licence

No licence has been chosen for this repository yet. Each file carries its own copyright
header. Files derived from Arm CMSDK, mostly under `firmware/` with some in the testbench,
RTL and ASIC pad files, carry Arm's copyright notice and remain under Arm's terms.
