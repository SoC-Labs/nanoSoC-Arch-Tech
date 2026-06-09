# 08 — Vivado Block-Diagram Generation with Typed Interconnect Ports

> Add a `nanosoc_gen` backend that emits, from the SoC model, (a) an IP-XACT
> packaging TCL that types the toplevel's clocks/resets/buses/discrete pins as
> Vivado bus interfaces, and (b) an optional `create_bd_*` block-design TCL —
> so an FPGA wrapper that *exposes* AHB/APB/AXI interconnect ports auto-connects
> in Vivado IP Integrator instead of being hand-wired.

---

## 1. Title & summary

This document specifies a new backend (working name `SoCVivadoBdBackend`) plus
a small RTL-wrapper variant in the generator. Together they let the build flow
produce a **packaged Vivado IP** whose clocks, reset, UART *and any promoted
AHB/APB/AXI bus* are correctly typed via IP-XACT bus-interface definitions (SWD,
RMII, MDIO and QSPI stay as standalone pins, as Vivado has no stock bus type for
them — matching the live script), and (optionally) a self-contained
**block-design TCL** that instantiates and address-maps that IP. The source of truth is the existing
`model.Interface` / `model.Interconnect` data and the protocol signal tables in
`backends/protocol_utils.py`, replacing the hand-written
`pynq/vivado_ip/package_nanosoc_multicore_ip.tcl` (the live multicore packaging
script) and the hand-exported board glue
`pynq/targets/pynq-z2/nanosoc_multicore_design.tcl` with generated, model-derived
output.

**System under study.** The artifact this doc targets is the multicore SoC's
live FPGA flow, driven from the **superproject** `pynq/Makefile`
(`package_ip:` line 193 → `synth_only:` line 243 → `build_design:`), which
packages `pynq/vivado_ip/package_nanosoc_multicore_ip.tcl` wrapping
`pynq/vivado_ip/nanosoc_multicore_vivado_wrapper.v` (module
`nanosoc_multicore_vivado_wrapper`, which instantiates `nanosoc_multicore_soc`).
That wrapper's IP-Integrator boundary exposes far more than the legacy
single-core wrapper: two clocks (`sys_fclk` 25 MHz + `rmii_ref_clk` 50 MHz),
`nrst`, a UART bus, plus RMII PHY pins, MDIO, a single CoreSight SoC-400 SWJ-DP
(`swd_*`), QSPI flash (`qspi_*`), and status taps (`eth_irq`, `phc_pps_out`,
`*_lockup_dbg`, …) — see `nanosoc_multicore_vivado_wrapper.v:48-116`. The legacy
single-core `fpga/fpga/vivado_ip/package_nanosoc_ip.tcl` /
`nanosoc_chip_vivado_wrapper.v` (GPIO/UART/SWD only) still exists in
`nanosoc_arch_tech/` and is the smaller, well-commented *pattern* for the
`ipx::` shape — but it is **not** the IP the multicore BD consumes. Both are
described below so the generator can re-emit the live multicore TCL while
borrowing the legacy script's structure.

---

## 2. Status & scope

**Status: greenfield backend, re-emits an existing hand-written TCL.** There is
currently **no FPGA/BD/Vivado backend** in `nanosoc_gen`. Verified:

```
$ grep -rEl 'create_bd|ipx::|block.design|write_bd_tcl' nanosoc_gen/soc_model/
$ echo $?
1            # zero matches anywhere under soc_model/ — no BD/ipx:: backend exists
```

(The grep returns *no* matches; there are no incidental hits in `validator.py`
or `soc_chip.v.j2` either. The conclusion stands purely on the empty result.)

What exists today and is in scope to *generate* instead of hand-maintain:

- `pynq/vivado_ip/package_nanosoc_multicore_ip.tcl` (superproject) — **the live**
  hand-written `ipx::` script that packages `nanosoc_multicore_vivado_wrapper`
  and manually defines the `sys_fclk` clock (STEP 4), the `rmii_ref_clk` clock
  with `FREQ_HZ 50000000` (STEP 5), the `nrst` reset (STEP 6) and the `uart`
  bus (STEP 7); RMII/MDIO/SWD/QSPI/status are deliberately left as standalone
  ports (STEP 8). This is the script our generated TCL must reproduce.
- `pynq/vivado_ip/nanosoc_multicore_vivado_wrapper.v` (superproject) — the RTL
  wrapper (`module nanosoc_multicore_vivado_wrapper`, ports at `:48-116`) whose
  pins those bus interfaces map onto; it instantiates `nanosoc_multicore_soc`.
- `fpga/fpga/vivado_ip/package_nanosoc_ip.tcl` (211 lines, `nanosoc_arch_tech/`)
  and `nanosoc_chip_vivado_wrapper.v` (124 lines) — the **legacy single-core**
  pattern (clk/nrst/gpio0/gpio1/uart bus interfaces, SWD raw). Kept here only as
  the clearest small reference for the `ipx::` shape (§4.1); not the IP the
  multicore BD consumes.

**In scope:**
1. A model-driven **IP-XACT packaging TCL** generator (covers the multicore
   wrapper's clk×2/reset/uart as today, *plus* AHB-Lite/APB/AXI-MM/AXI-Stream
   when those ports are present at the wrapper boundary; GPIO too, for the legacy
   wrapper).
2. A small generator change to **promote selected interconnect interfaces** to
   the FPGA wrapper boundary so there is something to type (today no AHB/APB/AXI
   bus crosses either wrapper boundary — see §4).
3. An **interface-inference rule set** (model `Interface.type`/`direction` →
   Xilinx bus VLNV + abstraction VLNV + per-signal port map), driven from a new
   data table that mirrors `protocol_utils.py`.
4. **Clock/reset association** metadata (`ASSOCIATED_BUSIF`,
   `ASSOCIATED_RESET`, `POLARITY`) derived from the model's clock/reset and bus
   lists.
5. Optional **block-design TCL** emission (`create_bd_design` +
   `create_bd_cell` of the packaged IP + `create_bd_intf_port`/`create_bd_port`
   + `assign_bd_address` from `InterconnectTarget.base/size` + `validate`/`save`).
6. The custom **IP-XACT bus + abstraction definition `.xml`** files for
   AHB-Lite and APB (Vivado ships no native AHB/APB bus type — confirmed below).

**Out of scope (explicitly):**
- Generating the board-level PS7/Zynq-US+ wiring and the `cmsdk_socket`
  pin-mux hierarchy (xlslice/xlconcat/AXI-GPIO). That board glue is not in the
  model. The generated BD targets the *no-PS bare* case and a hook for a
  hand-written board overlay (see §5, §9).
- Re-architecting the backend registry / common base class — assumed handled by
  `02-clean-architecture-adapters-backends.md`. We follow the existing
  hard-wired import + inline-call convention (`__main__.py:19-34`, `:139-313`).
- Changing the ASIC `nanosoc_chip_pads` flow (covered by
  `07-toplevel-wrapper-generation-fpga-asic.md`).

---

## 3. Motivation

The concrete problem, grounded in the FPGA flow today:

1. **The typing is hand-maintained and drift-prone.** The live multicore
   `pynq/vivado_ip/package_nanosoc_multicore_ip.tcl` hand-lists every
   `ipx::add_bus_interface` / `add_port_map` / `physical_name` (STEP 4–7), and
   the legacy `package_nanosoc_ip.tcl` does the same (lines 102-189). The *same*
   signal/width/direction information already lives in the model and in
   `protocol_utils.py`. Two sources of truth that silently disagree — every
   pin-rename in the wrapper must be re-keyed by hand in the TCL.

2. **No interconnect bus crosses the wrapper boundary.** The multicore wrapper
   exposes clk×2 / nrst / UART (typed) plus RMII/MDIO/SWD/QSPI/status as raw
   pins (`nanosoc_multicore_vivado_wrapper.v:48-116`); the legacy wrapper exposes
   only GPIO/UART/SWD/clk/rst (`nanosoc_chip_vivado_wrapper.v:26-49`). In both,
   the AHB bus-matrix and APB are entirely internal. So neither IP can
   participate in IPI auto-connect to AXI infrastructure, and there is no path to
   expose, say, an AHB initiator to a Xilinx AXI BRAM/DMA without a hand-built
   bridge.

