# 04 — Testbench Generation with a Default Test Set

> Add a `nanosoc_gen` backend that emits, for any configuration, a self-consistent cocotb testbench (`tb_top.sv` + `Makefile`) plus a battery of model-derived default tests (clock/reset bring-up, bus enumeration, per-region register read/write, memory walk, IRQ smoke) — eliminating the hand-copied, drift-prone per-env testbench that exists today.

---

## 1. Title & summary

See blockquote above. This document is a standalone implementation design for a new TB-generation backend in `nanosoc_gen`. It is written so an experienced SoC+Python engineer can implement it alone, months from now, without the other roadmap docs.

**Repository topology (read this first — it governs every path in this doc).** `nanosoc_gen` and this doc live inside the **`nanosoc_arch_tech` git submodule**. Everything the generated testbench *plugs into* lives in the **superproject one level up** (`nanosoc-multicore-system/`, henceforth `$HOME_SP`):

| Lives in the submodule (`nanosoc_arch_tech/`) | Lives in the superproject (`$HOME_SP`, one level up) |
|---|---|
| `nanosoc_gen/` (the generator + new TB backend) | `cocotb/` (42 env dirs; the regression harness) |
| `verification/cocotb/` (generic ADP driver, vplan) | `sys_desc/nanosoc_multicore_soc.yaml` (the **top SoC YAML** built by CI) |
| `sys_desc/` (region/regmap/subsystem *fragments* + `nanosoc_m0_soc.yaml`, the submodule's own standalone top — `makefile:305`) | `build_soc/` (generated RTL/flist/reports land here) |
| `docs/roadmap/` (this doc + 01–09) | `flist/nanosoc_multicore.flist`, `scripts/`, `.gitlab-ci.yml`, `set_env.sh` |

The CI flow is driven from the superproject: `make -C sys_desc` (a **superproject** Makefile target) feeds `$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml` to the submodule's `nanosoc_gen` and writes outputs under `$HOME_SP/build_soc/`. The submodule's *own* `makefile` builds a different, standalone top (`nanosoc_m0_soc.yaml`) and has **no `cocotb/` dir** (only `verification/cocotb/`) and **no multicore top YAML**. Throughout this doc, bare `cocotb/…`, `sys_desc/nanosoc_multicore_soc.yaml`, `build_soc/…`, `flist/…`, `make -C sys_desc`, and `.gitlab-ci.yml` refer to the **superproject** copies; bare `nanosoc_gen/…`, `verification/cocotb/…`, and `lib/interfaces/…` refer to the **submodule**. §4 and §7 pin the exact relative paths the implementer needs.

---

## 2. Status & scope

**Status:** Greenfield backend, building on existing model + protocol infrastructure. No TB/cocotb backend exists in `nanosoc_gen` today (verified: `grep -ril "testbench|tb_top|cocotb"` over `nanosoc_gen/soc_model/` returns only one *incidental comment* in `backends/templates/nanosoc_soc_config_pkg.sv.j2`).

**Where generated artifacts land (submodule/superproject split — see §1).** The backend code is in the submodule (`nanosoc_arch_tech/nanosoc_gen/soc_model/backends/tb.py`). Its *output* lands in the **superproject** build tree at `$HOME_SP/build_soc/verification/` (a new sibling of the existing `build_soc/{rtl,flist,reports,firmware,docs,discovery,interconnect,rdl}/`), because `make -C sys_desc` runs from `$HOME_SP` and points `nanosoc_gen` at `$HOME_SP/build_soc/`. The checked-in regression shim is a **superproject** file, `$HOME_SP/cocotb/soc_generated/Makefile`. The generated env reuses the **submodule's** ADP driver via the relative path `$HOME_SP/nanosoc_arch_tech/verification/cocotb/nanosoc_cocotb_driver.py` (the same `NANOSOC_MULTICORE_HOME = $(CURDIR)/../..` convention every existing env Makefile uses — `cocotb/soc_smoke/Makefile:15`).

**In scope**
- A new backend `SoCTbBackend` (in the submodule) that emits one cocotb environment (`tb_top.sv`, `Makefile`, a default test module, and an importable model-summary `.py`) into `$HOME_SP/build_soc/verification/` for the top-level module.
- A default test battery, generated from the model: clock/reset bring-up, boot-to-marker smoke, bus/target enumeration, per-region register read (PID/CID identity where the model carries reset values), per-writable-memory walk, IRQ smoke.
- For the bus battery on a top that exposes only a HOSTIO4 **pad** interface (the default multicore SoC — see §4.4): the generated `tb_top.sv` must also instantiate an in-TB `hostio4_target` host bridge and wire it to the DUT's `hostio4_p1_{in,out,outen}` pads, then expose `axis_rx0_*`/`axis_tx0_*` *as TB signals* for the ADP driver — mirroring the hand-written `cocotb/soc_multicore_hostio4/tb_top.sv`. This bridge emission is part of the M4 design (it is **not** optional hand-waving; see §5.4).
- Reuse of the existing `protocol_utils.py` signal tables and `bus_member_names()` to drive boundary tie-off and (optionally) per-protocol BFM stubs.
- Wiring the generated env into the existing **superproject** `cocotb/` regression Makefile and a small generator-level pytest in the submodule (`nanosoc_gen/tests/`).

**Out of scope**
- A general SystemVerilog UVM testbench generator. The live CI is cocotb-first (see §4); UVM (`uvm/Makefile`) has only one real env (`soc_top`) and two stubs. We target cocotb. A UVM path is noted as an alternative in §9 but not designed here.
- Protocol-correct, timing-accurate AHB/APB master BFMs written from scratch. We reuse the existing **HOSTIO4/ADP debug-initiator transport** (`verification/cocotb/nanosoc_cocotb_driver.py`) as the bus access mechanism where the SoC exposes a HOSTIO4 path, and fall back to UART-marker smoke where it does not. **Important:** the multicore top does *not* expose `axis_rx0/axis_tx0` ADP ports directly — it exposes a 7-pin `hostio4_p1_{in,out,outen}` pad bus (verified, §4.4). The ADP transport is reached by the generated TB *instantiating* a `hostio4_target` host bridge inside `tb_top.sv` (the bridge converts the pad bus to `axis_rx0/axis_tx0`). That bridge wiring is in scope (M4); writing native AHB/APB bus BFMs is a stretch goal (M6).
- Changing the model, parser, builder, or any existing backend's output. The TB backend is purely additive and read-only against `top_module`.
- Formal verification (none exists; the CI/validity coverage is tracked in `docs/roadmap/03-ci-system-validity-matrix.md`).

---

## 3. Motivation

**The concrete problem.** Today every cocotb environment under `$HOME_SP/cocotb/<env>/` carries a hand-maintained `tb_top.sv` (~200 lines) that instantiates `nanosoc_multicore_soc` with a specific port list and tie-off set. Verified example: `cocotb/soc_smoke/tb_top.sv` instantiates `u_dut` with ~60 explicit `.port(...)` lines (clock/reset at lines 84-95, `eth_ss_0_*` AHB tie-off 105-115, CPU sideband 117-133, DAP 138-148, RMII/MDIO/UART/PHC/QSPI 155-186). When the model's top-level port list changes — a routine event in this repo (RMII pushed into RTL, multicore reset controller, DMA-250 swap, all in project memory) — **every** `tb_top.sv` must be hand-edited or it fails to elaborate. The superproject `cocotb/` has **42 env directories** (43 entries including `Makefile`), of which **40 carry a `tb_top.sv`** (verified: `find cocotb -name tb_top.sv | wc -l` → 40); the regression Makefile's `ENVS` list activates **27** of them (`cocotb/Makefile:25-35`). There is no single source of truth for the DUT boundary in verification.

The arch_tech generic suite (`verification/cocotb/`) is the opposite failure mode: it has a reusable driver (`NanoSoC`/`ADP`) and model-driven tests (`test_address_map.py` reads the generated `nanosoc_address_map.py`), but per `verification/cocotb/vplan.md` most test states are "Impl" — syntax-verified, never run in sim — and its `TOPLEVEL=nanosoc_tb` is a *different*, older flat-topology top, so it does not exercise the live multicore SoC the CI actually builds.

**Why now.** The generator already emits the design RTL boundary (`SoCTopLevelBackend`, `backends/toplevel.py`), the address map (`backends/python.py` → importable model; `backends/discovery.py` → per-initiator visibility), and the register maps (`backends/rdl.py`). Everything a default testbench needs is already computed and sitting in `top_module`. The only missing piece is a backend that consumes it to emit the TB. This is the cheapest high-leverage backend to add: it closes the boundary-drift gap and turns the "Impl" default tests into something that runs against the real top on every regen.

**What good looks like.** (All `make` invocations run from the **superproject** `$HOME_SP`.)
- `make -C sys_desc` (the existing **superproject** generation entry point) additionally produces `$HOME_SP/build_soc/verification/{tb_top.sv,Makefile,test_default.py,model_summary.py}`.
- A single command — `make -C cocotb soc_generated` (a new **superproject** env that *symlinks or copies* the generated artifacts from `build_soc/verification/`) — boots the current configuration and runs the default battery, passing on a clean SoC.
- Changing a memory size via `--config-override CC_IMEM_RAM_ADDR_W=14` and re-running regenerates the TB *and* the per-region test bounds with zero hand-editing, and the memory walk automatically covers the new size.
- A new SoC variant (different YAML) gets a working smoke testbench for free.

---

## 4. Current state (grounded in the codebase)

### 4.1 The generator pipeline and backend-registration pattern

`soc_model/__main__.py` is a procedural orchestrator. Backends are registered by (a) a static import block and (b) a hand-written construct+call in `main()`:

- Imports: `__main__.py:19-34` (16 `from .backends.X import SoCYBackend`).
- Build dirs created at `__main__.py:128-135` (`rtl/`, `flist/`, `reports/`; others like `firmware/`, `docs/`, `discovery/` created by their backends).
- Backends invoked inline, e.g. toplevel:

```python
# __main__.py:251-257
toplevel_backend = SoCTopLevelBackend(top_module)
toplevel_path = toplevel_backend.generate(rtl_dir, flist_dir)
if toplevel_path:
    print(f"  Generated: {toplevel_path}")
```

There is **no `Backend` ABC, no registry, no plugin discovery** — adding a backend means editing these two spots. (Confirmed; see also gen-core research and `02-clean-architecture-adapters-backends.md` for the proposed refactor.) The TB backend follows the same additive pattern; if doc 02 lands first, it instead registers via the new mechanism.

### 4.2 The model has everything a TB needs

`Module` (`nanosoc_gen/soc_model/model.py:363-382`) carries:
- `clocks: List[Clock]` — `Clock(name, source, desc)` (`model.py:24`). Top YAML (superproject `$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml:189`): `sys_fclk, source: external`.
- `resets: List[Reset]` — `Reset(name, active, source, desc)` (`model.py:32`), `active` ∈ `low`/`high`. Top YAML (`$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml:196`): `sys_sysresetn, active: low, source: external`.
- `interfaces: List[Interface]` — `Interface(name, type, direction, params, desc)` (`model.py:59`) with `.is_input`/`.is_output`/`.is_bidirectional`, `.width`/`.addr_width`/`.data_width` properties (`model.py:68-101`).
- `interconnects: List[Interconnect]` — each `Interconnect.targets: [InterconnectTarget]` (`model.py:154-169`) with `name`, `instance`, `base`, `size`, `sw_access`, `region_type`, `protocol`, and an optional `register_map` reference (top-level targets carry the regmap path directly — see §5.3); and `.initiators: [InterconnectInitiator]` (`model.py:179`) with per-initiator `targets` + `visibility`.
- Register maps are reachable two ways (§5.3 details the traversal): (a) for the top-level matrix, via the target's `register_map` YAML reference resolved into a `RegisterMap`; (b) inside subsystems, via `Module.address_decode` (a single `Optional[AddressDecode]`, `model.py:386`) → `AddressDecode.slots[]` (`model.py:261`) → `AddressDecodeSlot.resolved_register_map` (`model.py:250`).

### 4.3 The exact artifact to emit already exists by hand

`$HOME_SP/cocotb/soc_smoke/tb_top.sv` (a superproject file) is the template-shaped target. Its structure:

```systemverilog
// tb_top.sv:20-35 — clock + reset generation
parameter FCLK_PERIOD_NS = 10;          // 100 MHz
reg sys_fclk;  initial sys_fclk = 1'b0;
always #(FCLK_PERIOD_NS/2) sys_fclk = ~sys_fclk;
reg sys_sysresetn;
initial begin sys_sysresetn = 1'b0; #200; sys_sysresetn = 1'b1; end
```

```systemverilog
// tb_top.sv:84-95 — DUT instantiation with config override + clk/rst
nanosoc_multicore_soc #( .ETH_IMEM_MEM_FPGA_IMG ("sim_build/image.hex") ) u_dut (
    .sys_fclk(sys_fclk), .sys_sysresetn(sys_sysresetn),
    .sys_scanenable(1'b0), .sys_testmode(1'b0), ...
```

Every input is tied to a constant (`1'b0`, `32'h0`, `4'hF`) and every output to a probe `wire`. This is exactly what `_build_ports()` already knows: input vs output is `Interface.is_input`, and the per-bit width comes from the same `protocol_utils` tables `_build_ports` uses (`toplevel.py:125-177`).

### 4.4 The bus access transport — and the pad-vs-axis reality (load-bearing)

The submodule's `verification/cocotb/nanosoc_cocotb_driver.py` (`NanoSoC` class) drives bus reads/writes over **HOSTIO4 channel 0** running the ADP ASCII protocol:

```python
# nanosoc_cocotb_driver.py:83-92
async def read32(self, address: int) -> int:
    await self._adp_command(f"A0x{address:08X}\n")
    resp = await self._adp_command("R\n")
    return self._parse_hex(resp)
async def write32(self, address: int, data: int):
    await self._adp_command(f"A0x{address:08X}\n")
    await self._adp_command(f"W0x{data:08X}\n")
```

**Critical detail — the driver expects `axis_*` as *DUT-level* signals, but the multicore top does not have them.** The driver references `self.dut.CLK`, `self.dut.NRST`, `self.dut.axis_rx0_tvalid/_tdata8/_tready`, `self.dut.axis_tx0_tvalid/_tdata8/_tready` (verified: `nanosoc_cocotb_driver.py:53-66,131-145`). On the *flat* `nanosoc_tb` top (the `verification/cocotb` `TOPLEVEL`) those ARE DUT ports. But on the **live `nanosoc_multicore_soc` top**, the boundary is a **7-pin HOSTIO4 pad bus**, not ADP streams (verified against `$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml:318-320`):

```yaml
- { name: hostio4_p1_in,    type: wire, direction: in,  params: { WIDTH: 7 }, desc: "HOSTIO4 P1[6:0] pad inputs (host -> SoC)" }
- { name: hostio4_p1_out,   type: wire, direction: out, params: { WIDTH: 7 }, desc: "HOSTIO4 P1[6:0] pad outputs (SoC -> host)" }
- { name: hostio4_p1_outen, type: wire, direction: out, params: { WIDTH: 7 }, desc: "HOSTIO4 P1[6:0] pad output-enables" }
```

The ADP `axis_rx0/axis_tx0` signals the driver touches belong to a **separate, in-testbench `hostio4_target u_hostio4_host` instance** that the hand-written env wires to the DUT pads — they are TB signals, not DUT ports. Verified in `$HOME_SP/cocotb/soc_multicore_hostio4/tb_top.sv`:

```systemverilog
// tb_top.sv:86-99 — tri-state pad mesh between DUT pads and a host P1 bus
wire [6:0] hostio4_p1_in, hostio4_p1_out, hostio4_p1_outen;
// ... generate assign P1[gi] = hostio4_p1_outen[gi] ? hostio4_p1_out[gi] : 1'bz;
assign hostio4_p1_in = P1;

// tb_top.sv:121-159 — the in-TB host bridge that EXPOSES the axis_* signals
reg  axis_rx0_tvalid; reg [7:0] axis_rx0_tdata8; wire axis_rx0_tready;
wire axis_tx0_tvalid; wire [7:0] axis_tx0_tdata8; reg axis_tx0_tready;
hostio4_target u_hostio4_host (
    .axis_rx0_tready(axis_rx0_tready), .axis_rx0_tvalid(axis_rx0_tvalid), .axis_rx0_tdata8(axis_rx0_tdata8),
    .axis_tx0_tready(axis_tx0_tready), .axis_tx0_tvalid(axis_tx0_tvalid), .axis_tx0_tdata8(axis_tx0_tdata8),
    /* ... P1 pad side wired to hostio4_p1_* ... */ );

// tb_top.sv:264-265 — DUT instantiated with PADS, not axis
.hostio4_p1_in(hostio4_p1_in), .hostio4_p1_out(hostio4_p1_out), .hostio4_p1_outen(hostio4_p1_outen),
```

**Consequence for this design:** a naive `_access_mode()` that scans `top_module.interfaces` for `axis_rx*`/`axis_tx*` returns `none` on the real top (those names are not interfaces), so the bus battery would silently SKIP on the very SoC it must exercise. §5.4 fixes this: the backend detects the **pad** interface (`type=='wire'`, name `hostio4_p1_*`), emits the `hostio4_target` bridge + tri-state mesh into `tb_top.sv`, and presents `axis_rx0/axis_tx0` as TB signals so the vendored driver connects unchanged at the TB scope. The driver's `dut.CLK`/`dut.NRST` references are also handled there (§5.4: the generated TB aliases the model clock/reset names to `CLK`/`NRST` or the driver is instantiated against the right scope).

And the model-driven test pattern already exists in the generic suite (`test_address_map.py`, submodule `verification/cocotb/`):

```python
# test_address_map.py:210-230 — probe every debug-visible region
regions = ADDRESS_MAP.get_regions(initiator="debug")
for region in regions:
    val = await soc.read32(region.base)   # bus responded OK
```

`test_address_map.py:53-70` hard-codes the peripheral list and memory regions — **the exact hard-coding this backend removes** by deriving them from the model.

### 4.5 The CI / regression harness to plug into

The **superproject** `cocotb/Makefile` defines `ENVS` (`:25-35`, **27 envs**) and a `regression` target (`:79-118`) that, per env, runs `make -C <env>` and reads `<env>/results.xml`: `<failure>` absent → PASS. Each env's `Makefile` (`cocotb/soc_smoke/Makefile`) is boilerplate: `SIM=vcs`, `TOPLEVEL=tb_top`, `VERILOG_SOURCES=$(CURDIR)/tb_top.sv`, `NANOSOC_MULTICORE_HOME ?= $(realpath $(CURDIR)/../..)` (= `$HOME_SP`, `:15`), an expanded flist built by `scripts/expand_flist.sh` from `$HOME_SP/flist/nanosoc_multicore.flist` (`:58-60`), `+CODEFILENAME=$(FIRMWARE_HEX)`, `+define+RAM_PRELOAD`, plus `convert_firmware_hex`/`install_bootrom` hooks. This Makefile is **highly templatable** — only `TOPLEVEL`, `MODULE`, `FIRMWARE_HEX`, and the flist path vary.

The superproject `.gitlab-ci.yml` runs `make -C cocotb regression` in the `cocotb_regression` stage. Adding the generated env to `ENVS` makes it part of CI automatically. (The CI/testing roadmap docs that orchestrate this matrix are `docs/roadmap/03-ci-system-validity-matrix.md` and `docs/roadmap/01-unit-testing-nanosoc-gen.md` — cross-linked in §10.)

### 4.6 The interface library (`lib/interfaces/*`) is documentation-only today

`lib/interfaces/ahb_slave.yaml` etc. declare protocol/role/signals, but `parser.parse_interface_definition` has **zero call sites** and the advertised `!include` tag is never registered (yaml-format research; confirmed). The *real* signal source of truth is the Python tables in `protocol_utils.py` (`AHB_TARGET_SIGNALS`, `GPIO_SIGNALS`, etc.) + `bus_member_names()`. **The TB backend must use `protocol_utils`, not the YAMLs**, to stay consistent with the actual generated RTL boundary. (If `02-clean-architecture-adapters-backends.md` makes `lib/interfaces` the single source of truth, the TB backend reads from whatever `protocol_utils` exposes — the call surface stays `bus_member_names()` / the signal tables.)

---

## 5. Proposed design

### 5.1 Approach in one picture

```
                         top_module (model.py)
                         clocks/resets/interfaces/interconnects/regmaps
                                   │
                                   ▼
                       ┌───────────────────────┐
                       │   SoCTbBackend         │  backends/tb.py
                       │  (read-only walk)      │
                       └───────────┬───────────┘
              ┌────────────────────┼────────────────────────┐
              ▼                    ▼                          ▼
   tb_top.sv (Jinja2)     test_default.py (Jinja2)   model_summary.py (string)
   clock/reset gen        @cocotb.test() battery      ADDRESS_MAP-like dict:
   DUT inst + tie-offs    imports model_summary       targets[], initiators[],
   probe wires +          + reuses NanoSoC driver     regmaps[], irqs[], clk/rst,
   hostio4_target bridge  (at TB scope, see 5.4)      ACCESS_MODE
   (pad<->axis, see 5.4)         │                          │
              └──────────┬───────┴──────────────────┬──────┘
                         ▼                           ▼
       $HOME_SP/build_soc/verification/   +  Makefile (Jinja2, copy of env boilerplate)
                         │                    (superproject build tree)
                         ▼
   $HOME_SP/cocotb/soc_generated/  ── symlink/copy ──►  make -C cocotb soc_generated
                  (superproject shim)                     (added to ENVS → CI)
                         │
                         ▼
                     results.xml
```

### 5.2 Why cocotb, why these artifacts

- **cocotb, not UVM**: the live CI regression is cocotb (the superproject `cocotb/Makefile`, 27 envs in `ENVS`); UVM is mostly stubs. Reusing the cocotb harness means the generated env is a first-class CI citizen with zero new infrastructure.
- **`model_summary.py`, not re-reading discovery YAML at test time**: the tests must self-check against the *same* model that built the RTL. We emit a small importable Python module (a focused subset of what `backends/python.py` already does, but flat and test-friendly — base/size/access/region_type/regmap-identity/IRQ per target) so the test file is configuration-independent. This mirrors how `test_address_map.py:32` imports `nanosoc_address_map`, but self-contained in the env so there is no `SOCLABS_PROJECT_DIR` path dependency.
- **Jinja2 for `tb_top.sv`/`Makefile`/`test_default.py`**: consistent with `toplevel.py`/`firmware.py`/`docs.py`. Guard `if Environment is None: return None` exactly like the other template backends (`toplevel.py:53-55`).
- **Reuse `NanoSoC` driver, don't reinvent**: copy `nanosoc_cocotb_driver.py` into the generated env (or reference it via `PYTHONPATH`) and select the access strategy from the model (see 5.4).

### 5.3 The default test battery (model-derived)

Each test is generated *only if* the model supports it (graceful degradation), and is tagged with a vplan-style ID so it maps onto `verification/cocotb/vplan*.md` conventions.

| ID | Test | Derived from | Mechanism | Pass condition |
|----|------|--------------|-----------|----------------|
| `TBGEN_CLK_001` | Clock/reset bring-up | `clocks[0]`, `resets[*]` | toggle clock, deassert reset, sample a known output goes non-X | reset releases, clock stable, no X on `sys_hresetn`/probe outputs |
| `TBGEN_BOOT_001` | Boot-to-marker smoke | UART iface present + firmware | sample `uart_txd`, decode baud (reuse `collect_uart` from `test_soc_smoke.py:37`) | `hello`/boot marker observed (configurable target string) |
| `TBGEN_ENUM_001` | Bus/target enumeration | `interconnects[*].initiators[*].targets` + `targets[].base` | `NanoSoC.read32(base)` (via the in-TB `hostio4_target` bridge, §5.4) for each debug-visible target | every read completes (bus responds, no hang) |
| `TBGEN_REG_001` | Per-region register identity | targets that resolve to a `RegisterMap` carrying PID/CID `Register`s with `reset_value` set (traversal in §5.3.1) | read PID0–3 (`base+0xFE0..0xFEC`) / CID0–3 (`base+0xFF0..0xFFC`) | matches model's `Register.reset_value` for those regs; else degrades to "reads complete" (see Decisions + §9) |
| `TBGEN_MEM_001` | Memory walk | targets with `region_type=='memory'` and `'w' in sw_access` | write/read boundaries (base, base+4, top) + N random within `size` | read-back == written |
| `TBGEN_IRQ_001` | IRQ smoke | top-level `wire` outputs named `*_irq`/`*irq*` + targets with interrupt-bearing regmaps | trigger source via a regmap write where possible, else passive observe that line is not stuck-X | IRQ line observable and not X after reset |

Decisions:
- **`TBGEN_ENUM_001`/`TBGEN_REG_001`/`TBGEN_MEM_001` require a bus access path** (HOSTIO4/ADP). The detection is on the **HOSTIO4 pad interface**, not on `axis_*` (the real top has no `axis_*` ports — §4.4). If the top exposes `hostio4_p1_{in,out,outen}` (`ACCESS_MODE='adp'`), the backend emits the `hostio4_target` bridge (§5.4) and these tests run. If the top has neither HOSTIO4 pads nor any other recognised bus path (`ACCESS_MODE` in `{'uart','none'}`), they are emitted as **skipped** tests (`@cocotb.test(skip=True)` with a reason), so the file always imports and the env always produces a `results.xml`. The clock/reset + boot smoke always run.
- **PID/CID identity** uses the *model's* reset values, not the hard-coded CMSDK constants in `test_address_map.py:40`. A regmap qualifies only if the model carries `Register.reset_value` for its PID/CID registers (`model.py:223`; this is the same field `rdl.py:250-251` emits as `reset = …`). Where present we assert those; where absent we fall back to "register reads complete" — see §9 / open question #2 for why this fallback materially limits net-new value over the existing hard-coded test, and the optional CMSDK fallback table.
- **IRQ smoke is deliberately weak** (observe-not-X / triggerable-where-possible). A correct IRQ test needs firmware that arms the source and an NVIC-served assertion; that is per-SoC and out of scope. The generated test documents this and provides the hook (a list of IRQ nets + their candidate source regmaps) for a human to strengthen.

#### 5.3.1 Target → register-map traversal (the load-bearing derivation for `TBGEN_REG_001`)

The reviewer correctly flagged that `resolved_register_map` lives on `AddressDecodeSlot` (`model.py:250`), **not** on `InterconnectTarget`. There are two distinct ways a target acquires a register map, and `_collect_targets()` must handle both:

1. **Top-level matrix target with a direct `register_map:` reference.** In `$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml` the top interconnect's targets carry the regmap path inline, e.g. (verified, `:1650`):
   ```yaml
   - { name: evt_route_0, instance: u_evt_route_0, base: 0x2B000000, size: 0x01000000, ..., register_map: register_maps/evt_route_ctrl.yaml, ... }
   ```
   The parser resolves that path into a `RegisterMap` object. `_collect_targets()` reads the resolved map off the target (the field the parser populates) — `target.register_map`/its resolved form — and pulls `RegisterMap.registers` (`model.py:237`).

2. **Subsystem-internal target (no direct ref on the top target).** Most top targets (`timer_0`, `uart_0`, …) live *inside* a subsystem `Module` whose own `Module.address_decode` (`model.py:386`, a single optional `AddressDecode`) holds the slots. Traversal: top `InterconnectTarget.instance` → the child `Module` for that instance → `child.address_decode.slots[]` → match `AddressDecodeSlot` by name/offset → `slot.resolved_register_map`. Note the top-level multicore `Module.address_decode` is itself typically `None` (the matrix is expressed via `interconnects`, and per-peripheral decode lives in subsystems), so REG identity at the default top is only available for targets that either (a) carry a direct top-level `register_map:` or (b) are reachable through an instantiated child module whose model the generator has resolved.

`REGMAPS` in `model_summary.py` is therefore keyed by target name and holds only the regmaps that resolve via (1) or (2) **and** carry PID/CID `Register`s with non-`None` `reset_value`. Targets that resolve to a map without reset values are recorded with `regmap=None` and downgrade to "reads complete" in `TBGEN_REG_001`. The `_collect_targets()`/`REGMAPS` derivation is implemented (not "…") as: for each top target, try (1); on miss, resolve the child module and try (2); filter PID0–3/CID0–3 by `reset_value is not None`; emit `{name, base, size, access, region_type, regmap}`.

### 5.4 Bus-access strategy selection + HOSTIO4 host-bridge emission (model-driven)

```
has HOSTIO4 pad bus (hostio4_p1_in/out/outen ifaces)?
  ├─ yes → ACCESS=adp : emit hostio4_target bridge in tb_top.sv;
  │                     full battery via NanoSoC.read32/write32 at TB scope
  └─ no  → has axis_rx0/axis_tx0 ADP ports directly on the DUT (flat-top variant)?
            ├─ yes → ACCESS=adp_direct : wire driver straight to DUT axis ports
            └─ no  → has uart iface?
                      ├─ yes → ACCESS=uart : clock/reset + boot smoke; bus tests skipped
                      └─ no  → ACCESS=none : clock/reset bring-up only
```

Detection is a model query over `top_module.interfaces`:
- **`hostio4_p1_in`/`hostio4_p1_out`/`hostio4_p1_outen`** present (the default multicore top — `type=='wire'`, 7-bit) → `ACCESS_MODE='adp'` **and** `HOSTIO4_BRIDGE=True`.
- else **`axis_rx*`/`axis_tx*`** present as actual DUT ports (the flat `nanosoc_tb`-style top) → `ACCESS_MODE='adp_direct'`, no bridge.
- else `uart_txd` or a `uart`-typed iface → `ACCESS_MODE='uart'`.
- else `ACCESS_MODE='none'`.

`ACCESS_MODE` (and `HOSTIO4_BRIDGE`) are recorded in `model_summary.py` so the test file branches on data, not on regeneration-time logic.

**HOSTIO4 host-bridge emission (the part the previous draft hand-waved).** When `HOSTIO4_BRIDGE` is set, `tb_top.sv.j2` must emit — *in addition to* the DUT instantiation — the exact structure proven in `$HOME_SP/cocotb/soc_multicore_hostio4/tb_top.sv:73-159,264-265`:

1. `wire [6:0] hostio4_p1_in, hostio4_p1_out, hostio4_p1_outen;` and a `genvar` tri-state mesh `assign P1[gi] = hostio4_p1_outen[gi] ? hostio4_p1_out[gi] : 1'bz; assign hostio4_p1_in = P1;` so the host and SoC share a bidirectional 7-pin pad bus.
2. TB-scope ADP signals `axis_rx0_tvalid/_tdata8/_tready`, `axis_tx0_tvalid/_tdata8/_tready` (the names the vendored driver expects).
3. An instance `hostio4_target u_hostio4_host (.axis_rx0_*(...), .axis_tx0_*(...), <P1 pad side> );`.
4. The DUT wired to **pads**: `.hostio4_p1_in(hostio4_p1_in), .hostio4_p1_out(hostio4_p1_out), .hostio4_p1_outen(hostio4_p1_outen)`.

`hostio4_target` is an existing RTL module, but it is **NOT on `flist/nanosoc_multicore.flist`** — `soc_multicore_hostio4` compiles it by adding its five source files explicitly in its env Makefile (`cocotb/soc_multicore_hostio4/Makefile:22-28`, `VERILOG_SOURCES = $(NANOSOC_MULTICORE_HOME)/nanosoc_arch_tech/rtl/hostio4/target_rtl/{hostio4_target_sync,hostio4_target_fsm,hostio4_target_axis_rxport,hostio4_target_axis_txport,hostio4_target}.v`). The generated `Makefile` (`tb_Makefile.j2`) must therefore append the **same five sources** to `VERILOG_SOURCES` whenever `HOSTIO4_BRIDGE` is set — this is a documented context flag (`HOSTIO4_TARGET_SOURCES`) in the template, not an assumption that the flist already carries it. The vendored `NanoSoC` driver also references `dut.CLK`/`dut.NRST`; because those are not the multicore top's port names (`sys_fclk`/`sys_sysresetn`), the generated TB declares top-level aliases `wire CLK = sys_fclk; wire NRST = sys_sysresetn;` (or the env passes the driver an explicit handle to the TB scope). This is recorded as `CLK_ALIAS`/`NRST_ALIAS` in `model_summary.py` so the driver attaches without editing it. **Net effect:** the driver is vendored *unchanged* (per §2), and all `dut.axis_*`/`dut.CLK`/`dut.NRST` it touches resolve at the `tb_top` scope where the bridge and aliases live.

### 5.5 Boundary tie-off generation (the drift killer)

For `tb_top.sv`, iterate `_build_ports()`-equivalent expansion (reuse the *same* `protocol_utils` tables `toplevel.py` uses so the TB boundary cannot drift from the RTL boundary):

- For each expanded port `(name, direction, width)`:
  - **input** → tie to a constant. Default `1'b0` / `{width{1'b0}}`. Special-cases come from a small, documented **exact-name** dict `_TB_INPUT_TIEOFFS`, mirroring the proven `cocotb/soc_smoke/tb_top.sv` exactly: `dap_swj_enable=1'b1`, `dap_swditms=1'b1`, `dap_ntrst=1'b1` (DAP held idle but the chiplet "active" — `soc_smoke:139,145,147`), `qspi_io_i=4'hF` (`soc_smoke:184`). A port whose name matches the clock name is driven by the TB clock; a reset name by the TB reset. **There is no blanket `*_enable` suffix rule** — it would be wrong: `cpu_0_pmuenable`/`cpu_1_pmuenable` are tied `1'b0` in `soc_smoke:98-99`, so a `_enable→1'b1` heuristic would drive both PMU enables high. Enables that must be 1 are named explicitly (the `*swj_enable`-style debug enables); everything else, including `*pmuenable`, takes the default `1'b0`. The **only** safe suffix rule is `*hready → 1'b1` (AHB inputs must signal ready); even this is applied only to `input` ports whose name ends in `hready`/`hreadyin`. Any future "must be 1" enable is added to the exact-name dict, never inferred from `_enable`.
  - **output** → declare a probe `wire` and connect.
  - **inout** → declare a `wire`, leave undriven (or a pullup) — flagged in a comment.
- Config overrides: pass through the same `--config-override` values the build used (e.g. `.ETH_IMEM_MEM_FPGA_IMG("sim_build/image.hex")`), driven from a small `tb_overrides` context entry.

Before/after for boundary maintenance:

```
BEFORE: change top-level port list (e.g. add rmii_*) →
        hand-edit cocotb/soc_smoke/tb_top.sv AND the other ~39 tb_top.sv files
        (40 total across the superproject cocotb/ envs).

AFTER:  make -C sys_desc  → $HOME_SP/build_soc/verification/tb_top.sv regenerated
        with the new ports tied off automatically; soc_generated env always elaborates.
        Hand envs that need bespoke stimulus can still exist, but the *smoke*
        boundary is generated and never drifts.
```

### 5.6 What this does NOT replace

Bespoke envs (`soc_multicore_ipc`, `soc_eth_loopback_ptp`, etc.) keep their hand-written `tb_top.sv` because they need real PHY models, flash VIP, SWD bit-bang drivers, etc. The generated env is the **default smoke + enumeration env** that proves the boundary and the address map for *any* config. It is one new env, additive to `ENVS`.

---

## 6. Implementation plan (milestones)

Each milestone is independently shippable and reviewable.

### M1 — `SoCTbBackend` skeleton + generated `tb_top.sv` (boundary only)

**Changes.** New `nanosoc_gen/soc_model/backends/tb.py` (submodule) with `SoCTbBackend(top_module)` and `generate(out_dir, config_overrides=None) -> Optional[Path]`. New template `backends/templates/tb_top.sv.j2`. Emit only the clock/reset gen + DUT instantiation + tie-offs (no tests yet), including the `hostio4_target` bridge + pad mesh when `HOSTIO4_BRIDGE` is set (§5.4). Register in `nanosoc_gen/soc_model/__main__.py` (import + call block writing to `build_dir / 'verification'`, which resolves to `$HOME_SP/build_soc/verification/` under the superproject `make -C sys_desc` flow).

**Why.** The boundary-drift fix is the single biggest win and is self-contained. Producing a `tb_top.sv` that elaborates against the current RTL is provable on its own.

**Acceptance.** `make -C sys_desc` produces `$HOME_SP/build_soc/verification/tb_top.sv`. Diffing the generated file's DUT `.port(...)` set against the hand-written `$HOME_SP/cocotb/soc_smoke/tb_top.sv` shows the same DUT-port set (order may differ; note the generated file additionally carries the `hostio4_target` bridge that `soc_smoke` omits because soc_smoke is UART-only). A throwaway VCS elaborate (`vcs -sverilog tb_top.sv -f <expanded flist>`) compiles with no UPIMI/port-mismatch errors.

### M2 — `model_summary.py` emitter + clock/reset bring-up test

**Changes.** Extend `tb.py` to emit `model_summary.py` (flat dicts: `CLOCKS`, `RESETS`, `TARGETS`, `INITIATORS`, `REGMAPS`, `IRQS`, `ACCESS_MODE`). New template `backends/templates/tb_test_default.py.j2` containing `TBGEN_CLK_001` (clock/reset bring-up). Emit `test_default.py`.

**Why.** The summary module is the contract every later test imports; shipping it with the simplest always-runnable test proves the import path and the clock/reset sequence end-to-end.

**Acceptance.** Generated `test_default.py` imports `model_summary` and runs `TBGEN_CLK_001` to PASS in a manual cocotb run (see M4 for the env). `model_summary.TARGETS` matches `build_soc/reports/<top>_memory_map.txt` bases/sizes.

### M3 — generated `Makefile` + `cocotb/soc_generated` env wiring

**Changes.** New template `backends/templates/tb_Makefile.j2` (parameterised copy of the superproject `cocotb/soc_smoke/Makefile`: `TOPLEVEL=tb_top`, `MODULE=test_default`, flist path = `$HOME_SP/flist/nanosoc_multicore.flist`, `FIRMWARE_HEX`, `convert_firmware_hex`/`install_bootrom` hooks kept; **plus the five `hostio4_target` RTL sources appended to `VERILOG_SOURCES` when `HOSTIO4_BRIDGE` is set**, since they are not on the flist — §5.4; this Makefile is emitted into `$HOME_SP/build_soc/verification/`). New **checked-in superproject** env dir `$HOME_SP/cocotb/soc_generated/` containing a tiny `Makefile` that *copies or symlinks* the generated artifacts from `$HOME_SP/build_soc/verification/` — and the submodule driver from `$HOME_SP/nanosoc_arch_tech/verification/cocotb/nanosoc_cocotb_driver.py` — before delegating to the generated cocotb makefile (so generated files are not committed; they regenerate). Add `soc_generated` to the superproject `cocotb/Makefile:ENVS` (`:25-35`).

**Why.** Connects the generated TB to the live regression harness with no change to existing envs.

**Acceptance.** `make -C cocotb soc_generated` boots the SoC and `TBGEN_CLK_001` (+ `TBGEN_BOOT_001` if M5 done) passes; `cocotb/soc_generated/results.xml` has no `<failure>`. `make -C cocotb regression` includes it in the summary.

### M4 — bus enumeration + per-region register read (`TBGEN_ENUM_001`, `TBGEN_REG_001`)

**Changes.** Two coupled pieces: **(a)** emit the in-TB `hostio4_target` bridge + tri-state pad mesh + `CLK`/`NRST` aliases in `tb_top.sv.j2` when `HOSTIO4_BRIDGE` is set (§5.4) — this is what gives the vendored driver an `axis_rx0/axis_tx0` to attach to on the pad-bus top; **(b)** vendor `nanosoc_cocotb_driver.py` *unchanged* into the generated env (the shim copies it from `$HOME_SP/nanosoc_arch_tech/verification/cocotb/`). Extend `tb_test_default.py.j2` with the enumeration loop (over `model_summary.TARGETS` visible to the debug initiator) and PID/CID identity (over `REGMAPS` carrying PID/CID with reset values — §5.3.1). Implement HOSTIO4-pad detection → `ACCESS_MODE`/`HOSTIO4_BRIDGE` and `@cocotb.test(skip=...)` gating.

**Why.** This is the address-map regression that `test_address_map.py` does today but with hard-coded values; here it is config-derived. The bridge emission (a) is non-negotiable for the default multicore top: without it `_access_mode()` would see no `axis_*` and the whole battery would SKIP (the precise failure the §4.4 review caught).

**Acceptance.** On the multicore SoC (which exposes the `hostio4_p1_*` pad bus — verified §4.4, and `soc_multicore_hostio4` proves the bridge pattern), the generated `tb_top.sv` elaborates *with* the `hostio4_target` instance, `ACCESS_MODE=='adp'`, and the vendored driver attaches at TB scope; `TBGEN_ENUM_001` reads every debug-visible target without hang; `TBGEN_REG_001` matches model `Register.reset_value` for PID/CID where present (else SKIP-with-reason / degrade to "reads complete" per §5.3.1). Changing `--config-override` for a memory size and regenerating updates the bounds and still passes.

### M5 — boot smoke + memory walk (`TBGEN_BOOT_001`, `TBGEN_MEM_001`)

**Changes.** Add `collect_uart`/`uart_rx_byte` (lifted from the superproject `cocotb/soc_smoke/test_soc_smoke.py:23-51`) to the generated test (or a vendored `tb_uart.py` helper). `TBGEN_BOOT_001` decodes UART and asserts a configurable marker (default the firmware's expected banner). `TBGEN_MEM_001` walks each writable memory target (boundaries + random within `size`), reusing the `test_address_map.py:140-195` pattern but model-derived.

**Why.** These are the two highest-value functional smokes and reuse proven code.

**Acceptance.** `TBGEN_BOOT_001` passes with the default `hello_uart` firmware; `TBGEN_MEM_001` passes write-read-back on every model `region_type==memory && 'w' in sw_access` target.

### M6 — IRQ smoke + generator pytest + vplan emission (hardening)

**Changes.** `TBGEN_IRQ_001`: collect top-level `wire` outputs matching `*irq*` and targets with interrupt regmaps; emit an observe-not-X test plus a triggerable variant where a regmap write can assert the source. Add **`nanosoc_gen/tests/test_tb_backend.py`** — a **pure-pytest generator test** (no EDA tool, no cocotb) that builds a tiny fixture `Module` and asserts the backend emits `tb_top.sv`/`test_default.py`/`model_summary.py`/`Makefile` with expected ports/targets/`ACCESS_MODE`. **Note (new infrastructure):** there is currently **no** pure-pytest generator-test directory in `nanosoc_gen`; the existing `test_discovery.py`/`test_systable.py`/`test_address_map.py` are **cocotb** tests under the submodule `verification/cocotb/`, not pytest generator tests. So `nanosoc_gen/tests/` is created here, and its conventions (fixtures, invocation) are defined by `docs/roadmap/01-unit-testing-nanosoc-gen.md`; this milestone *populates* that lane rather than inventing it standalone. Optionally emit a `vplan_generated.md` mapping the `TBGEN_*` IDs to status (mirrors the submodule `verification/cocotb/vplan.md`).

**Why.** Closes the loop with the unit-testing and CI roadmap docs — `docs/roadmap/01-unit-testing-nanosoc-gen.md` (the generator pytest lane) and `docs/roadmap/03-ci-system-validity-matrix.md` (the config/validity matrix) — and documents coverage. The pytest is the cheap per-commit guard that the backend keeps emitting valid artifacts as the model evolves.

**Acceptance.** `pytest nanosoc_gen/tests/test_tb_backend.py` passes; `TBGEN_IRQ_001` runs (PASS or documented SKIP) on the multicore SoC; `vplan_generated.md` lists all six IDs.

---

## 7. File & module changes

### New files

In the **submodule** (`nanosoc_arch_tech/`):
```
nanosoc_gen/soc_model/backends/tb.py                            # SoCTbBackend
nanosoc_gen/soc_model/backends/templates/tb_top.sv.j2           # M1 (incl. hostio4_target bridge)
nanosoc_gen/soc_model/backends/templates/tb_test_default.py.j2  # M2,M4,M5,M6
nanosoc_gen/soc_model/backends/templates/tb_Makefile.j2         # M3
nanosoc_gen/tests/test_tb_backend.py                            # M6 (pure-pytest generator test)
```

In the **superproject** (`$HOME_SP/`):
```
cocotb/soc_generated/Makefile                                   # M3 (checked-in shim)
```

Generated (NOT committed — land in the superproject build tree `$HOME_SP/build_soc/verification/`):
```
$HOME_SP/build_soc/verification/tb_top.sv
$HOME_SP/build_soc/verification/test_default.py
$HOME_SP/build_soc/verification/model_summary.py
$HOME_SP/build_soc/verification/Makefile
```

### Modified files

- `nanosoc_gen/soc_model/__main__.py` (submodule)
  - Import: add `from .backends.tb import SoCTbBackend` to the block at `:19-34`.
  - Call: after the firmware block (`:259-263`), add:
    ```python
    # --- Testbench generation ---
    print("\n--- Testbench Generation ---")
    tb_backend = SoCTbBackend(top_module)
    tb_dir = build_dir / 'verification'
    tb_path = tb_backend.generate(tb_dir, config_overrides=config_overrides)
    if tb_path:
        print(f"  Generated: {tb_path}")
    else:
        print("  Skipped (jinja2 not available)")
    ```
  - (If `02-clean-architecture-adapters-backends.md` is implemented first, register via the new backend mechanism instead.)
- `$HOME_SP/cocotb/Makefile` (superproject) — add `soc_generated` to `ENVS` (`:25-35`).

### Backend signature & key methods (`backends/tb.py`)

```python
"""Testbench generation backend — emits a cocotb env (tb_top.sv + Makefile +
default test battery + model summary) for the top-level module.

Boundary tie-offs are driven by the SAME protocol_utils tables the
SoCTopLevelBackend uses, so the TB DUT boundary cannot drift from the
generated RTL boundary.
"""
from pathlib import Path
from typing import Any, Dict, List, Optional

from ..model import (
    Module, Interface, InterconnectTarget,
    AddressDecode, AddressDecodeSlot, RegisterMap, Register,
)
from ..utils import write_if_changed
from .protocol_utils import (
    AHB_TARGET_SIGNALS, AHB_INITIATOR_SIGNALS, GPIO_SIGNALS, SWD_SIGNALS,
    DBGAHB_TARGET_SIGNALS, AXIS_SIGNALS, AXIS_BYTE_SIGNALS, bus_member_names,
)

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    Environment = None

_TEMPLATE_DIR = Path(__file__).parent / 'templates'

# The only hand-curated knowledge: input ports that must NOT tie to 0.
# Keyed by EXACT name. Mirrors cocotb/soc_smoke/tb_top.sv verbatim:
#   swj_enable/swditms/ntrst = 1 (DAP idle but chiplet active, soc_smoke:139,145,147)
#   qspi_io_i = 4'hF (soc_smoke:184)
# NOTE: pmuenable is NOT here — soc_smoke ties cpu_{0,1}_pmuenable to 1'b0
# (lines 98-99). There is deliberately NO blanket '_enable' suffix rule, which
# would wrongly drive the PMU enables high. Add future must-be-1 enables HERE
# by exact name, never by suffix.
_TB_INPUT_TIEOFFS = {
    'dap_swj_enable': "1'b1",
    'dap_swditms':    "1'b1",
    'dap_ntrst':      "1'b1",
    'qspi_io_i':      "4'hF",
}
# Only AHB hready inputs are safe to infer by suffix (must signal ready).
_TB_INPUT_TIEOFF_SUFFIXES = {'hready': "1'b1", 'hreadyin': "1'b1"}


class SoCTbBackend:
    def __init__(self, top_module: Module):
        self.top = top_module

    def generate(self, out_dir, config_overrides=None) -> Optional[Path]:
        if Environment is None:
            print("  WARNING: jinja2 not available — skipping TB generation")
            return None
        out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
        env = Environment(loader=FileSystemLoader(str(_TEMPLATE_DIR)),
                          trim_blocks=True, lstrip_blocks=True,
                          keep_trailing_newline=True)
        ctx = self._build_context(config_overrides or {})
        write_if_changed(out_dir / 'tb_top.sv',
                         env.get_template('tb_top.sv.j2').render(**ctx))
        write_if_changed(out_dir / 'model_summary.py', self._emit_model_summary())
        write_if_changed(out_dir / 'test_default.py',
                         env.get_template('tb_test_default.py.j2').render(**ctx))
        write_if_changed(out_dir / 'Makefile',
                         env.get_template('tb_Makefile.j2').render(**ctx))
        return out_dir / 'tb_top.sv'

    # --- boundary expansion (reuses protocol_utils tables) ----------------
    def _expand_ports(self) -> List[Dict[str, Any]]:
        """Same expansion logic as SoCTopLevelBackend._build_ports, but
        annotated with tie-off ('1'b0'/probe) for the TB."""
        ...

    def _tieoff_for(self, name: str, width: int, direction: str) -> str:
        if direction == 'input':
            if name in _TB_INPUT_TIEOFFS:
                return _TB_INPUT_TIEOFFS[name]
            for suf, v in _TB_INPUT_TIEOFF_SUFFIXES.items():
                if name.endswith(suf):
                    return v
            return "1'b0" if width == 1 else f"{{{width}{{1'b0}}}}"
        return None  # output → probe wire

    def _access_mode(self) -> tuple:
        """Returns (ACCESS_MODE, HOSTIO4_BRIDGE). Detects the HOSTIO4 *pad*
        bus on the real multicore top (NOT axis_* — those are not DUT ports;
        see §4.4). Falls back to direct-axis (flat top), uart, or none."""
        names = {i.name for i in self.top.interfaces}
        if {'hostio4_p1_in', 'hostio4_p1_out', 'hostio4_p1_outen'} <= names:
            return ('adp', True)          # emit hostio4_target bridge
        if any(n.startswith('axis_rx') for n in names):
            return ('adp_direct', False)  # flat nanosoc_tb-style top
        if 'uart_txd' in names or any(i.type == 'uart' for i in self.top.interfaces):
            return ('uart', False)
        return ('none', False)

    def _collect_targets(self) -> List[Dict[str, Any]]:
        # For each top interconnect target: base/size/sw_access/region_type,
        # then resolve its register map two ways (see §5.3.1):
        #   (1) target.register_map (top-level direct ref), or
        #   (2) child Module(instance).address_decode.slots[*].resolved_register_map
        # keep PID0-3/CID0-3 Registers whose reset_value is not None.
        ...
    def _collect_irqs(self) -> List[str]: ...                 # *irq* wire outputs
    def _emit_model_summary(self) -> str: ...                 # flat dicts (string build)
    def _build_context(self, overrides) -> Dict[str, Any]: ...
```

### `tb_top.sv.j2` (illustrative — mirrors `soc_smoke/tb_top.sv`)

```jinja
`timescale 1ns/1ps
module tb_top;
    parameter FCLK_PERIOD_NS = {{ clk_period_ns }};
    reg {{ clk_name }};
    initial {{ clk_name }} = 1'b0;
    always #(FCLK_PERIOD_NS/2) {{ clk_name }} = ~{{ clk_name }};
{% for r in resets %}
    reg {{ r.name }};
    initial begin {{ r.name }} = {{ '1' if r.active=='high' else '0' }}'b{{ '1' if r.active=='high' else '0' }};
        #200; {{ r.name }} = {{ '0' if r.active=='high' else '1' }}'b{{ '0' if r.active=='high' else '1' }}; end
{% endfor %}
{% for p in probe_wires %}
    wire {{ p.width_str }} {{ p.name }};
{% endfor %}
    {{ module_name }} #(
{% for o in dut_overrides %}
        .{{ o.name }}({{ o.value }}){{ "," if not loop.last }}
{% endfor %}
    ) u_dut (
{% for c in dut_conns %}
        .{{ c.port }}({{ c.expr }}){{ "," if not loop.last }}
{% endfor %}
    );
`ifdef WAVES
    initial begin $dumpfile("waves.vcd"); $dumpvars(0, tb_top); end
`endif
endmodule
```

### `model_summary.py` (illustrative emitted output)

```python
# AUTO-GENERATED — model summary for testbench self-checks. Do not edit.
ACCESS_MODE = "adp"          # 'adp' | 'adp_direct' | 'uart' | 'none'
HOSTIO4_BRIDGE = True        # emit in-TB hostio4_target (pad-bus top)
CLK_ALIAS = "sys_fclk"       # driver expects dut.CLK -> aliased at TB scope
NRST_ALIAS = "sys_sysresetn" # driver expects dut.NRST -> aliased at TB scope
CLOCKS = ["sys_fclk"]
RESETS = [{"name": "sys_sysresetn", "active": "low"}]
TARGETS = [
    # region_type uses the model's own vocabulary: 'memory' or 'periph'
    # (the top YAML uses 'periph' — 10 occurrences — NOT 'peripheral').
    {"name": "qspi_flash_xip", "base": 0x24000000, "size": 0x04000000,
     "access": "rx", "region_type": "memory", "regmap": None},
    {"name": "phc_0", "base": 0x22000000, "size": 0x01000000,
     "access": "rw", "region_type": "periph",
     # regmap present ONLY if the model carries Register.reset_value for PID/CID;
     # otherwise regmap=None and TBGEN_REG_001 degrades to "reads complete".
     "regmap": {"PID": [0x22, 0x10, 0x00, 0x00], "CID": [0x0D, 0xF0, 0x05, 0xB1]}},
    # ...
]
IRQS = ["eth_irq", "phc_pps_irq", "phc_alarm_irq"]
```

### `cocotb/soc_generated/Makefile` (checked-in shim, M3)

This file is checked in at the **superproject** path `$HOME_SP/cocotb/soc_generated/Makefile`. The `$(CURDIR)/../..` convention therefore resolves to `$HOME_SP` (identical to every existing env, e.g. `cocotb/soc_smoke/Makefile:15`), so `build_soc/verification/` and `nanosoc_arch_tech/verification/cocotb/` are both reachable from here:

```makefile
# $HOME_SP/cocotb/soc_generated/Makefile  (CURDIR/../.. == $HOME_SP)
# Stages the generated TB artifacts from build_soc/verification/, vendors the
# (submodule) ADP driver unchanged, then delegates to the generated Makefile.
NANOSOC_MULTICORE_HOME ?= $(realpath $(CURDIR)/../..)   # == $HOME_SP
GEN    := $(NANOSOC_MULTICORE_HOME)/build_soc/verification
DRIVER := $(NANOSOC_MULTICORE_HOME)/nanosoc_arch_tech/verification/cocotb/nanosoc_cocotb_driver.py
SIM := vcs
TOPLEVEL := tb_top
MODULE   := test_default

stage-artifacts:
	@test -f $(GEN)/tb_top.sv || { echo "Run 'make -C sys_desc' first"; exit 1; }
	@cp $(GEN)/tb_top.sv $(GEN)/test_default.py $(GEN)/model_summary.py $(CURDIR)/
	@cp $(DRIVER) $(CURDIR)/                                  # vendored UNCHANGED

# The generated Makefile (build_soc/verification/Makefile) holds the real
# cocotb include + flist/firmware/bootrom hooks; this shim just stages + delegates.
include $(GEN)/Makefile
sim: stage-artifacts
```

---

## 8. Testing & validation

Validation gradient mirrors the cheapest→most-expensive ladder, and ties into the unit-testing (`docs/roadmap/01-unit-testing-nanosoc-gen.md`) and CI-matrix (`docs/roadmap/03-ci-system-validity-matrix.md`) roadmap docs.

1. **Generator unit test (seconds, M6) — NEW pytest infrastructure.** `pytest nanosoc_gen/tests/test_tb_backend.py`. This directory does not exist today: the current `test_discovery.py`/`test_systable.py`/`test_address_map.py` are **cocotb** tests under the submodule `verification/cocotb/`, not pure-pytest generator tests, so lane 1 is genuinely new infra defined by `docs/roadmap/01-unit-testing-nanosoc-gen.md` and merely *populated* here. Build a minimal fixture `Module` (one clock, one active-low reset, one interconnect with a `region_type='memory'` target + a `region_type='periph'` target carrying a PID/CID `RegisterMap` with `reset_value`s set, a `uart_txd` output, and a `hostio4_p1_{in,out,outen}` **pad** triplet — exercise the pad-bridge path, the real top's shape, NOT a bare `axis_*` pair). Assert:
   - `tb_top.sv` declares the clock `reg`, the reset `reg`, the probe wires for every output, ties the memory's bus inputs, contains the `_TB_INPUT_TIEOFFS` overrides, and — because the fixture has `hostio4_p1_*` — instantiates `hostio4_target` with `axis_rx0/axis_tx0` TB signals + `CLK`/`NRST` aliases.
   - `model_summary.py` imports and `TARGETS`/`ACCESS_MODE` (== `'adp'`) / `HOSTIO4_BRIDGE` (== `True`) match the fixture; `region_type` values are `'memory'`/`'periph'` (not `'peripheral'`).
   - `test_default.py` imports `model_summary` and contains the expected `@cocotb.test()` defs (`TBGEN_*`).
   This is the per-commit guard — runs without any EDA tool.

2. **Elaborate (minutes, M1).** `vcs -full64 -sverilog tb_top.sv -f <expanded flist> <hostio4_target sources>` must compile with no port-mismatch. Note `hostio4_target` is **not** on `flist/nanosoc_multicore.flist`; the generated Makefile adds its five RTL sources from `nanosoc_arch_tech/rtl/hostio4/target_rtl/` (see §5.4), exactly as `soc_multicore_hostio4/Makefile:22-28` does. Equivalent to the existing `--lint` lane (`backends/lint.py`).

3. **Boundary-parity check (M1).** Script-diff the generated `tb_top.sv` DUT `.port(...)` set against `$HOME_SP/cocotb/soc_smoke/tb_top.sv` for the current multicore config; the DUT-port *names* must match exactly (tie-off values may differ for documented special-cases; the generated file additionally carries the `hostio4_target` bridge). This proves the boundary did not drift.

4. **Sim smoke (10s of min, M3-M5).** `make -C cocotb soc_generated` → `results.xml` with no `<failure>`. Then `make -C cocotb regression` includes it. This is the same gate the superproject `.gitlab-ci.yml`'s `cocotb_regression` stage uses, so adding the env to `ENVS` makes it CI-enforced automatically.

5. **Config-sweep validation (M4).** Regenerate with `make -C sys_desc soc_model PARAM_OVERRIDES="--config-override CC_IMEM_RAM_ADDR_W=14"` and confirm `TBGEN_MEM_001` bounds and `model_summary.TARGETS` track the change with no hand-edit. This is the concrete config-matrix hook `03-ci-system-validity-matrix.md` calls out as net-new — the generated TB is the per-config golden artifact.

**Interaction with other docs.** The pytest (lane 1) integrates with `docs/roadmap/01-unit-testing-nanosoc-gen.md` (which defines the generator-pytest lane and `nanosoc_gen/tests/` conventions); the CI env wiring (lane 4) and config sweep (lane 5) integrate with `docs/roadmap/03-ci-system-validity-matrix.md`. This backend produces the artifacts those docs consume, so land the pytest in the suite `01` defines.

---

## 9. Risks, tradeoffs, alternatives

**Risks / failure modes**
- **Tie-off correctness is heuristic.** The `_TB_INPUT_TIEOFFS` dict encodes hand knowledge (`dap_swj_enable`/`swditms`/`ntrst`=1, `hready`=1, `qspi_io_i`=0xF). A wrong default can wedge boot. **Specific trap already avoided:** there is NO `_enable→1` suffix rule, because `cpu_{0,1}_pmuenable` are tied `1'b0` in `soc_smoke:98-99` and a suffix rule would wrongly drive them high (this is exactly the kind of silent-wedge bug the dict's exact-name discipline prevents). Mitigation: default-0 is safe for everything not in the dict; the dict is small, documented, and matched line-for-line against the proven `soc_smoke/tb_top.sv`; the boundary-parity check (testing lane 3) catches missing ports; the boot smoke (TBGEN_BOOT_001) catches a fatally-wrong tie-off.
- **HOSTIO4 access requires emitting an in-TB host bridge (not just a port scan).** The multicore top exposes a 7-pin `hostio4_p1_*` **pad** bus, not `axis_*` ports (verified §4.4). The bus battery therefore depends on the backend emitting a `hostio4_target` instance + tri-state pad mesh + `CLK`/`NRST` aliases inside `tb_top.sv` (§5.4); if that emission is wrong or omitted, `_access_mode()` would see no usable path and the battery SKIPs on the very SoC it must exercise. Mitigation: the M4 acceptance check asserts the `hostio4_target` instance is present and `ACCESS_MODE=='adp'`, and the generator pytest (lane 1) fixture uses the pad triplet to force this path; the bridge structure is copied verbatim from the proven `soc_multicore_hostio4/tb_top.sv:73-159`. Variants with neither pads nor direct `axis_*` correctly degrade to `ACCESS_MODE in {'uart','none'}` (clock/reset + boot only) — weaker but honest, not a false pass.
- **IRQ smoke is shallow.** Without per-SoC firmware it cannot prove NVIC delivery (see project memory: IRQ-served gaps were real bugs). We are explicit that TBGEN_IRQ_001 is observe-not-X + triggerable-where-possible, not a delivery proof. Accepting shallow-but-honest beats a false sense of coverage.
- **REG identity may add little over the existing hard-coded test if reset values are absent.** `TBGEN_REG_001`'s value hinges on the model carrying `Register.reset_value` for PID/CID (open question #2). If reset values are not reliably present, the test degrades to "reads complete" — which is what `test_address_map.py` already does, only with hard-coded constants — so the milestone delivers little net-new on those targets. Mitigation/decision: where the model lacks reset values, *optionally* fall back to a small CMSDK PID/CID table (the very constants in `test_address_map.py:40`) keyed by regmap module name, so CMSDK peripherals still get a true identity check; this fallback is opt-in and documented, not the default, to avoid re-introducing the hard-coding this backend exists to remove. M4 acceptance should record, per target, whether identity ran against model values or fell back.
- **Boot marker is firmware-specific.** TBGEN_BOOT_001's expected string depends on the loaded firmware. Mitigation: make the marker a context variable (default `hello`), settable per env; the test asserts the marker, not a fixed banner.
- **Drift between `_expand_ports` here and `SoCTopLevelBackend._build_ports`.** Two copies of the expansion logic could diverge. Mitigation: both call the *same* `protocol_utils` tables; ideally factor the expansion into a shared helper in `protocol_utils.py` (a one-function refactor) so there is one source — note this overlaps with `02-clean-architecture-adapters-backends.md`'s shared-walk proposal.

**Alternatives considered**
- **UVM TB generation.** Rejected: live CI is cocotb; UVM envs are mostly stubs; a UVM agent generator is far larger (sequencer/driver/monitor/scoreboard per protocol) for less CI value. Could be a later doc once `lib/interfaces/*` become the real protocol source of truth.
- **Generate native cocotb AHB/APB BFM masters** (cocotbext-ahb is already a CI pip dep). Rejected for the default battery because the SoC's AHB/APB never crosses the chip boundary (wrappers research) — there is no top-level bus port to drive; HOSTIO4/ADP is the only debug-initiator path. Native BFMs become relevant only if a future SoC variant promotes bus ports to the top (then this backend can emit a cocotbext-ahb master against that port).
- **Don't vendor the driver; require `PYTHONPATH`.** Rejected as the default (fragile path coupling like `test_address_map.py:28`); copying the driver into the env keeps it self-contained. The driver is vendored **unchanged** — the mismatch between its `dut.CLK`/`dut.NRST`/`dut.axis_*` expectations and the real top's `sys_fclk`/`sys_sysresetn`/pad ports is resolved entirely in the generated TB (the `hostio4_target` bridge + `CLK`/`NRST` aliases, §5.4), not by editing the driver. A `PYTHONPATH` reference to `$HOME_SP/nanosoc_arch_tech/verification/cocotb/` is an acceptable M4 simplification if maintainers prefer a single copy.
- **Emit per-env `tb_top.sv` for all envs.** Rejected: the ~40 bespoke envs need real models/VIP; forcing generation there breaks them. We add one generated env and leave bespoke envs alone.