3. **Board BD address offsets are typed in TCL, not derived from the model.**
   The board BD `assign_bd_address` offsets (e.g. the legacy
   `targets/pynq_z2/vivado_script/2021_1/nanosoc_design.tcl:869`
   `assign_bd_address -offset 0x41200000 -range 0x00010000 ...`) are hand-typed,
   independent of `InterconnectTarget.base/size` in the model. The exported board
   TCLs are also hand-edited and stale (that same legacy export at `:58` still
   names the design `extio8x4_io`; `:888 #create_root_design ""` is commented
   out).

> **Note — the multicore IP is NOT dead.** The legacy single-core flow had a
> "two IPs that don't line up" problem: the curated
> `nanosoc_chip_vivado_wrapper` IP was built but the board BD instantiated the
> uncurated `soclabs.org:user:nanosoc_chip:1.0` cell
> (`nanosoc_design.tcl:752`), so the typed IP was never consumed. That does
> **not** apply to the multicore system: the live board BD
> `pynq/targets/pynq-z2/nanosoc_multicore_design.tcl:176` instantiates the
> curated IP directly —
> `create_bd_cell -type ip -vlnv soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0 nanosoc_multicore_ip_0`.
> Here the IP *name* is the wrapper module name and `core_revision = 1`
> (`pynq/Makefile:115`, `FPGA_CORE_REV := 1`). The generator must default to
> that identity, not the legacy `nanosoc_chip`/rev-2.

**Why now:** the model already carries everything needed — `Interface.type` /
`direction` / width properties (`model.py:59-101`), `Interconnect` /
`InterconnectTarget.base/size/protocol` (`model.py:154-203`), the flattened
boundary expansion (`protocol_utils.bus_member_names`,
`protocol_utils.py:95-129`), and a working IP-XACT recipe to copy
(`package_nanosoc_multicore_ip.tcl`, with the legacy
`package_nanosoc_ip.tcl` as the smaller annotated reference). The remaining work
is data-plumbing, not invention.

**What good looks like:**
- A new `make` target emits `build_soc/fpga/<top>_package_ip.tcl` + the custom
  bus-def XMLs, and the existing `make -C pynq package_ip` (or a `_gen` sibling)
  sources it so `vivado -mode batch` packages an IP whose clk×2/rst/uart/swd and
  any promoted AHB/APB/AXI ports show up as proper interfaces in IPI.
- For the promoted-bus case, `assign_bd_address` offsets in the generated BD
  match `InterconnectTarget.base/size` exactly — single source of truth.
- The hand `package_nanosoc_multicore_ip.tcl` becomes a generated artifact,
  re-emitted under the *same* `soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0`
  VLNV so the existing multicore board BD picks it up unchanged.

---

## 4. Current state (grounded)

### 4.1a The LIVE multicore IP-XACT script (the one the generator must re-emit)

`pynq/vivado_ip/package_nanosoc_multicore_ip.tcl` is the script actually run by
`make -C pynq package_ip` (`pynq/Makefile:193`), then synthesised by
`synth_only` (`:243`). It packages `nanosoc_multicore_vivado_wrapper` and types,
in order:

- **STEP 3** — strip every auto-inferred bus interface first
  (`foreach bus_if ... ipx::remove_bus_interface ...`), then re-add curated ones.
  We keep this "strip then add" discipline.
- **STEP 4** — `sys_fclk` clock, `interface_mode slave`,
  `bus_type_vlnv xilinx.com:signal:clock:1.0` /
  `abstraction xilinx.com:signal:clock_rtl:1.0`, `physical_name sys_fclk`.
- **STEP 5** — `rmii_ref_clk` clock (same VLNVs) **with `FREQ_HZ 50000000`**
  (lines 120-121) — a 50 MHz second clock the legacy single-clock script never
  had.