---

## 10. Dependencies & sequencing

**Builds on**
- The existing model + `protocol_utils` (no changes needed for M1-M5).
- `docs/roadmap/02-clean-architecture-adapters-backends.md` — *optional* dependency. If it lands first, register the TB backend via the new mechanism and consume the shared port-expansion helper instead of duplicating `_expand_ports`. If it lands later, this backend uses the current `__main__.py` import+call pattern and is trivially migrated.
- `docs/roadmap/01-unit-testing-nanosoc-gen.md` — defines the **pure-pytest generator-test lane** and `nanosoc_gen/tests/` conventions that M6's `test_tb_backend.py` plugs into. This is a real dependency for M6 (the directory and harness do not exist today, §8 lane 1); M1–M5 do not need it.

**Unblocks / complements**
- `docs/roadmap/03-ci-system-validity-matrix.md` (the CI / validity-matrix roadmap): this backend produces the cocotb env (`soc_generated`) and the generator pytest that that doc orchestrates into the per-config validity matrix; the config-sweep hook (§8 lane 5) is the concrete net-new artifact it calls for.
- `docs/roadmap/01-unit-testing-nanosoc-gen.md`: M6's `test_tb_backend.py` is one of the generator pytests that doc collects.
- Any future config-sweep harness: the generated `soc_generated` env + `model_summary.py` are the per-config golden artifacts a sweep validates against (replacing the hard-coded expectations in the cocotb `test_discovery.py`/`test_systable.py`/`test_address_map.py` under `verification/cocotb/`).