- **STEP 6** — `nrst` reset, `physical_name nrst`, active-low.
- **STEP 7** — `uart` bus, `interface_mode master`,
  `xilinx.com:interface:uart_rtl:1.0`, mapping `RxD`→`uart_rxd` /
  `TxD`→`uart_txd` (CPU0 eth-ss UART; CPU1's UART is left as standalone ports).
- **STEP 8** — RMII / MDIO / SWD / QSPI / status / `cpu1_uart_*` /
  `cpu1_wdog_reset` are **deliberately left as standalone ports** (auto-imported
  by `ipx::package_project`).

So the multicore boundary the generator must reproduce is **two typed clocks +
one reset + one UART bus + a large raw-pin tail**, packaged under
`soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0`,
`core_revision = $env(FPGA_CORE_REV)` (= 1, `pynq/Makefile:115`). Note there is
**no GPIO bus** on this wrapper — GPIO typing is exercised only by the legacy
wrapper (§4.1b).

### 4.1b The legacy single-core script (the smaller annotated pattern)

`fpga/fpga/vivado_ip/package_nanosoc_ip.tcl` is the clearest *small* reference
for the `ipx::` shape. Each typed interface follows exactly this form (clock,
lines 102-116):

```tcl
ipx::add_bus_interface clk $core
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 [ipx::get_bus_interfaces clk -of_objects $core]
set_property bus_type_vlnv         xilinx.com:signal:clock:1.0     [ipx::get_bus_interfaces clk -of_objects $core]
set_property interface_mode slave  [ipx::get_bus_interfaces clk -of_objects $core]
ipx::add_port_map CLK [ipx::get_bus_interfaces clk -of_objects $core]
set_property physical_name clk [ipx::get_port_maps CLK -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]
ipx::add_bus_parameter ASSOCIATED_RESET [ipx::get_bus_interfaces clk -of_objects $core]
set_property value nrst [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]
ipx::add_bus_parameter ASSOCIATED_BUSIF [ipx::get_bus_interfaces clk -of_objects $core]
set_property value {} [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]
```

Confirmed VLNVs used (legacy script): clock `xilinx.com:signal:clock_rtl:1.0` /
`...:clock:1.0` (`:103-104`); reset `xilinx.com:signal:reset_rtl:1.0` with
`POLARITY ACTIVE_LOW` (`:122-131`); GPIO `xilinx.com:interface:gpio_rtl:1.0`
mapping `TRI_I/TRI_O/TRI_T` (`:137-149`); UART `xilinx.com:interface:uart_rtl:1.0`
mapping `RxD/TxD` (`:180-189`). **SWD is deliberately left as raw pins** with a
comment that it has "no standard Vivado bus definition" (`:170-174`). The same
VLNVs appear in the multicore script — only the *set* of typed interfaces and the
physical names differ.

`STEP 3` (legacy lines 89-97 / multicore STEP 3) strips all auto-inferred
interfaces first, then re-adds curated ones.

### 4.2 The RTL boundaries that get typed

**Multicore (live):** `nanosoc_multicore_vivado_wrapper.v:48-116` — two clocks
(`sys_fclk`, `rmii_ref_clk`), `nrst`, `uart_rxd/uart_txd`, `cpu1_uart_rxd/txd`,
RMII PHY pins (`phy_rmii_*`), MDIO (`mdio_i/o/t`, `phy_mdc`), SWD
(`swd_clk/swd_dio_i/o/t` — a single SoC-400 SWJ-DP, not per-core pairs), QSPI
(`qspi_sclk/ncs/io_i/o/t`), and status taps (`eth_irq`, `phc_pps_out`,
`sys_hresetn_o`, `*_lockup_dbg`, `cpu1_wdog_reset`, `sys_hclk_dbg`,
`uart_txd_dbg`). The wrapper converts the SoC's active-high `_e` / active-low
`_z` enables to Vivado `_t` tristate convention (`mdio_t = ~md_padoe_o` `:133`,
`swd_dio_t = ~dap_swdoen` `:138`, `qspi_io_t = ~qspi_io_e_int` `:141`). **No
AHB/APB/AXI bus crosses this boundary** — the matrix is internal to
`nanosoc_multicore_soc` (instantiated at `:189`).

**Legacy:** `nanosoc_chip_vivado_wrapper.v:26-49` — only clk/nrst, gpio0/1
(`_tri_i/o/t`), swd (`_clk/_dio_i/_dio_o/_dio_t`), uart (`_rxd/_txd`); same
`_e`/`_z`→`_tri_t` inversion (`:63-72`); matrix internal (`:75-122`).

### 4.3 What the model already knows

- **Interfaces**: `model.Interface` (`model.py:59-101`) has `type` — the
  docstring enumeration at `model.py:63` lists
  `wire, ahb, apb, axis, axis_byte, swd, gpio` — `direction`
  (`in|out|inout|initiator|target|receiver`), `.addr_width`, `.data_width`,
  `.is_input/.is_output/.is_bidirectional`. **`dbg_ahb` is a real, handled type
  too** (`protocol_utils.bus_member_names` `:118-119` and
  `DBGAHB_TARGET_SIGNALS` `:76`), but it is *not* in the `model.py:63` docstring
  enumeration — the inference table must treat `dbg_ahb` from the
  `protocol_utils` tables, not from the model docstring.
- **Boundary expansion**: `protocol_utils.py` has the authoritative per-protocol
  signal tables — `AHB_INITIATOR_SIGNALS` (`:15`), `AHB_TARGET_SIGNALS`
  (`:30`), `AXIS_SIGNALS` (`:47`), `AXIS_BYTE_SIGNALS` (`:56`), `SWD_SIGNALS`
  (`:63`), `DBGAHB_TARGET_SIGNALS` (`:76`), `GPIO_SIGNALS` (`:88`). Each entry
  is `(suffix, direction_from_role, width_expr)`. `bus_member_names(iface)`
  (`:95-129`) reproduces the exact flattened port names the generated RTL uses
  (e.g. `cpu_0_dbgahb_slvaddr`). **This is the precise list a BD emitter needs.**
- **Toplevel boundary builder**: `SoCTopLevelBackend._build_ports`
  (`toplevel.py:125-177`) already expands every iface type into individual
  ports; `_expand_ahb_port` (`:200+`) handles the
  initiator/target/passthrough-initiator boundary forms. The wrapper backend
  reuses this expansion logic (it is the same naming).
- **Interconnect + address map**: `model.Interconnect` (`:193-203`),
  `InterconnectTarget` (`:154-169`, has `base`/`size`/`protocol`/
  `apb_config`/`passthrough`), `InterconnectInitiator` (`:179-190`). The
  `base`/`size` map directly to `assign_bd_address -offset -range`.

### 4.4 The packaging flow that invokes the TCL

`flows/makefile.fpga:99-112` — target `package_nanosoc_ip` exports
`FPGA_COMPONENT_FILELIST`, `FPGA_COMPONENT_LIB`, `FPGA_VENDOR`, `FPGA_CORE_REV`
then runs `vivado -mode batch -source $(VIVADO_IP_DIR)/package_nanosoc_ip.tcl`.
`COMPONENT_TOP ?= nanosoc_chip`, `NANOSOC_VENDOR ?= soclabs.org`,
`NANOSOC_CORE_REV ?= 2` (`:19-23`). We slot the generated TCL into this same
env-var contract so the makefile change is one path swap.

### 4.5 Confirmation: no native Xilinx AHB-Lite/APB bus type

Vivado ships `clock_rtl`, `reset_rtl`, `gpio_rtl`, `uart_rtl`, `aximm_rtl`,
`axis_rtl` — all used in repo BDs — but **no AHB-Lite or APB** abstraction. The
hand script's SWD comment (`package_nanosoc_ip.tcl:170-174`) is the standing
acknowledgement of this gap. So to type AHB/APB ports we must **ship custom
IP-XACT bus + abstraction definition XMLs** (or insert AXI↔AHB bridge IP and
expose AXI instead — see §9 alternatives).

---

## 5. Proposed design

Three cooperating pieces. Each is independently useful.

```
            sys_desc/*.yaml
                  |  (parser -> builder)
                  v
            model.Module (top)  ── interfaces, interconnects, clocks, resets
                  |
   ┌──────────────┼───────────────────────────────────────────┐
   |              |                                             |
   v              v                                             v
 (A) RTL       (B) bus-iface inference          (C) BD emission
 wrapper       table: model type/dir -> Xilinx  (create_bd_design,
 variant       VLNV + port-map + clk/rst assoc  create_bd_cell of IP,
 (promotes                                       create_bd_intf_port,
  buses to     -> SoCVivadoBdBackend             assign_bd_address)
  boundary)        |
                   v
        build_soc/fpga/<top>_package_ip.tcl   (ipx::)
        build_soc/fpga/bus_defs/*.xml          (custom AHB/APB bus defs)
        build_soc/fpga/<top>_bd.tcl            (optional create_bd_*)
```

### 5.1 (A) Wrapper boundary: promote interconnect interfaces (optional)

For the typed-bus story to be more than clk/uart, the FPGA wrapper must expose
at least one interconnect bus. Two sub-options, both supported by a single model
annotation:

- **Reuse the existing curated wrapper as-is.** For the live multicore wrapper
  that is clk×2/reset/UART typed + raw RMII/MDIO/SWD/QSPI/status; for the legacy
  wrapper it is GPIO/UART/SWD/clk/rst. The new backend types exactly what
  `package_nanosoc_multicore_ip.tcl` (or the legacy `package_nanosoc_ip.tcl`)
  does today, but from the model. Zero new RTL. This is M1–M3.
- **Promote a bus**: mark a toplevel `Interface` (or a passthrough
  initiator/target) with `fpga_expose: true`. The toplevel backend already
  expands it into boundary ports; the wrapper variant forwards those ports
  outward. The BD backend then types them. This is M5.

We do **not** invent a new wrapper RTL generator from scratch — the
`nanosoc_multicore_vivado_wrapper.v` (and legacy `nanosoc_chip_vivado_wrapper.v`)
boundary is small and stable. The promotion annotation simply tells the BD
backend which ifaces to type *and* (for M5) drives a tiny Jinja2 wrapper template
that adds the forwarded ports. Decision: keep the generic curated path identical
to today so M1–M4 are pure-TCL, no RTL risk.

### 5.2 (B) Interface inference table

A new data table — `backends/vivado_bus_map.py` — that mirrors
`protocol_utils.py` but maps **model iface type → Xilinx bus VLNVs + logical
port-map**. Driving everything from one table avoids the per-interface TCL
copy-paste in the live `package_nanosoc_multicore_ip.tcl` (and legacy
`package_nanosoc_ip.tcl`).

```python
# backends/vivado_bus_map.py
from dataclasses import dataclass, field
from typing import List, Optional

@dataclass
class PortMap:
    logical: str            # IP-XACT logical port name, e.g. 'HADDR', 'TRI_I'
    suffix: str             # physical suffix appended to iface name, e.g. 'haddr'

@dataclass
class VivadoBusDef:
    bus_type_vlnv: str
    abstraction_vlnv: str
    # 'master'|'slave' from the *interface_mode* Vivado expects; computed per
    # iface direction (see _interface_mode below) when None.
    default_mode: Optional[str] = None
    port_maps: List[PortMap] = field(default_factory=list)
    custom_busdef: bool = False        # True -> we must emit a bus-def XML

# Stock Xilinx defs (no XML needed)
CLOCK = VivadoBusDef('xilinx.com:signal:clock:1.0',
                     'xilinx.com:signal:clock_rtl:1.0', 'slave',
                     [PortMap('CLK', '')])
RESET = VivadoBusDef('xilinx.com:signal:reset:1.0',
                     'xilinx.com:signal:reset_rtl:1.0', 'slave',
                     [PortMap('RST', '')])
GPIO  = VivadoBusDef('xilinx.com:interface:gpio:1.0',
                     'xilinx.com:interface:gpio_rtl:1.0', 'master',
                     [PortMap('TRI_I', 'in'), PortMap('TRI_O', 'out'),
                      PortMap('TRI_T', 'outen')])   # see note on TRI_T below
UART  = VivadoBusDef('xilinx.com:interface:uart:1.0',
                     'xilinx.com:interface:uart_rtl:1.0', 'master',
                     [PortMap('RxD', 'rxd'), PortMap('TxD', 'txd')])

# Custom AHB-Lite / APB defs (require shipped XML, custom_busdef=True).
# soclabs VLNVs; XML lives in build_soc/fpga/bus_defs/.
AHB_LITE = VivadoBusDef('soclabs.org:interface:ahblite:1.0',
                        'soclabs.org:interface:ahblite_rtl:1.0', None,
                        [PortMap('HADDR','haddr'), PortMap('HTRANS','htrans'),
                         PortMap('HWRITE','hwrite'), PortMap('HSIZE','hsize'),
                         PortMap('HBURST','hburst'), PortMap('HPROT','hprot'),
                         PortMap('HWDATA','hwdata'), PortMap('HMASTLOCK','hmastlock'),
                         PortMap('HRDATA','hrdata'), PortMap('HREADY','hready'),
                         PortMap('HRESP','hresp'), PortMap('HSEL','hsel'),
                         PortMap('HREADYOUT','hreadyout')],
                        custom_busdef=True)
APB = VivadoBusDef('soclabs.org:interface:apb:1.0',
                   'soclabs.org:interface:apb_rtl:1.0', None,
                   [PortMap('PSEL','psel'), PortMap('PADDR','paddr'),
                    PortMap('PENABLE','penable'), PortMap('PWRITE','pwrite'),
                    PortMap('PWDATA','pwdata'), PortMap('PRDATA','prdata'),
                    PortMap('PREADY','pready'), PortMap('PSLVERR','pslverr')],
                   custom_busdef=True)

# Map model Interface.type -> VivadoBusDef
IFACE_TYPE_MAP = {'gpio': GPIO, 'ahb': AHB_LITE, 'apb': APB}
# axis/axis_byte -> AXIS via stock xilinx.com:interface:axis_rtl:1.0 (M6)
```

> **TRI_T caveat (must verify against actual port suffix).** The model's
> `GPIO_SIGNALS` (`protocol_utils.py:88`) emits suffixes `in/out/outen`. The
> legacy wrapper exposes `_tri_i/_tri_o/_tri_t` and inverts enable polarity in
> RTL (`nanosoc_chip_vivado_wrapper.v:63-72`). So the GPIO map above is **only
> correct against the legacy wrapper's port names**, not against the raw model
> GPIO expansion (and the live multicore wrapper has no GPIO at all). The backend
> must therefore type against the *wrapper's* boundary via the `WRAPPER_BOUNDARY`
> physical-name indirection (see §5.3.1). This is the one place where wrapper RTL
> and model expansion diverge — keep them reconciled.

Each member's physical name comes from `WRAPPER_BOUNDARY[wrapper_top]` for
curated ports, or `f'{iface.name}_{port_map.suffix}'` for generator-promoted
model ifaces (M5); see §5.3.1. `interface_mode` for AHB/APB is derived from
direction:

```python
def interface_mode(iface, busdef):
    if busdef.default_mode:
        return busdef.default_mode
    # AHB initiator/out -> master; target/in -> slave. APB always slave.
    if iface.type == 'apb':
        return 'slave'
    return 'master' if iface.is_output else 'slave'
```

### 5.3 (C) The backend

`backends/vivado_bd.py` → `SoCVivadoBdBackend`, following the existing backend
convention (no base class, own ctor, own `generate*`):

```python
class SoCVivadoBdBackend:
    # Defaults target the LIVE multicore IP. The wrapper module name doubles as
    # the IP name (the multicore BD instantiates
    # soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0), and core_rev=1
    # matches pynq/Makefile FPGA_CORE_REV. Pass the legacy values
    # (wrapper_top='nanosoc_chip_vivado_wrapper', ip_name='nanosoc_chip',
    # core_rev=2) to re-emit the single-core IP instead.
    def __init__(self, top_module: Module, vendor='soclabs.org', core_rev=1,
                 wrapper_top='nanosoc_multicore_vivado_wrapper',
                 ip_name=None):                 # ip_name defaults to wrapper_top
        self.top = top_module
        self.ip_name = ip_name or wrapper_top
        ...

    def generate_package_tcl(self, out_dir: Path) -> Path:
        """Emit <top>_package_ip.tcl (ipx:: packaging) + bus_defs/*.xml."""

    def generate_bd_tcl(self, out_dir: Path,
                        with_ps: bool = False) -> Optional[Path]:
        """Emit <top>_bd.tcl (create_bd_* of the packaged IP)."""
```

**Wrapper/IP selection.** The backend is parameterised on
`(wrapper_top, ip_name, core_rev)` rather than baking in one identity. The
caller in `__main__.py` selects the live multicore triple by default; a future
single-core regeneration passes the legacy triple. The VLNV the BD will reference
is then `f'{vendor}:user:{ip_name}:{core_rev}.0'`, which for the defaults is the
exact string the live board BD already uses
(`nanosoc_multicore_design.tcl:176`).

Both render Jinja2 templates (consistent with toplevel/chip/firmware backends),
guarded by `if Environment is None: return None` exactly like `chip.py:43-45`.

The packaging template iterates a context list of *typed boundary interfaces*
built by `_typed_interfaces()` (below), plus the synthetic clk/reset entries
derived from `top.clocks` / `top.resets`. Clock/reset association is computed
once: `ASSOCIATED_BUSIF` = the comma-joined names of every typed bus that shares
the clock; `ASSOCIATED_RESET` = the reset iface name; reset `POLARITY` from the
`model` reset `active` field.

#### 5.3.1 Resolving model suffixes vs wrapper physical names

The core mechanism — and the one place the model and the curated wrapper RTL
diverge — is mapping each `VivadoBusDef.PortMap` to a *physical port name that
actually exists on the wrapper*. The model expands a GPIO iface to suffixes
`in/out/outen` (`GPIO_SIGNALS`, `protocol_utils.py:88`), but the legacy wrapper
exposes `gpio0_tri_i / _tri_o / _tri_t` and inverts the enable polarity in RTL
(`nanosoc_chip_vivado_wrapper.v:63-72`). The live multicore wrapper does not
expose GPIO at all, and renames the SWD/MDIO/QSPI enables to Vivado `_t`
(`nanosoc_multicore_vivado_wrapper.v:133/138/141`). Two distinct boundaries, so
the backend cannot derive physical names from the model alone.

Resolution: a `WRAPPER_BOUNDARY` data structure — one entry per wrapper variant,
selected by `wrapper_top` — that pins, per typed interface, the *exact* physical
port names. It is a dict of `{iface_name: {logical: physical}}`:

```python
# vivado_bus_map.py
# Keyed by wrapper_top so the backend types against the wrapper that is
# actually packaged (NOT the raw model expansion). Each inner map is
# logical-port -> physical-port; physical names are copied verbatim from the
# wrapper module port list and MUST round-trip a unit test (see §8).
WRAPPER_BOUNDARY = {
    'nanosoc_multicore_vivado_wrapper': {
        # two clocks + reset + one UART bus; everything else stays raw
        'sys_fclk':     (CLOCK, {'CLK': 'sys_fclk'}),
        'rmii_ref_clk': (CLOCK, {'CLK': 'rmii_ref_clk'}),   # +FREQ_HZ 50e6
        'nrst':         (RESET, {'RST': 'nrst'}),
        'uart':         (UART,  {'RxD': 'uart_rxd', 'TxD': 'uart_txd'}),
        # RMII/MDIO/SWD/QSPI/status: NOT typed -> emitted as scalar ports.
    },
    'nanosoc_chip_vivado_wrapper': {            # legacy single-core
        'clk':   (CLOCK, {'CLK': 'clk'}),
        'nrst':  (RESET, {'RST': 'nrst'}),
        'gpio0': (GPIO,  {'TRI_I': 'gpio0_tri_i', 'TRI_O': 'gpio0_tri_o',
                          'TRI_T': 'gpio0_tri_t'}),   # _tri_t, polarity in RTL
        'gpio1': (GPIO,  {'TRI_I': 'gpio1_tri_i', 'TRI_O': 'gpio1_tri_o',
                          'TRI_T': 'gpio1_tri_t'}),
        'uart':  (UART,  {'RxD': 'uart_rxd', 'TxD': 'uart_txd'}),
    },
}
```

`_typed_interfaces()` then resolves in two passes, so the curated path (M1) and
the promoted-bus path (M5) share one builder:

```python
def _typed_interfaces(self):
    ctx, boundary = [], WRAPPER_BOUNDARY[self.wrapper_top]
    # Pass 1 — curated, hard-pinned interfaces from WRAPPER_BOUNDARY.
    for name, (busdef, phys) in boundary.items():
        ctx.append(self._typed_entry(name, busdef,
                   port_maps=[(pm.logical, phys[pm.logical])
                              for pm in busdef.port_maps]))
    # Pass 2 — promoted model buses (M5+): physical names ARE the model
    # expansion (f'{iface.name}_{suffix}'), because the M5 wrapper template
    # forwards exactly those names — no rename, so no override needed.
    for iface in self.top.interfaces:
        if iface.params.get('fpga_expose') and iface.name not in boundary:
            busdef = IFACE_TYPE_MAP[iface.type]
            ctx.append(self._typed_entry(iface.name, busdef,
                       port_maps=[(pm.logical, f'{iface.name}_{pm.suffix}')
                                  for pm in busdef.port_maps],
                       mode=interface_mode(iface, busdef)))
    return ctx
```

The key invariant: **curated wrapper ports get physical names from
`WRAPPER_BOUNDARY` (because the hand-written wrapper renamed them);
generator-promoted ports get physical names from the model expansion (because the
M5 wrapper template emits exactly the model suffixes, by construction).** That is
why M5 generates the wrapper too — it removes the rename, collapsing both passes
onto one naming source. A unit test asserts every physical name in
`WRAPPER_BOUNDARY[wrapper_top]` is present in the parsed wrapper `.v` port list,
so a hand-edit to the wrapper that drops/renames a pin fails CI rather than
silently producing a broken `component.xml`.

### 5.4 Generated `*_package_ip.tcl` (illustrative)

```tcl
# AUTO-GENERATED by nanosoc_gen SoCVivadoBdBackend — do not edit.
set component_lib $env(FPGA_COMPONENT_LIB)
source $env(FPGA_COMPONENT_FILELIST)
read_verilog {{ wrapper_src }}
set_property top {{ wrapper_top }} [current_fileset]
update_compile_order -fileset sources_1

# Register custom AHB/APB bus definitions so abstraction VLNVs resolve.
{% for xml in bus_def_xmls %}
set_property ip_repo_paths [concat [get_property ip_repo_paths [current_project]] {{ xml | dirname }}] [current_project]
{% endfor %}
update_ip_catalog

ipx::package_project -root_dir $component_lib -vendor $env(FPGA_VENDOR) \
    -library user -taxonomy /UserIP -import_files -set_current false -force \
    -force_update_compile_order
ipx::unload_core $component_lib/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $component_lib $component_lib/component.xml
set core [ipx::current_core]

# STEP 3: strip auto-inferred interfaces (same discipline as the hand script)
foreach bus_if [ipx::get_bus_interfaces -of_objects $core] {
    ipx::remove_bus_interface [get_property NAME $bus_if] $core
}

{% for bif in interfaces %}
# --- {{ bif.name }} ({{ bif.display }}) ---
ipx::add_bus_interface {{ bif.name }} $core
set_property abstraction_type_vlnv {{ bif.abstraction_vlnv }} [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property bus_type_vlnv         {{ bif.bus_type_vlnv }}    [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property interface_mode        {{ bif.mode }}            [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property display_name         "{{ bif.display }}"        [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
{% for pm in bif.port_maps %}
ipx::add_port_map {{ pm.logical }} [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property physical_name {{ pm.physical }} [ipx::get_port_maps {{ pm.logical }} -of_objects [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]]
{% endfor %}
{% if bif.associated_reset %}
ipx::add_bus_parameter ASSOCIATED_RESET [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property value {{ bif.associated_reset }} [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]]
{% endif %}
{% if bif.associated_busif is not none %}
ipx::add_bus_parameter ASSOCIATED_BUSIF [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property value {{ '{' }}{{ bif.associated_busif }}{{ '}' }} [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]]
{% endif %}
{% if bif.polarity %}
ipx::add_bus_parameter POLARITY [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]
set_property value {{ bif.polarity }} [ipx::get_bus_parameters POLARITY -of_objects [ipx::get_bus_interfaces {{ bif.name }} -of_objects $core]]
{% endif %}
{% endfor %}

ipx::merge_project_changes -verbose files $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
ipx::move_temp_component_back -component $core
close_project
update_ip_catalog
```

This is the same shape as the hand scripts (compare the live multicore
`package_nanosoc_multicore_ip.tcl` STEP 3–7, or the legacy
`package_nanosoc_ip.tcl:43-200`) but every interface block is data-driven.

### 5.5 Generated `*_bd.tcl` (illustrative, bare/no-PS variant)

```tcl
# AUTO-GENERATED block design — bare instantiation of the packaged NanoSoC IP.
create_bd_design {{ design_name }}
current_bd_design {{ design_name }}
set nsc [ create_bd_cell -type ip -vlnv {{ vendor }}:user:{{ ip_name }}:{{ rev }}.0 nanosoc_0 ]

# Discrete / typed external ports derived from the model boundary.
{% for p in scalar_ports %}
create_bd_port -dir {{ p.dir }}{% if p.width > 1 %} -from {{ p.width-1 }} -to 0{% endif %}{% if p.type %} -type {{ p.type }}{% endif %} {{ p.name }}
connect_bd_net [get_bd_ports {{ p.name }}] [get_bd_pins nanosoc_0/{{ p.name }}]
{% endfor %}

{% for ip in intf_ports %}
create_bd_intf_port -mode {{ ip.mode }} -vlnv {{ ip.abstraction_vlnv }} {{ ip.name }}
connect_bd_intf_net [get_bd_intf_ports {{ ip.name }}] [get_bd_intf_pins nanosoc_0/{{ ip.name }}]
{% endfor %}

# Address map from the model's interconnect targets (single source of truth).
{% for seg in address_segments %}
assign_bd_address -offset {{ '0x%08X' % seg.base }} -range {{ '0x%08X' % seg.size }} \
  -target_address_space [get_bd_addr_spaces {{ seg.space }}] \
  [get_bd_addr_segs {{ seg.seg }}] -force
{% endfor %}

validate_bd_design
save_bd_design
```

Compare to the real primitives already in repo (legacy single-core export,
`targets/pynq_z2/vivado_script/2021_1/nanosoc_design.tcl`): `create_bd_intf_port
-mode Master -vlnv ...` (`:738`), `create_bd_port -dir I -from 7 -to 0 ...`
(`:744`), `create_bd_intf_pin -mode Slave -vlnv
xilinx.com:interface:aximm_rtl:1.0 S00_AXI` (`:208` — note the *abstraction*
VLNV `aximm_rtl:1.0`; the matching `bus_type_vlnv` is the stock
`xilinx.com:interface:aximm:1.0`, paired by Vivado), `assign_bd_address -offset
0x41200000 -range 0x00010000 ...` (`:869`),
`validate_bd_design`/`save_bd_design` (`:878-879`). The live multicore board BD
`pynq/targets/pynq-z2/nanosoc_multicore_design.tcl` uses the same primitive set,
instantiating the curated IP at `:176`.

> **The PS/board overlay is NOT generated.** For the pynq case the user keeps a
> small hand-written `*_board.tcl` that creates the PS7/Zynq-US+ cell and the
> `cmsdk_socket` pin-mux, then `source`s the generated `*_bd.tcl` as a
> sub-step. The generated BD's job is only the model-derived IP + its typed
> ports + address map. This is the clean cut between "what the model knows" and
> "board-specific glue it does not".

---

## 6. Implementation plan (milestones)

Each milestone is independently shippable. M1–M4 require **no RTL change** and
no custom bus XML — they just regenerate the existing curated-IP behaviour from
the model. M5+ add real interconnect ports.

### M1 — Inference table + clk×2/reset/uart packaging TCL (parity with the LIVE multicore script)
- **Change:** new `backends/vivado_bus_map.py` (stock VLNVs only:
  CLOCK/RESET/UART, +GPIO for the legacy path); new `backends/vivado_bd.py` with
  `generate_package_tcl`; new template `templates/vivado_package_ip.tcl.j2`.
  Type `sys_fclk`/`rmii_ref_clk`/`nrst`/`uart` against the **live**
  `nanosoc_multicore_vivado_wrapper` port names via the
  `WRAPPER_BOUNDARY['nanosoc_multicore_vivado_wrapper']` entry (§5.3.1), which
  mirrors `nanosoc_multicore_vivado_wrapper.v:48-116`. Include the
  `rmii_ref_clk` `FREQ_HZ 50000000` parameter the live script sets.
- **Why:** prove the data-driven TCL reproduces the IP-XACT the *live* multicore
  flow already packages before touching anything riskier.
- **Acceptance:** `vivado -mode batch -source build_soc/fpga/<top>_package_ip.tcl`
  produces a `component.xml` whose bus interfaces (`sys_fclk`/`rmii_ref_clk`/
  `nrst`/`uart`) and port maps match the **live**
  `package_nanosoc_multicore_ip.tcl` output. Diff the two `component.xml` for
  interface/port-map equivalence (timestamps/checksums excepted). Anchor the diff
  to the multicore baseline, *not* the legacy single-core `component.xml` —
  byte-equivalence to the legacy IP would prove nothing about the IP the board
  actually consumes. (A secondary legacy-parity check, passing the legacy ctor
  triple, is optional regression value but not the M1 gate.)

### M2 — Wire into the generator pipeline + makefile
- **Change:** import `SoCVivadoBdBackend` in `__main__.py` (near the other
  backend imports, `:19-34`); add an inline call block writing to
  `build_dir/'fpga'`. **Placement matters:** the chip backend is gated by
  `if system_module:` (`__main__.py:~294`), so it only runs when `--system-yaml`
  is supplied. The FPGA-BD backend needs only `top_module`, so emit it
  *unconditionally* (not inside the `if system_module:` block) after docs
  generation — or, if it should track the chip wrapper, document that
  `--system-yaml` is then required. Add a `package_nanosoc_ip_gen` target in
  `flows/makefile.fpga` (and a sibling in `pynq/Makefile`) that sources the
  generated TCL using the *same* env-var contract as the live `package_ip`
  recipe (`pynq/Makefile:193`; legacy `flows/makefile.fpga` `package_nanosoc_ip`
  `:99-112`).
- **Why:** make it part of the standard render so it stays current with the
  model; reuse the existing vivado batch invocation.
- **Acceptance:** running the generator
  (`python -m nanosoc_gen.soc_model ...`, as `nanosoc_arch_tech/makefile:305`
  invokes it with `sys_desc/nanosoc_m0_soc.yaml --system-yaml
  nanosoc_m0_system.yaml`) writes `build_soc/fpga/<top>_package_ip.tcl`;
  `make -C pynq package_nanosoc_ip_gen` packages the IP successfully (vivado log
  "packaged successfully"). There is no `sys_desc/Makefile` in this tree, so the
  acceptance is phrased against the actual generator entrypoint, not a
  `make -C sys_desc`.

### M3 — Clock/reset association + polarity from the model
- **Change:** compute `ASSOCIATED_RESET`, `ASSOCIATED_BUSIF` (all typed buses),
  and reset `POLARITY` from `top.clocks`/`top.resets` (reset `active` field)
  instead of the hard-coded `nrst`/`ACTIVE_LOW` of the hand script.
- **Why:** correct IPI auto-connect for any clock/reset naming; removes the
  last hard-coded values from the packaging TCL.
- **Acceptance:** in IPI, dropping the IP and running "Run Connection
  Automation" auto-connects clk to a clock source and nrst to a
  proc-system-reset's `peripheral_aresetn` (ACTIVE_LOW honoured). Manually
  verify on a scratch BD or assert via a TCL post-check that
  `ASSOCIATED_BUSIF`/`ASSOCIATED_RESET` parameters exist with expected values.

### M4 — Optional bare block-design TCL (typed clk×2/uart + raw pins)
- **Change:** `generate_bd_tcl(with_ps=False)` + `templates/vivado_bd.tcl.j2`.
  Emit `create_bd_design`, `create_bd_cell` of the packaged IP, the typed UART
  bus as `create_bd_intf_port`, and `sys_fclk`/`rmii_ref_clk`/`nrst`/swd/RMII/
  MDIO/QSPI/status as `create_bd_port` (the multicore wrapper exposes no GPIO
  bus; for the legacy wrapper, GPIO is the extra `create_bd_intf_port`).
  `validate`/`save`. No address map yet (no AXI slave to map).
- **Why:** end-to-end "model → packaged IP → BD" without board glue, usable for
  smoke/elaboration.
- **Acceptance:** `vivado -mode batch` sourcing `<top>_bd.tcl` runs
  `validate_bd_design` with zero critical warnings on a scratch project for the
  default part (`xc7z020clg400-1`, `pynq/Makefile:62` `XILINX_PART`).

### M5 — Custom AHB-Lite + APB bus definitions; promote one bus to the boundary
- **Change:**
  1. Ship IP-XACT bus-def + abstraction XMLs for `ahblite`/`apb`
     (generated into `build_soc/fpga/bus_defs/` from the
     `protocol_utils` AHB/APB signal tables — or hand-authored once and checked
     in under `pynq/vivado_ip/bus_defs/` next to the live packaging script; see
     §7).
  2. Add `fpga_expose: true` annotation handling on a toplevel `Interface`;
     extend `vivado_bus_map` with `AHB_LITE`/`APB`; add a tiny wrapper variant
     template (`vivado_wrapper.v.j2`) that forwards the promoted iface's
     boundary ports outward.
- **Why:** the actual goal — exposing a typed interconnect port.
- **Acceptance:** packaged IP shows a typed AHB-Lite (or APB) master/slave
  interface in IPI; a scratch BD connecting it to a matching custom-bus consumer
  (or to an AXI bridge, §9) validates.

### M6 — AXI-Stream typing + address-mapped AXI promotion
- **Change:** map `axis`/`axis_byte` to stock `axis_rtl`; when a promoted bus is
  AXI-MM, emit `assign_bd_address` segments from `InterconnectTarget.base/size`
  (`model.py:159-160`) so the BD address map equals the model.
- **Why:** completes typed-port coverage; makes the model the single source of
  truth for offsets (kills the hardcoded `0x41200000` etc. drift class).
- **Acceptance:** generated `assign_bd_address` offsets/ranges equal the model's
  target base/size for every addressable promoted target; `validate_bd_design`
  clean.

### M7 — Re-emit under the live multicore VLNV so the board BD picks it up (cleanup)
- **Change:** repackage the generated IP under the *same* VLNV the live board BD
  already references —
  `soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0`
  (`nanosoc_multicore_design.tcl:176`, `core_revision = 1`). No board-BD edit is
  needed: the BD instantiates that VLNV today, so a generated IP under the same
  VLNV is a drop-in. (For the legacy single-core case the equivalent target is
  `soclabs.org:user:nanosoc_chip:2.0`.)
- **Why:** make the generated artifact replace the hand-written
  `package_nanosoc_multicore_ip.tcl` with zero downstream churn — the goal of §3.
- **Acceptance:** the live pynq_z2 multicore board BD builds against the
  generated IP and produces a `.bit` (the `fpga_smoke` CI job — `allow_failure:
  true`, tag `vivado`, runs `make -C pynq synth_only`; see §8). Full bitstream is
  the manual `fpga_deploy` job.

---

## 7. File & module changes

### New files

| Path | Purpose |
|---|---|
| `nanosoc_gen/soc_model/backends/vivado_bus_map.py` | `VivadoBusDef`/`PortMap` dataclasses + `IFACE_TYPE_MAP` + `interface_mode()` (the inference table, §5.2). |
| `nanosoc_gen/soc_model/backends/vivado_bd.py` | `SoCVivadoBdBackend` (`generate_package_tcl`, `generate_bd_tcl`). |
| `nanosoc_gen/soc_model/backends/templates/vivado_package_ip.tcl.j2` | The ipx:: packaging template (§5.4). |
| `nanosoc_gen/soc_model/backends/templates/vivado_bd.tcl.j2` | The `create_bd_*` template (§5.5). |
| `nanosoc_gen/soc_model/backends/templates/vivado_wrapper.v.j2` | (M5+) wrapper variant that forwards promoted bus ports. |
| `pynq/vivado_ip/bus_defs/ahblite_busdef.xml`, `ahblite_rtl.xml`, `apb_busdef.xml`, `apb_rtl.xml` | (M5) custom IP-XACT bus + abstraction defs (next to the live `package_nanosoc_multicore_ip.tcl`), OR generate into `build_soc/fpga/bus_defs/`. |

### Modified files

| Path | Change |
|---|---|
| `nanosoc_gen/soc_model/__main__.py` | Add `from .backends.vivado_bd import SoCVivadoBdBackend` (near the backend imports, `:19-34`); add an inline call block writing to `build_dir/'fpga'`. Emit it **outside** the `if system_module:` chip-gen block (`~:294`) since the FPGA-BD backend needs only `top_module`. Optionally a `--fpga-bd` flag (default on). |
| `flows/makefile.fpga` and `pynq/Makefile` | Add a `package_nanosoc_ip_gen` target. In the live `pynq/Makefile`, mirror `package_ip:` (`:193`) — same `FPGA_VENDOR`/`FPGA_CORE_REV` (`:114-115`), `FPGA_COMPONENT_FILELIST`/`_LIB` — but source `$(BUILD_SOC_DIR)/fpga/<top>_package_ip.tcl`. In the legacy `flows/makefile.fpga`, mirror `package_nanosoc_ip` (`:99-112`) identically. |
| `nanosoc_gen/soc_model/backends/protocol_utils.py` | (M5) optionally add an `ahb_busdef_signals()`/`apb_busdef_signals()` helper if the bus-def XML is *generated* rather than hand-checked-in — reuse `AHB_INITIATOR_SIGNALS`/`AHB_TARGET_SIGNALS` to drive the XML. No change to existing tables. |
| `sys_desc/nanosoc_m0_soc.yaml` (the top SoC YAML; see `nanosoc_arch_tech/makefile:305`, paired with `--system-yaml sys_desc/nanosoc_m0_system.yaml`, `:308`) | (M5) add `fpga_expose: true` to the chosen toplevel bus iface (no schema change needed — builder uses `.get()`; it just becomes a backend-read key). Note: `sys_desc/` in this working tree holds only `regions/`, `register_maps/`, `subsystems/`; the top YAMLs are referenced by the makefile and live with the system description, not under `sys_desc/` here. |

### Key signatures introduced

```python
# vivado_bd.py
class SoCVivadoBdBackend:
    # Live multicore identity by default; ip_name defaults to wrapper_top.
    def __init__(self, top_module, vendor='soclabs.org', core_rev=1,
                 wrapper_top='nanosoc_multicore_vivado_wrapper',
                 ip_name=None): ...
    def _typed_interfaces(self) -> List[dict]: ...      # builds template ctx
                                                        # (resolves via WRAPPER_BOUNDARY, §5.3.1)
    def _scalar_ports(self) -> List[dict]: ...          # raw pins (swd/rmii/mdio/qspi/status/clk/nrst)
    def _address_segments(self) -> List[dict]: ...      # from InterconnectTarget
    def _clock_reset_assoc(self) -> dict: ...           # ASSOCIATED_* + POLARITY
    def generate_package_tcl(self, out_dir: Path) -> Optional[Path]: ...
    def generate_bd_tcl(self, out_dir: Path, with_ps=False) -> Optional[Path]: ...
```

The jinja2 guard pattern is copied verbatim from `chip.py:18-22, 43-45` so the
backend silently no-ops without jinja2, like every other template backend.

---

## 8. Testing & validation

Layered cheapest-first, consistent with the unit-testing doc
(`01-unit-testing-nanosoc-gen.md`) and the CI doc
(`03-ci-system-validity-matrix.md`).

1. **Pure-Python unit tests (no Vivado).** Add `nanosoc_gen/tests/test_vivado_bd.py`
   (pytest; there is no `nanosoc_gen/tests/` today — this introduces it,
   coordinate with `01-unit-testing-nanosoc-gen.md`). Build a small `Module`
   fixture with two clocks, one active-low reset, one UART, one AHB iface (and,
   for the legacy path, two GPIO ifaces); assert:
   - `_typed_interfaces()` returns the right VLNV per type;
   - every physical name in `WRAPPER_BOUNDARY[wrapper_top]` is present in the
     parsed wrapper `.v` port list (the §5.3.1 drift guard — run for both
     `nanosoc_multicore_vivado_wrapper` and `nanosoc_chip_vivado_wrapper`);
   - `interface_mode()` maps AHB initiator→master, target→slave, APB→slave;
   - `_address_segments()` offsets/ranges equal the fixture's
     `InterconnectTarget.base/size`;
   - the rendered `*_package_ip.tcl` string contains the expected
     `ipx::add_bus_interface`/`add_port_map`/`physical_name` lines (golden
     substring match against the live `package_nanosoc_multicore_ip.tcl`), and
     contains no Jinja artifacts.
   These run in seconds and are the per-config gate analogous to
   `--validate-only`.

2. **TCL-syntax lint (no synthesis).** `vivado -mode batch -source <tcl> -tclargs
   --dry` is not a thing, but `info complete` over the file, or running the
   packaging in a throwaway project and checking exit code, catches TCL typos.
   M1 acceptance uses the real `ipx::` run and diffs `component.xml` against the
   **live multicore** `package_nanosoc_multicore_ip.tcl` output (not the legacy
   single-core IP — see M1).

3. **IPI smoke (Vivado, gated).** M4/M5/M6: a scratch project that sources the
   generated `*_bd.tcl` and asserts `validate_bd_design` returns no
   `CRITICAL WARNING`. This is the FPGA leg. The superproject `.gitlab-ci.yml`
   already has an `fpga_smoke` job (`allow_failure: true`, tag `vivado`,
   `needs: [clone, preflight, soc_gen]`) that runs `make -C "$WORK_DIR/pynq"
   synth_only` — point the new smoke at the *generated* packaging TCL by having
   `synth_only` depend on `package_nanosoc_ip_gen` (or add a parallel job). Note
   the doc itself lives in `nanosoc_arch_tech/`, which has **no** `.gitlab-ci.yml`
   of its own; the CI that drives the multicore FPGA flow is the superproject's.

4. **End-to-end bitstream (M7, manual/gated).** Build one board against the
   generated IP and confirm a `.bit` emerges
   (`pynq/Makefile` `build_design:` → `FPGA_BIT`,
   `nanosoc_multicore_design_wrapper.bit`, `:125`). The superproject's
   `fpga_deploy` job (`when: manual`, fpgahub-leased board) covers the on-board
   leg; do not make it a blocking gate.

CI interaction: the generated TCL/XML land under `build_soc/fpga/` and become a
`soc_gen` job artifact like the rest of `build_soc/`. The pure-Python tests
join the generator pytest set `01-unit-testing-nanosoc-gen.md` proposes.

---

## 9. Risks, tradeoffs, alternatives

- **No native Xilinx AHB/APB bus type (highest risk; M5–M6 only).** Custom
  IP-XACT bus definitions are fiddly and version-sensitive; IPI won't
  auto-connect two custom buses unless both ends use the *same* abstraction VLNV.
  This risk is **confined to M5–M6** and rests on bench-only unknowns (the three
  open items in the Appendix: TRI_T polarity, custom-bus auto-connect, address-
  segment path strings — all "needs a Vivado run"). Mitigation: M1–M4 deliver the
  cheap, shippable value with **only stock VLNVs** — for the multicore wrapper
  that is clk×2 (`clock_rtl`) + reset (`reset_rtl`) + UART (`uart_rtl`); GPIO
  (`gpio_rtl`) applies only to the legacy wrapper. Those re-emit the live
  `package_nanosoc_multicore_ip.tcl` with zero new RTL and no custom XML, so the
  headline "typed interconnect ports" deliverable (M5–M6) can be deferred until a
  real consumer needs it without blocking M1–M4. **Alternative considered:**
  instead of custom AHB bus defs, insert an AXI↔AHB bridge inside the wrapper and
  expose *AXI-MM* (`aximm_rtl`, fully native, auto-connect + `assign_bd_address`
  just works). This trades RTL complexity (a bridge) for TCL simplicity and is
  likely the better long-term path for *initiator* promotion to Xilinx
  infrastructure; custom AHB defs are better for chip-to-chip / AHB-native
  consumers. Recommend documenting both and choosing per use-case at M5.

- **Wrapper-boundary vs model-expansion divergence.** The wrappers rename/invert
  enables: the legacy wrapper renames GPIO/SWD
  (`nanosoc_chip_vivado_wrapper.v:63-72`); the live multicore wrapper inverts
  MDIO/SWD/QSPI enables to Vivado `_t`
  (`nanosoc_multicore_vivado_wrapper.v:133/138/141`); the model's `GPIO_SIGNALS`
  uses `in/out/outen` (`protocol_utils.py:88`). The backend must type against the
  *wrapper's* actual port names, not the raw model expansion — resolved
  concretely by the `WRAPPER_BOUNDARY` dict and the two-pass `_typed_interfaces()`
  in §5.3.1 (curated ports take hard-pinned physical names; M5 promoted ports take
  model-expansion names because the M5 wrapper template emits exactly those).
  Risk: if someone hand-edits a wrapper, the TCL drifts — the §8 unit test
  asserting `WRAPPER_BOUNDARY[wrapper_top]` physical names all exist in the parsed
  wrapper `.v` port list guards this for both wrappers.

- **Generated-vs-hand IP coexistence (M7).** For the multicore system this risk
  is *low*: the live board BD already references
  `soclabs.org:user:nanosoc_multicore_vivado_wrapper:1.0`
  (`nanosoc_multicore_design.tcl:176`), so re-emitting under that exact VLNV is a
  drop-in replacement, not a clobber. Mitigation if cautious: package the
  generated IP into a *separate* `FPGA_COMPONENT_LIB` dir, point one board build
  at it as a pilot, then promote. (The clobber risk was real only for the legacy
  single-core `nanosoc_chip` raw-port IP.)

- **External build scripts not in repo.** `build_design.tcl` /
  `package_component.tcl` (legacy) live in `$SOCLABS_SOCTOOLS_FLOW_DIR` (unset in
  this shell); the live multicore build instead uses the in-tree
  `pynq/build_nanosoc_multicore_design.tcl` (`pynq/Makefile:70`). Our generated
  packaging TCL is self-contained and invoked directly via
  `vivado -mode batch -source`, so it does not depend on the soctools scripts —
  keep it that way; the board build can `source` it as a sub-step.

- **Effort vs payoff.** M1–M3 (parity, model-driven typing) is the cheap,
  high-value, fully-shippable slice — it kills the dual-source-of-truth in the
  live `package_nanosoc_multicore_ip.tcl`. M5–M7 (custom buses, promotion, board
  retarget) are the expensive, higher-risk slice that delivers the headline
  "typed interconnect ports" but rests on bench-only unknowns — adopt only when an
  actual consumer needs them.

---

## 10. Dependencies & sequencing

- **Builds on:**
  - `02-clean-architecture-adapters-backends.md` — if a backend base class /
    registry lands, `SoCVivadoBdBackend` should adopt it; until then we follow
    the hard-wired `__main__.py` convention. Not a hard blocker.
  - `07-toplevel-wrapper-generation-fpga-asic.md` — sibling "boundary as data"
    effort (FPGA/ASIC toplevel wrapper). The FPGA wrapper boundary and the ASIC
    pad boundary share the same model interface list; coordinate the
    `Interface`→boundary mapping so both read one source.
  - The `lib/interfaces/*.yaml` data-driven interface effort (if pursued in
    `02`/yaml-format doc): if `parse_interface_definition` is wired into the
    builder, `vivado_bus_map` could be driven from those YAMLs too instead of a
    Python table. Today those YAMLs are unused (`parse_interface_definition`
    has zero call sites), so M1 uses a Python table to avoid the dependency.

- **Unblocks / relates to:**
  - `01-unit-testing-nanosoc-gen.md` and `03-ci-system-validity-matrix.md` —
    this backend's pure-Python tests are the first entries in a new
    `nanosoc_gen/tests/` dir and a candidate generator pytest set; the IPI smoke
    joins the superproject's existing `fpga_smoke` job (`.gitlab-ci.yml:332`).
  - Any future "expose accelerator/DMA bus to FPGA fabric" work depends on M5/M6
    bus promotion.

- **Rough effort:**
  - M1–M3 (model-driven packaging parity): **M (medium).**
  - M4 (bare BD): **S (small).**
  - M5 (custom AHB/APB defs + promotion): **L (large)** — the custom IP-XACT
    bus definitions and wrapper variant are the bulk of the risk/cost.
  - M6 (AXIS + address map): **M.**
  - M7 (board retarget): **M**, mostly Vivado iteration.

---

### Appendix: confirmed VLNV reference (for the inference table)

| Logical role | bus_type_vlnv | abstraction_vlnv | source |
|---|---|---|---|
| Clock | `xilinx.com:signal:clock:1.0` | `xilinx.com:signal:clock_rtl:1.0` | live `package_nanosoc_multicore_ip.tcl` STEP 4/5 (`sys_fclk`/`rmii_ref_clk`); legacy `package_nanosoc_ip.tcl:103-104` |
| Reset | `xilinx.com:signal:reset:1.0` | `xilinx.com:signal:reset_rtl:1.0` | live STEP 6 (`nrst`); legacy `package_nanosoc_ip.tcl:122-123` |
| GPIO | `xilinx.com:interface:gpio:1.0` | `xilinx.com:interface:gpio_rtl:1.0` | legacy only — `package_nanosoc_ip.tcl:137-138` (multicore wrapper has no GPIO) |
| UART | `xilinx.com:interface:uart:1.0` | `xilinx.com:interface:uart_rtl:1.0` | live `package_nanosoc_multicore_ip.tcl` STEP 7; legacy `package_nanosoc_ip.tcl:180-181` |
| AXI-MM | `xilinx.com:interface:aximm:1.0` (stock; not on a single repo line) | `xilinx.com:interface:aximm_rtl:1.0` | abstraction VLNV at `pynq_z2/...nanosoc_design.tcl:208` (`create_bd_intf_pin -mode Slave -vlnv ...aximm_rtl:1.0 S00_AXI`); bus_type is the paired stock VLNV |
| AXI-Stream | (stock) | `xilinx.com:interface:axis_rtl:1.0` | Vivado native |
| AHB-Lite | `soclabs.org:interface:ahblite:1.0` | `soclabs.org:interface:ahblite_rtl:1.0` | **custom, must ship XML** |
| APB | `soclabs.org:interface:apb:1.0` | `soclabs.org:interface:apb_rtl:1.0` | **custom, must ship XML** |

**Open items requiring bench verification (could not be confirmed from code
alone):**
1. The exact GPIO `TRI_T` polarity contract Vivado's `gpio_rtl` expects vs the
   wrapper's `_tri_t` (`nanosoc_chip_vivado_wrapper.v:64` maps `p0_z`,
   active-high = Hi-Z). The hand script already maps `TRI_T`→`gpio0_tri_t`
   (`package_nanosoc_ip.tcl:148`), so it is presumed correct, but auto-connect
   to `axi_gpio` should be smoke-tested (M3).
2. Whether IPI will auto-connect two `soclabs.org` custom AHB buses without a
   manual `connect_bd_intf_net` — needs an actual Vivado run (M5). The
   AXI-bridge alternative sidesteps this entirely.
3. Exact `assign_bd_address` `space`/`seg` path strings for a promoted AXI slave
   on the packaged IP — these depend on the IP's auto-generated address segment
   names, observable only after M5/M6 packaging.