**Rough effort estimate**
- M1 (boundary `tb_top.sv`): **M** — most of the logic is mirroring `toplevel.py:_build_ports` with tie-off annotation.
- M2 (`model_summary.py` + clk/rst test): **S**.
- M3 (Makefile + env wiring): **S**.
- M4 (enum + reg identity): **M** — model→test derivation + ACCESS_MODE gating.
- M5 (boot + mem walk): **S** — lifts proven code.
- M6 (IRQ + pytest + vplan): **M**.
- **Total: M–L** (~1.5–2.5 weeks for one engineer), front-loaded on M1/M4.

---

## Open questions

1. **HOSTIO4 exposure on the multicore top — RESOLVED (now designed for, §4.4/§5.4).** Verified against `$HOME_SP/sys_desc/nanosoc_multicore_soc.yaml:318-320` and `$HOME_SP/cocotb/soc_multicore_hostio4/tb_top.sv:73-159,264-265`: the current `nanosoc_multicore_soc` top exposes a **7-pin `hostio4_p1_{in,out,outen}` pad bus**, NOT `axis_rx0/axis_tx0` ports. The ADP `axis_*` signals the `NanoSoC` driver drives belong to a separate **in-TB `hostio4_target u_hostio4_host`** instance (`tb_top.sv:147`) wired to the DUT pads. The design therefore *emits* that bridge (§5.4) rather than assuming `axis_*` are DUT ports; `_access_mode()` detects the pads, not `axis_*`. The flat `nanosoc_tb` top (the only place `axis_*` are real DUT ports) is handled by the separate `ACCESS_MODE='adp_direct'` branch. No longer open.
2. **Where PID/CID reset values live for non-CMSDK regmaps — partially open; fallback designed.** Verified: `Register.reset_value` exists (`model.py:223`) and is the field `rdl.py:250-251` emits, and **no** PID/CID offsets are hard-coded in the backends (so identity must come from the model). What remains unconfirmed is whether the *builder reliably populates* `reset_value` for PID/CID `Register`s on the targets we want to identity-check — `test_address_map.py:40` still hard-codes CMSDK CID, and the YAML `identification:` block was historically "NOT read by builder." **Decision (see §9):** where the model carries reset values, assert them; where it does not, either SKIP-with-reason or fall back to an opt-in CMSDK PID/CID table keyed by regmap module name. Confirm builder coverage of `reset_value` before relying on M4's identity assertions as net-new.
3. **Whether `$HOME_SP/build_soc/verification/` collides with anything — appears free; confirm post-processing.** No existing backend writes to `build_dir/'verification'` (backends use `rtl/flist/reports/firmware/docs/discovery/interconnect/rdl` — verified by `ls $HOME_SP/build_soc/`), so the sibling dir is free. Before wiring M1 into the make flow, confirm the **superproject** `sys_desc/Makefile` post-processing (`scripts/patch_ahb_to_apb.py`) is scoped to `rtl/` (it is, per the review's verified note) and does not glob `build_soc/**/*.sv` and rewrite the generated `tb_top.sv`.
