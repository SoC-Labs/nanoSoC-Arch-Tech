# 07 — Top-Level Wrapper Generation (FPGA & ASIC, Technology-Dependent)

> Make a new tech node / pin-count "drop-in configurable": the functional chip boundary comes from the model (it already does), and the *physical* pad ring (real cell names, power pads, tie-offs, UPF skeleton, FPGA tristate wrapper) is synthesised from a small **technology descriptor + pin-assignment map** instead of being hand-authored as a flat Verilog file per tech/pin combo.

---

## 1. Title & summary

This document specifies a generator extension that produces **technology-specific top-level pad wrappers** for both FPGA and ASIC from declarative data. Today the generator emits only a *generic-cell* `nanosoc_chip_pads.v` that no flow consumes, while every real tech variant (`tsmc65lp/{28,44,60}pin`, `tsmc28hpcp/{38pin,no_pads}`, `tsmc16fcll/28pin`) is a hand-written flat Verilog file. The proposal: add a **`SoCPadRingBackend`** driven by a per-tech **pad-tech descriptor** (`pad_tech/<tech>.yaml`) plus a **pin-assignment map** (`pin_map/<tech>_<N>pin.yaml`), so only the cell-name layer + counts + placement + *body structure* become data.

**Important grounding correction (the load-bearing premise):** the six hand files are **not** one uniform body. There are **two distinct file architectures** (verified by grepping the files):

- **Architecture A — `chip_cfg` wrapper, `pad_gpio_portN_*` nets:** `tsmc65lp/44pin`, `tsmc28hpcp/38pin`, `tsmc28hpcp/no_pads`. These instantiate `nanosoc_chip_cfg #(.GPIO_TIO(GPIO_TIO))` *and* `nanosoc_chip` as siblings (e.g. `tsmc65lp/...44pin.v:118` cfg, `:174` chip), wiring pad cells through `pad_gpio_port0_*`/`pad_gpio_port1_*` nets.
- **Architecture B — direct `nanosoc_chip`, `pN_*` nets:** `tsmc65lp/28pin`, `tsmc65lp/60pin`, `tsmc16fcll/28pin`. These instantiate `nanosoc_chip` directly with **no** `nanosoc_chip_cfg` (e.g. `tsmc65lp/...28pin.v:81`, `tsmc65lp/...60pin.v:81`, `tsmc16fcll/...28pin.v:80`), wiring pad cells through `p0_*`/`p1_*` nets (e.g. `.IE(p0_z[00])`, `.C(p0_i[00])` at `tsmc65lp/...28pin.v:225`).

The boundary is **also not identical**: `tsmc16fcll/28pin` has **no `SE` port** (grep finds no `SE` anywhere in the file) and exposes **unconditional** `inout` supply ports `VDDIO/VDD/VSS/VDDACC` (`tsmc16fcll/...28pin.v:39-42`), not `` `ifdef POWER_PINS ``-guarded ones. The descriptor schema below therefore carries an explicit **`body_flavour` (cfg | direct)** knob, a **GPIO net-name template** (`pad_gpio_port{idx}` vs `p{idx}`), and **boundary knobs** (`has_se`, `boundary_supplies`) — without these the M3 "normalise-diff identical to every hand file" goal is unachievable for the three Architecture-B variants.

---

## 2. Status & scope

**Status:** Greenfield backend; *extends* the existing `SoCChipBackend` (`backends/chip.py`) and its two templates (`soc_chip.v.j2`, `soc_chip_pads.v.j2`). The functional boundary generation is **already done and correct** — this doc does not touch how `nanosoc_chip` is generated. It replaces only the *pad-ring layer* and adds the FPGA-IP wrapper layer.

**In scope:**
- A technology descriptor schema (pad cell name + port map, power-pad set, supply voltages, `GPIO_TIO`, FPGA-vs-ASIC flavour, UPF hints incl. a fixed `top_prefix`).
- A pin-assignment map schema (which functional pad maps to which pin, pad-ring side/order) **plus per-variant body/boundary structure** (`body_flavour` cfg/direct, GPIO net-name template, `has_se`, `boundary_supplies`) — these capture the two real file architectures and the non-uniform boundary documented in §4.2.
- A `SoCPadRingBackend` that renders `nanosoc_chip_pads_<tech>_<N>pin.v` from descriptor + pin-map + the model's GPIO/SWD/UART/clk/reset boundary.
- A **UPF skeleton** emitter (supply sets, power domains, PST) parametrised by the descriptor.
- An **FPGA wrapper** emitter that regenerates `nanosoc_chip_vivado_wrapper.v` from the model (replacing the hand-written one) and aligns it with `package_nanosoc_ip.tcl`.
- An optional Innovus-style **IO placement file** (`*.io`) emitter from the pin-map.

**Out of scope (explicitly):**
- The internal AHB/APB interconnect, `nanosoc_chip_cfg` (external IP, not in this repo), and `nanosoc_chip` body generation — unchanged.
- Promoting AHB/APB interconnect ports to the chip boundary (that is doc 08's territory if it exists; here the boundary stays clk/reset/test/SWD/UART/GPIO — plus the per-variant `SE`/supply ports the descriptor models, §4.2 — matching reality).
- The board-level Vivado block design / `cmsdk_socket` mux (see `06`/FPGA-BD doc) — this doc stops at the packaged IP boundary.
- Real timing/floorplan/DRC; the `*.io` emitter is a *template* (offsets are placeholders), not a placer.

---

## 3. Motivation

### The concrete problem

Adding a new tech node or pin count today means **hand-authoring an entire flat Verilog file** under `asic/ASIC/nanosoc_chip_pads/<tech>/nanosoc_chip_pads_<N>pin.v`. Verified by inspection, each file is ~500 lines and the human must:

1. Swap every pad-cell module name (e.g. `PRDW0408SCDG` → `PRDW08SDGZ_V_G` → `PBIDIRN_18_18_FS_DR_H`), each repeated 20–40×.
2. Adjust `P0`/`P1` port widths (`[3:0]` 28pin, `[7:0]` 44/38pin, `[15:0]` 60pin — verified at `tsmc65lp/..._44pin.v:45-46`, `..._60pin.v:49-50`, `..._28pin.v:48-49`).
3. Add/delete the per-bit `uPAD_P0_NN`/`uPAD_P1_NN` instances (verified counts: 28pin=8, 38/44pin=16, 60pin=32 GPIO pads).
4. Fix the GPIO tie-off `assign` ranges for unbonded bits (`tsmc65lp/..._44pin.v:485-501` ties bits 8–15).
5. Re-do the power-pad count/types (15–17 power pads per file, tech-specific cell names).
6. Match the **per-cell port map**, which differs by tech: 65nm `PRDW0408SCDG` has `.IE/.C/.PE/.DS/.I/.OEN/.PAD` (`..._44pin.v:323-331`); 28nm `PRDW08SDGZ_V_G` has `.C/.I/.OEN/.REN/.PAD` (`..._38pin.v` GPIO instance); 16nm `PBIDIRN_18_18_FS_DR_H` has `.IE/.Y/.PE/.A/.PAD` (`..._28pin.v` GPIO instance). **These are three different port vocabularies** — getting one wrong floats an input or mis-drives an output.

This is error-prone and the files silently drift. The repo already shows the failure class: the generator's own `soc_chip_pads.v.j2` (generic `PAD_INOUT8MA_NOE` cells) is **dead** — no ASIC flow reads `build_soc/rtl/nanosoc_chip_pads.v`; flows read the hand-written `asic/ASIC/nanosoc_chip_pads/<tech>/*.v` (verified: `TSMC65nm/44pin/Cadence/scripts/design_import_noDFT.tcl:33` reads `nanosoc_chip_pads_44pin.v` from the netlist dir, and `Synopsys/scripts/synthesis.tcl` elaborates `nanosoc_chip_pads`). On the FPGA side `nanosoc_chip_vivado_wrapper.v` is **also hand-maintained** and its boundary (clk/nrst/gpio0/gpio1/swd/uart) duplicates what the model already knows.

### Why now / what good looks like

The model already carries the functional boundary: GPIO interfaces are extracted in `SoCChipBackend._build_context` (`chip.py:94-101`, reading `type == 'gpio'` ifaces with `WIDTH`). SWD/UART/clk/reset are uniform across every variant; `SE`/test and the supply-port boundary are **not** (see §4.2), so the descriptor must model those too. The thing standing between "model" and "any tech, any pin count" is the cell-name + count + placement layer **plus the body-structure flavour** (Architecture A vs B). Good = a one-command flow.

There is **no `sys_desc/Makefile` and no `soc_model` make target in this repo** (verified: `sys_desc/` contains only `regions/`, `register_maps/`, `subsystems/`; the only Makefiles are unrelated, under `firmware/` and a Vivado driver dir). The generator is invoked either directly via `python3 -m soc_model` or via `make all` from the **parent superproject** `nanosoc_m0_soc/` (outside this repo; see `nanosoc_gen/README.md:17-26`). The new selector is therefore a pair of CLI/env flags on `__main__.py`, plus a one-line addition to the *parent* project's `make all` recipe:

```
# direct (the canonical entry point in this repo):
python3 -m soc_model sys_desc/nanosoc_m0_soc.yaml \
    --lib-dir nanosoc_arch_tech/sys_desc \
    --build-dir build_soc \
    --system-yaml sys_desc/nanosoc_m0_system.yaml \
    --pad-tech tsmc65lp --pin-count 44
# emits build_soc/rtl/nanosoc_chip_pads_tsmc65lp_44pin.v + .upf + .io
```

and to add a tech, you write **one descriptor YAML + one pin-map YAML**, not a 500-line Verilog file.

---

## 4. Current state (grounded)

### 4.1 The generic-cell template (dead) and the chip backend

`SoCChipBackend.generate()` renders two files from one context (`chip.py:57-72`):

```python
# chip.py:60-72
chip_template = env.get_template('soc_chip.v.j2')
...
pads_template = env.get_template('soc_chip_pads.v.j2')
pads_ctx = dict(ctx)
pads_ctx['module_name']      = f'{ctx["module_name"]}_pads'
pads_ctx['chip_module_name'] = ctx['module_name']
```

Context is GPIO-only beyond names (`chip.py:_build_context`, `:88-101`):

```python
# chip.py:94-101 (functional-boundary GPIO extraction)
for iface in self.system.interfaces:
    if iface.type == 'gpio':
        width = iface.params.get('WIDTH', 16)
        width = resolve_param_ref(width, self.flat_params)
        gpio_ports.append({'name': iface.name, 'width': int(width)})
```

(Note: `protocol_utils` has a `gpio` branch at `protocol_utils.py:127`, but the chip backend does **not** route GPIO through it — the functional-boundary extraction the pad ring reuses lives in `chip.py:_build_context`.)

It is invoked **only when `--system-yaml` is given** (`__main__.py:294-303`), via `SoCChipBackend(system_module, top_module).generate(rtl_dir, flist_dir)`.

The generic pads template uses one cell type for everything — `PAD_INOUT8MA_NOE` with `.PAD/.O/.I/.NOE` (`soc_chip_pads.v.j2:215-267`) — and emits *all* GPIO bits (`for i in range(port.width)`, `soc_chip_pads.v.j2:261`), with no concept of bonded subset, tie-offs, real cells, or power pads beyond the `` `ifdef POWER_PINS `` generic `PAD_VDDIO`/`PAD_VSS`/`PAD_VDDSOC` (`soc_chip_pads.v.j2:186-211`). `GPIO_TIO = 4` is a hard `localparam` (`soc_chip_pads.v.j2:34`). **No flist or flow references its output.**

### 4.2 The hand-written tech files (what the flows actually use)

**The boundary and the body are NOT uniform** (verified file-by-file with grep). There are **two file architectures**, and the boundary differs (notably `SE` and the supply ports). Any descriptor/template that claims to reproduce all six must model these differences as data — they are not cosmetic.

**Body architecture (verified):**

| Variant | Body flavour | Top instances | GPIO net names | Evidence |
|---|---|---|---|---|
| `tsmc65lp/44pin` | **A: cfg** | `nanosoc_chip_cfg` + `nanosoc_chip` (siblings) | `pad_gpio_portN_*` | cfg `:118`, chip `:174` |
| `tsmc28hpcp/38pin` | **A: cfg** | `nanosoc_chip_cfg` + `nanosoc_chip` | `pad_gpio_portN_*` | cfg `:118` |
| `tsmc28hpcp/no_pads` | **A: cfg** | `nanosoc_chip_cfg` + `nanosoc_chip` | `pad_gpio_portN_*` | cfg present |
| `tsmc65lp/28pin` | **B: direct** | `nanosoc_chip` only (no cfg) | `pN_*` (`p0_i`,`p0_z`,…) | chip `:81`, `.IE(p0_z[00])` `:225` |
| `tsmc65lp/60pin` | **B: direct** | `nanosoc_chip` only | `pN_*` | chip `:81`, pad `:233` |
| `tsmc16fcll/28pin` | **B: direct** | `nanosoc_chip` only | `pN_*` | chip `:80`, `.IE(p0_z[00])` `:210` |

`grep -l nanosoc_chip_cfg` returns **only** the three Architecture-A files; the other three instantiate `nanosoc_chip` directly. The schema below carries a `body_flavour` knob and a GPIO net-name template to cover both.

**Boundary + cell layer (verified):**

| Variant | `P0/P1` width | GPIO pads | Power pads | `SE`? | Boundary supplies | I/O cell | GPIO cell port map |
|---|---|---|---|---|---|---|---|
| `tsmc65lp/28pin` | `[3:0]` | 8 | ~15 | yes | none in boundary | `PRDW0408SCDG` | `.IE/.C/.PE/.DS/.I/.OEN/.PAD` |
| `tsmc65lp/44pin` | `[7:0]` | 16 | **16** (`uPAD_VDDIO_1` commented out → 17th inactive) | yes | none in boundary | `PRDW0408SCDG` | same |
| `tsmc65lp/60pin` | `[15:0]` | 32 | ~17 | yes | none in boundary | `PRDW0408SCDG` | same |
| `tsmc28hpcp/38pin` | `[7:0]` | 16 | 16 | yes | none in boundary | `PRDW08SDGZ_V_G` | `.C/.I/.OEN/.REN/.PAD` |
| `tsmc28hpcp/no_pads` | `[15:0]` | 32 | **5** (generic: `PAD_VDDIO`,`PAD_VSSIO`,`PAD_VDDSOC`×2,`PAD_VSS`) | yes | none in boundary | `PAD_INOUT8MA_NOE` | `.PAD/.O/.I/.NOE` |
| `tsmc16fcll/28pin` | `[3:0]` | 8 | ~15 | **no** | **unconditional `inout VDDIO/VDD/VSS/VDDACC`** (`:39-42`) | `PBIDIRN_18_18_FS_DR_H` | `.IE/.Y/.PE/.A/.PAD` |

The active 65nm/44pin power-pad count is **16** (`^PVDD`/`^PVSS` grep = 16; the 17th, `uPAD_VDDIO_1`, is commented out at `:218`). `no_pads` has **5** generic power pads, not 4. The 16nm variant alone drops `SE` from the boundary and lists its four supplies as plain unconditional `inout` ports (it does still use a `` `ifdef POWER_PINS `` *inside* the `nanosoc_chip` instantiation at `:81`, but not to gate the boundary supply ports). So `has_se` and `boundary_supplies` are per-variant descriptor knobs, not constants.

> **Digest correction:** the research digest claimed tsmc28hpcp and tsmc16fcll "use the SAME pad cell names". They do **not**. Verified: 28nm uses `PRDW08SDGZ_V_G` / `PVDD2DGZ_H_G` / `PVDD2POC_H_G`; 16nm uses `PBIDIRN_18_18_FS_DR_H` / `PDVDD_18_18_NT_DR_H` / `PVDD_08_08_NT_DR_H` / `PVSS_08_08_NT_DR_H`. They are distinct cell libraries with distinct port vocabularies. The descriptor design below treats each tech's cell + port-map as fully independent data — do not assume aliasing.

Tie-off of unbonded GPIO bits is hand-written per file, e.g. `tsmc65lp/..._44pin.v:485-501` (Architecture A, `pad_gpio_portN_*` nets):

```verilog
assign pad_gpio_port0_i[8] = pad_gpio_port0_o[8] & pad_gpio_port0_e[8];
...
assign pad_gpio_port1_i[15] = pad_gpio_port1_o[15] & pad_gpio_port1_e[15];
```

In Architecture-B files the identical loopback uses the `pN_*` names (`assign p0_i[8] = p0_o[8] & p0_e[8];`), so the tie-off emitter must take the net-name template from the descriptor too.

The two enable-form differences are real and load-bearing: 65nm GPIO sets `.PE(z & o)` (pull-enable from output when tristated) with `.IE(z)`; 16nm sets `.PE(z & o)` too but pairs it with `.IE(z)`/`.Y`/`.A`; 28nm has no `IE`/`PE` and instead uses `.REN(~(z & o))` (active-low receive enable). Power-cell instantiation also differs: 65nm power cells take **no port connections** (`PVDD2CDG uPAD_VDDIO_0( );`, `..._44pin.v:216`), while 28nm connects the supply net (`PVDD2DGZ_H_G uPAD_VDDIO_0( .VDDPST(VDDIO) );`).

### 4.3 The physical pin-assignment artifact already exists (Innovus `.io`)

`asic/ASIC/TSMC65nm/44pin/Cadence/scripts/nanosoc_io_plan.io` is a real, machine-readable pad-ring layout, keyed by **instance name** with side + offset:

```
(iopad
    (top
        (inst name="uPAD_TEST_I"   offset=149.29)
        (inst name="uPAD_SWDCK_I"  offset=257.86 place_status=placed )
        ...)
    (left
        (inst name="uPAD_P0_04"    offset=146.25 place_status=placed )
        ...))
```

This proves a pin-assignment map (functional pad → side → order) is already part of the flow — it is currently a downstream Innovus export, not an input. The proposed `pin_map/<tech>_<N>pin.yaml` becomes the **single source** the generator uses both to (a) decide which GPIO bits get pads vs tie-offs and (b) optionally emit a `*.io` template.

### 4.4 UPF (tech-dependent, fragile)

`TSMC65nm/44pin/Synopsys/upf/nanosoc_chip_pads.upf` (verified, **57 lines**): two supply sets `VDDACC_VSS`/`VDD_VSS`, two power domains `ACCEL`/`TOP`, supply ports `VDDACC/VDD/VSS`, **hard-coded memory supply-pin hierarchy paths** (the `connect_supply_net` block spans `:31-35`):

```tcl
connect_supply_net VDD -ports u_nanosoc_chip/u_system/u_ss_cpu/u_region_imem_0/u_imem_0/u_sram/u_rf_sp_hdf/VDD   ; # :34
connect_supply_net VDD -ports u_nanosoc_chip/u_system/u_ss_cpu/u_region_bootrom_0/u_bootrom_cpu_0/u_bootrom/u_sl_rom/VDDE ; # :35
```

(the same block also lists `u_region_expram_h/_l` and `u_region_dmem_0` SRAM paths at `:31-33`) and PST states at 1.08 V (`add_port_state VDD -state {state1 1.08}`, `:44`). These instance paths break on any hierarchy rename (the multicore/DMA-250 renames already invalidated similar paths). The 16nm UPF (`TSMC16nm/28pin/Synopsys_FC/inputs/nanosoc.upf`) is **empty** — 0 lines / 0 bytes, not even a stub line.

### 4.5 FPGA wrapper (hand-written, model-derivable)

`fpga/fpga/vivado_ip/nanosoc_chip_vivado_wrapper.v` exposes `clk, nrst, gpio0_tri_{i,o,t}[15:0], gpio1_tri_{i,o,t}[15:0], swd_clk, swd_dio_{i,o,t}, uart_rxd, uart_txd` (`:26-49`) and ties off all test/scan/BIST, mapping `p*_z → *_tri_t` (`:63-72`). `package_nanosoc_ip.tcl` curates IP-XACT bus interfaces over those exact port names: clock `clk` (`:102-108`), reset `nrst` ACTIVE_LOW (`:121-131`), `gpio0/gpio1` via `TRI_I/TRI_O/TRI_T` (`:136-167`), `uart` via `RxD/TxD` (`:179-189`); SWD left as raw pins (`:170-174`). The wrapper port list is a direct function of the model's GPIO ports + the fixed SWD/UART/clk/reset contract — it can be generated, and **the IP-XACT port names must stay in lockstep** (an explicit acceptance check below).

---

## 5. Proposed design

### 5.1 Two data inputs, one backend

```
                       model (system_module)
                       └── gpio ifaces (name,width)  ── functional boundary (already extracted)
                                   │
   pad_tech/<tech>.yaml ───────────┼──────────── pin_map/<tech>_<N>pin.yaml
   (cell names, port maps,         │             (functional pad -> side/order,
    power pads, voltages,          │              bonded GPIO bit subset)
    GPIO_TIO, flavour)             ▼
                          SoCPadRingBackend
              ┌───────────────────┼───────────────────────────┐
              ▼                    ▼                           ▼
   nanosoc_chip_pads_<tech>_  nanosoc_chip_pads_<tech>_   nanosoc_chip_pads_<tech>_
   <N>pin.v  (real cells)     <N>pin.upf (skeleton)       <N>pin.io  (placement template)
```

For **FPGA** the same backend, given a descriptor with `flavour: fpga`, emits the synthesizable wrapper (no pad cells, tristate `_tri_t` convention) instead of a pad ring + UPF.

### 5.2 Technology descriptor schema (`nanosoc_gen/lib/pad_tech/<tech>.yaml`)

A descriptor names cells and gives a **logical→physical port map** per cell role. The logical port names are the four uniform tristate nets the chip boundary already uses: `i` (pad→core input), `o` (core→pad output data), `oen_active_high` (`_e`), `oen_active_low` (`_z`), `pad`.

```yaml
# nanosoc_gen/lib/pad_tech/tsmc65lp.yaml
pad_tech:
  name: tsmc65lp
  flavour: asic                 # asic | fpga | generic
  gpio_tio: 4
  # --- Bidirectional GPIO / alt-IO cell -----------------------------------
  bidir_cell:
    module: PRDW0408SCDG
    # map logical nets -> this cell's physical port; expr uses the logical names
    port_map:
      PAD: "{pad}"
      C:   "{i}"                # pad receive -> core input
      I:   "{o}"               # core output data
      OEN: "{z}"               # active-low output enable
      IE:  "{z}"               # input/receive enable
      PE:  "{z} & {o}"         # pull-enable when tristated
      DS:  "1'b0"
  # --- Pure input cell (CLK/NRST/TEST/SWDCK and SE where present) ---------
  input_cell:
    module: PRDW0408SCDG
    port_map:
      PAD: "{pad}"
      C:   "{i}"
      IE:  "1'b1"
      I:   "1'b0"
      OEN: "1'b1"
      PE:  "1'b0"
      DS:  "1'b0"
  # --- Power/ground pads: name, how many, optional supply-net port --------
  power_pads:
    - { cell: PVDD2CDG, prefix: uPAD_VDDIO, count: 2 }
    - { cell: PVDD2POC, prefix: uPAD_VDDIO_POC, count: 1 }
    - { cell: PVSS2CDG, prefix: uPAD_VSSIO, count: 2 }
    - { cell: PVDD1CDG, prefix: uPAD_VDD,    count: 4 }
    - { cell: PVSS1CDG, prefix: uPAD_VSS,    count: 4 }
    - { cell: PVDD1CDG, prefix: uPAD_VDDACC, count: 3 }
  supply_connect: false          # 65nm power cells take no ports
  # --- UPF hints ----------------------------------------------------------
  upf:
    domains:
      - { name: TOP,   supply_set: VDD_VSS,    elements: [] }
      - { name: ACCEL, supply_set: VDDACC_VSS, elements: ["u_nanosoc_chip/u_system/u_ss_expansion/u_region_exp/u_ss_accelerator"] }
    supply_voltage: 1.08
    # mem supply-pin paths are model-derivable (see M5); list overrides here if needed
```

28nm differs only in data:

```yaml
# nanosoc_gen/lib/pad_tech/tsmc28hpcp.yaml (excerpt)
pad_tech:
  name: tsmc28hpcp
  flavour: asic
  gpio_tio: 4
  bidir_cell:
    module: PRDW08SDGZ_V_G
    port_map:
      PAD: "{pad}"
      C:   "{i}"
      I:   "{o}"
      OEN: "{z}"
      REN: "~({z} & {o})"
  power_pads:
    - { cell: PVDD2DGZ_H_G, prefix: uPAD_VDDIO, count: 2 }
    - { cell: PVDD2POC_H_G, prefix: uPAD_VDDIO_POC, count: 1 }
    ...
  supply_connect: true           # 28nm: .VDDPST(VDDIO) etc.
  supply_port_map: { uPAD_VDDIO: VDDPST, uPAD_VSSIO: VSSPST, uPAD_VDD: VDD, uPAD_VSS: VSS }
```

16nm provides its own `PBIDIRN_18_18_FS_DR_H` with `.IE/.Y/.PE/.A/.PAD`. FPGA provides `flavour: fpga` and no cell modules (the FPGA path is a separate template, §5.4).

**Why a `port_map` with `{i}/{o}/{z}` substitution rather than fixed roles?** Because the three real techs have three incompatible port vocabularies and even differ in *which* logical net feeds a given physical port (65nm `IE={z}`, 28nm has no IE but `REN=~(z&o)`). A free-form expression map (substituted per bit) captures all observed cases and any future cell without code changes. The expression grammar is deliberately tiny: logical-name substitution + verbatim Verilog passthrough.

#### 5.2.1 Body-structure and boundary knobs (the §4.2 differences as data)

The Architecture-A/B split and the boundary differences (`SE`, supply ports) are **per-variant**, not per-tech: `tsmc65lp` has both a `cfg` variant (44pin) and `direct` variants (28pin, 60pin). So these knobs live in the **pin-map** (per tech+pin), not the descriptor:

| Knob | Values (observed) | Reproduces |
|---|---|---|
| `body_flavour` | `cfg` \| `direct` | A (cfg+chip, `pad_gpio_portN_*`) vs B (chip only, `pN_*`) |
| `gpio_net_template` | `pad_gpio_port{idx}` \| `p{idx}` | Arch-A vs Arch-B net names; feeds both the pad-cell wiring and the tie-off `assign` |
| `has_se` | `true` \| `false` | drops the `SE` boundary port + its input pad (16nm: `false`) |
| `boundary_supplies` | `none` \| `unconditional` \| `ifdef_power_pins` | 16nm = `unconditional` (`inout VDDIO/VDD/VSS/VDDACC`); 65nm/28nm = `none` in boundary |

The ASIC template (§5.5) selects the `nanosoc_chip_cfg`+`nanosoc_chip` sibling block vs the bare `nanosoc_chip` block on `body_flavour`, and threads `gpio_net_template` into every net reference. This is what makes the M3 "normalise-diff-clean against **every** hand file" goal achievable; without it, M2/M3 can only match the three Architecture-A files.

### 5.3 Pin-assignment map (`nanosoc_gen/lib/pin_map/<tech>_<N>pin.yaml`)

```yaml
# nanosoc_gen/lib/pin_map/tsmc65lp_44pin.yaml
pin_map:
  tech: tsmc65lp
  pin_count: 44
  # --- per-variant body/boundary structure (§5.2.1) ---
  body_flavour: cfg                 # 44pin is Architecture A
  gpio_net_template: "pad_gpio_port{idx}"
  has_se: true
  boundary_supplies: none
  # GPIO bits that get a real pad (others are tied off). Order = pad order.
  bonded_gpio:
    P0: [0,1,2,3,4,5,6,7]        # bits 8..15 tied off
    P1: [0,1,2,3,4,5,6,7]
  # Optional: explicit pad-ring placement for the *.io emitter (M6).
  # If omitted, the .io file is not generated.
  ring:
    top:    [uPAD_TEST_I, uPAD_SWDCK_I, uPAD_VDD_3, uPAD_VSS_3, uPAD_VDDIO_3, uPAD_P1_00, uPAD_P1_01]
    left:   [uPAD_P0_04, uPAD_P0_05, uPAD_P0_03, uPAD_VDDACC_0, uPAD_VSS_0, uPAD_CLK_I, ...]
    bottom: [uPAD_P0_02, uPAD_VDDACC_1, uPAD_SE_I, ...]
    right:  [...]
```

The `bonded_gpio` lists drive both the pad-cell instantiation loop and the tie-off `assign` block. `P0=[0..7]` with a 16-bit core port reproduces `tsmc65lp/..._44pin.v` exactly (8 pads + bits 8–15 tied off). `P0=[0..3]` gives the 28pin file (which is also `body_flavour: direct` + `gpio_net_template: "p{idx}"`); `P0=[0..15]` gives 60pin (no tie-offs, also `direct`). The `tsmc16fcll_28pin.yaml` map sets `has_se: false` and `boundary_supplies: unconditional`. The `ring` section is a faithful re-encoding of the existing `nanosoc_io_plan.io` so the generator can round-trip it; the `uPAD_SE_I` entry is present only when `has_se: true`.

### 5.4 FPGA flavour

For `flavour: fpga`, `SoCPadRingBackend` renders a **new** `fpga_vivado_wrapper.v.j2` that reproduces `nanosoc_chip_vivado_wrapper.v` from the model: GPIO ports become `<name>_tri_{i,o,t}`, with `assign <name>_tri_t = <name>_z` (matching the existing hand wrapper, `nanosoc_chip_vivado_wrapper.v:63-72`), test/scan/BIST tied off, `alt_mode=1`/`swd_mode=1`. No pad cells, no UPF. It must keep the exact port names `package_nanosoc_ip.tcl` curates (`gpio0_tri_i` etc.); the template's GPIO loop emits `gpio{{loop.index0}}_tri_*` to match.

### 5.5 ASIC pad-ring rendering (before/after)

**Before** (hand, per file): every `uPAD_P0_NN` typed out with the right cell + port map + tie-off ranges.

**After** (one Jinja loop, data-driven):

```jinja
{# nanosoc_chip_pads_asic.v.j2  (excerpt). `net` = the per-variant GPIO
   net-name stem from pin_map.gpio_net_template, e.g. "pad_gpio_port" (Arch A)
   or "p" (Arch B). The backend resolves it per port index. #}
{% for port in gpio_ports %}
{% set pidx = loop.index0 %}
{% set stem = net_stem(pidx) %}   {# "pad_gpio_port0" or "p0" #}
{% for bit in port.bonded %}
{{ bidir.module }} uPAD_{{ port.name }}_{{ '%02d' % bit }} (
{% for phys, expr in bidir.port_map.items() %}
   .{{ phys }} ({{ expr
        | replace('{pad}', port.name ~ '[' ~ ('%02d' % bit) ~ ']')
        | replace('{i}',   stem ~ '_i[' ~ ('%02d' % bit) ~ ']')
        | replace('{o}',   stem ~ '_o[' ~ ('%02d' % bit) ~ ']')
        | replace('{z}',   stem ~ '_z[' ~ ('%02d' % bit) ~ ']') }}){{ "," if not loop.last }}
{% endfor %}
   );
{% endfor %}
{# tie off unbonded bits, same net stem #}
{% for bit in port.unbonded %}
assign {{ stem }}_i[{{ bit }}] = {{ stem }}_o[{{ bit }}] & {{ stem }}_e[{{ bit }}];
{% endfor %}
{% endfor %}

{# --- body block: selected on pin_map.body_flavour --- #}
{% if body_flavour == 'cfg' %}
{% include 'pads_body_cfg.v.j2' %}     {# nanosoc_chip_cfg + nanosoc_chip siblings (lifted from soc_chip_pads.v.j2:90-...) #}
{% else %}
{% include 'pads_body_direct.v.j2' %}  {# bare nanosoc_chip, pN_* nets #}
{% endif %}
```

The net substitution is done in Python (cleaner than Jinja filters) — the snippet shows intent; §7 puts the expansion in the backend. **The body block is NOT one fixed section:** Architecture-A variants (44pin/38pin/no_pads) emit a `nanosoc_chip_cfg` + `nanosoc_chip` sibling pair (this *can* be lifted verbatim from the current generic `soc_chip_pads.v.j2:90-145`, which is itself Architecture-A shaped), whereas Architecture-B variants (65nm 28/60pin, 16nm 28pin) emit a **bare `nanosoc_chip`** with no cfg and `pN_*` nets. The template selects between two body sub-templates on `body_flavour`; the boundary block likewise drops `SE` and/or adds unconditional supply ports per the `has_se`/`boundary_supplies` knobs (§5.2.1). This split is exactly the work the original "reuse verbatim" assumption hid.

---

## 6. Implementation plan

Each milestone is independently shippable; the generic path keeps working until M7 retires it.

### M1 — Descriptor + pin-map schema, parser, model classes
**Changes:** add `lib/pad_tech/<tech>.yaml` (tsmc65lp, tsmc28hpcp, tsmc16fcll, fpga, generic) and `lib/pin_map/<tech>_<N>pin.yaml` for the six existing variants — each pin-map carrying the §5.2.1 `body_flavour`/`gpio_net_template`/`has_se`/`boundary_supplies` knobs. Add `PadTech`/`PadCell`/`PowerPad`/`PinMap` dataclasses to `model.py` and `parse_pad_tech()`/`parse_pin_map()` to `parser.py` (plain `yaml.safe_load`, mirroring `parse_register_map` at `parser.py:114`/`:174`).
**Why:** establishes the data layer with no behavioural change.
**Acceptance:** a pytest loads all six descriptors + pin-maps and asserts `PadTech('tsmc65lp').bidir_cell.module == 'PRDW0408SCDG'`, the 44pin pin-map bonds 8 bits/port with `body_flavour == 'cfg'`, the 60pin map has `body_flavour == 'direct'` + `gpio_net_template == 'p{idx}'`, and the 16nm map has `has_se == False`, `boundary_supplies == 'unconditional'`.

### M2 — `SoCPadRingBackend` for ASIC, behind a flag, diff-equivalent to ONE Architecture-A file
**Changes:** new `backends/pad_ring.py` + `templates/nanosoc_chip_pads_asic.v.j2` with the `cfg` body sub-template only. CLI: `--pad-tech tsmc65lp --pin-count 44` (or env `PAD_TECH`/`PIN_COUNT`) on `__main__.py`. When given, after the chip backend (`__main__.py:296`), emit `nanosoc_chip_pads_<tech>_<N>pin.v`. **Scope: the Architecture-A reference only (`tsmc65lp/44pin`)** — direct/`pN_*` bodies land in M3.
**Why:** the core value — pad rings from data — proven on the file whose body matches the existing generic template.
**Acceptance:** `python3 -m soc_model ... --pad-tech tsmc65lp --pin-count 44` produces a file **logically identical** to the hand `tsmc65lp/nanosoc_chip_pads_44pin.v`: same module ports (incl. `SE`), same cell instances, same `pad_gpio_portN_*` net references, same port maps, same `:485-501`-style tie-offs. Prove with a normalising diff (strip whitespace/comments, sort `assign` blocks) and by elaborating both in slang (`--lint`). Because M2 reuses the hand file's exact `pad_gpio_portN_*` net names, the diff is expected to be net-name-clean; the slang bar is **zero new warnings vs the hand file** elaborated standalone.

### M3 — Architecture B + all remaining variants reproduced
**Changes:** add the `direct` body sub-template (`pads_body_direct.v.j2`) and the boundary knobs so `body_flavour`/`gpio_net_template`/`has_se`/`boundary_supplies` are honoured; add descriptors/pin-maps for 28pin/60pin/38pin/16nm-28pin/no_pads. Handle the 28nm `supply_connect: true` power-pad port, the 16nm no-`SE` + unconditional-supply boundary, and the `no_pads` generic flavour (5 generic power pads).
**Why:** proves the schema generalises to **both** file architectures, every port-vocabulary/count, and the non-uniform boundary — the variants M2 deliberately excluded.
**Acceptance:** all six variants generate via `python3 -m soc_model ... --pad-tech .. --pin-count ..` and normalise-diff-clean against their hand files. For the three Architecture-B files the diff must confirm bare-`nanosoc_chip` (no `nanosoc_chip_cfg`) and `pN_*` net names; for 16nm it must confirm no `SE` port and the four unconditional `inout` supplies. CI elaborates each in slang.

### M4 — FPGA wrapper from the model
**Changes:** `templates/fpga_vivado_wrapper.v.j2`; `flavour: fpga` path in the backend emits `nanosoc_chip_vivado_wrapper.v`.
**Why:** removes the second hand-maintained boundary and ties it to the model + IP-XACT names.
**Acceptance:** generated wrapper is port-identical to `fpga/fpga/vivado_ip/nanosoc_chip_vivado_wrapper.v`; a new lint check (M8) asserts every `physical_name` in `package_nanosoc_ip.tcl` exists as a port in the generated wrapper.

### M5 — UPF skeleton emitter
**Changes:** `templates/nanosoc_chip_pads.upf.j2`; emit supply sets/domains/PST from `pad_tech.upf`. Derive the *variable* tail of each memory supply-pin path by walking `module.srams` (`model.py:382`) + `instance.resolved_module`/`instance_name` (`model.py:359`/`:351`); the **fixed top prefix** (`u_nanosoc_chip/u_system`) comes from the chip template, supplied to the backend as a constant (it is **not** model-derivable — see Risk in §9).
**Why:** the UPF is the most fragile hand artifact (instance paths) — deriving the path *tail* from the model fixes the rename-breakage class for everything below `u_system`.
**Acceptance:** generated UPF for 65nm/44pin matches the hand UPF's (57-line) supply sets/domains/PST (`add_port_state VDD ... 1.08`) and reproduces the same `connect_supply_net` block, including `.../u_region_imem_0/u_imem_0/u_sram/u_rf_sp_hdf/VDD` and `.../u_region_bootrom_0/u_bootrom_cpu_0/u_bootrom/u_sl_rom/VDDE` (and the `expram_h/_l`, `dmem_0` SRAM paths), where everything **below `u_system` is model-derived** and only the `u_nanosoc_chip/u_system` prefix is a declared constant. Load-checks clean in `synthesis.tcl` (`load_upf`).

### M6 — IO placement template emitter
**Changes:** `templates/nanosoc_io_plan.io.j2`; emit the Innovus `(iopad (top..)(left..)..)` structure from `pin_map.ring`.
**Why:** makes the pad ring's *physical order* data too, round-tripping the existing `.io`.
**Acceptance:** generated `.io` parses in Innovus (`read_io_file`) and matches the side/order of the hand `nanosoc_io_plan.io` (offsets are placeholders; instance order per side must match).

### M7 — Retire the dead generic template; wire flows to generated files
**Changes:** repoint the ASIC flow scripts' pad-RTL read (e.g. `TSMC65nm/44pin/Cadence/scripts/design_import_noDFT.tcl:33`, `Synopsys/scripts/synthesis.tcl`) and the FPGA flist (`fpga/.../package_nanosoc_ip.tcl` source list) at `build_soc/rtl/nanosoc_chip_pads_<tech>_<N>pin.v`. Delete `soc_chip_pads.v.j2` once `generic` flavour covers `no_pads`. Keep the hand files in git until one full tapeout-grade run confirms equivalence.
**Why:** single source of truth.
**Acceptance:** a full `synthesis.tcl` run on 65nm/44pin against the generated pad file produces an equivalent netlist (formality `fm_shell.tcl` PASS vs the hand-file netlist).

### M8 — CI gate
**Changes:** a `tests/test_pad_ring.py` (pytest) + a CI job that, per (tech, pin) in a matrix, generates and elaborates the pad file and runs the IP-XACT/port consistency check (M4).
**Why:** lock equivalence so the data and flows can't drift.
**Acceptance:** matrix green; intentionally corrupting a descriptor cell name fails the elaborate step.

---

## 7. File & module changes

**New files**

| Path | Purpose |
|---|---|
| `nanosoc_gen/lib/pad_tech/tsmc65lp.yaml` (+`tsmc28hpcp`, `tsmc16fcll`, `fpga`, `generic`) | tech descriptors |
| `nanosoc_gen/lib/pin_map/tsmc65lp_44pin.yaml` (+ 28/60, 38, 16nm-28, no_pads) | pin-assignment maps |
| `nanosoc_gen/soc_model/backends/pad_ring.py` | `SoCPadRingBackend` |
| `nanosoc_gen/soc_model/backends/templates/nanosoc_chip_pads_asic.v.j2` | ASIC pad ring |
| `nanosoc_gen/soc_model/backends/templates/fpga_vivado_wrapper.v.j2` | FPGA wrapper |
| `nanosoc_gen/soc_model/backends/templates/nanosoc_chip_pads.upf.j2` | UPF skeleton |
| `nanosoc_gen/soc_model/backends/templates/nanosoc_io_plan.io.j2` | IO placement template |
| `nanosoc_gen/tests/test_pad_ring.py` | unit/equivalence tests |

**Modified files**

| Path | Change |
|---|---|
| `nanosoc_gen/soc_model/model.py` | add `PadTech`, `PadCell`, `PowerPad`, `PinMap`, `PadDomain` dataclasses (style of existing `SramEntry` at `:316` / `BuildInfo` at `:308`); `PinMap` carries `body_flavour`, `gpio_net_template`, `has_se`, `boundary_supplies`, `bonded_gpio`, `ring` |
| `nanosoc_gen/soc_model/parser.py` | `parse_pad_tech(name)`, `parse_pin_map(name)`; scan `lib/pad_tech` + `lib/pin_map` |
| `nanosoc_gen/soc_model/__main__.py` | argparse `--pad-tech`/`--pin-count` (default from env `PAD_TECH`/`PIN_COUNT`); after the chip backend (`SoCChipBackend(...)` at `:296`) construct `SoCPadRingBackend(system_module, top_module, pad_tech, pin_map).generate(rtl_dir, flist_dir)` |
| **parent** `nanosoc_m0_soc/Makefile` (outside this repo) | add `--pad-tech`/`--pin-count` to the `make all` `python3 -m soc_model` recipe — **there is no `sys_desc/Makefile` or `soc_model` target in this repo**; the parent project's `make all` (see `nanosoc_gen/README.md:17-26`) is the make-level entry point |
| ASIC flow scripts (M7) | repoint pad-RTL read at generated file |

**Backend interface (mirrors `SoCChipBackend`):**

```python
# backends/pad_ring.py
class SoCPadRingBackend:
    def __init__(self, system_module, core_module, pad_tech: PadTech, pin_map: PinMap):
        self.system, self.core = system_module, core_module
        self.tech, self.pin_map = pad_tech, pin_map
        self.flat_params = flatten_params({n: p.default for n, p in system_module.params.items()})

    def generate(self, rtl_dir: Path, flist_dir: Path = None) -> List[Path]:
        if self.tech.flavour == 'fpga':
            return [self._render_fpga(rtl_dir)]
        outs = [self._render_asic_pads(rtl_dir)]
        if self.tech.upf:        outs.append(self._render_upf(rtl_dir.parent / 'upf'))
        if self.pin_map.ring:    outs.append(self._render_io(rtl_dir.parent / 'pnr'))
        return outs

    def _gpio_ports(self) -> List[dict]:
        """Same extraction as chip.py:_build_context (:94-101), plus bonded/unbonded
        bit lists from pin_map."""
        ports = []
        for iface in self.system.interfaces:
            if iface.type != 'gpio':
                continue
            w = int(resolve_param_ref(iface.params.get('WIDTH', 16), self.flat_params))
            bonded = self.pin_map.bonded_gpio.get(iface.name, list(range(w)))
            ports.append({'name': iface.name, 'width': w,
                          'bonded': bonded,
                          'unbonded': [b for b in range(w) if b not in bonded]})
        return ports

    def _net_stem(self, port_idx: int) -> str:
        """Per-variant GPIO net stem from pin_map.gpio_net_template, e.g.
        'pad_gpio_port0' (Architecture A) or 'p0' (Architecture B)."""
        return self.pin_map.gpio_net_template.format(idx=port_idx)

    def _expand_cell(self, cell: PadCell, nets: dict) -> List[Tuple[str, str]]:
        """Substitute {pad}/{i}/{o}/{z} in cell.port_map -> [(phys_port, verilog_expr)]."""
        out = []
        for phys, expr in cell.port_map.items():
            for k, v in nets.items():
                expr = expr.replace('{' + k + '}', v)
            out.append((phys, expr))
        return out
```

The `body_flavour`/`has_se`/`boundary_supplies` knobs (read off `self.pin_map`) select the body sub-template and gate the `SE` / supply boundary ports, per §5.2.1.

All writes go through `utils.write_if_changed` (as every backend does). Output filename uses the `<tech>_<N>pin` suffix so multiple variants can coexist in `build_soc/rtl/`.

**UPF mem-path derivation (M5)** — walk the model rather than hard-code:

```python
def _mem_supply_paths(self) -> List[str]:
    paths = []
    def walk(mod, prefix):
        for s in getattr(mod, 'srams', []):          # model.py:382
            paths.append(f"{prefix}/{s.name}/u_sram/u_rf_sp_hdf/VDD")  # cell pin per tech
        for inst in mod.instances:
            if inst.resolved_module:                  # model.py:359
                walk(inst.resolved_module, f"{prefix}/{inst.instance_name}")  # :351
    # NOTE: the top prefix is a FIXED chip-template constant, not model-derived
    # (see §9 risk); only the tail below u_system comes from the walk.
    walk(self.system, self.tech.upf.top_prefix)       # default "u_nanosoc_chip/u_system"
    return paths
```

(The exact leaf pin name — `VDD` vs `VDDE` for ROM — comes from `pad_tech.upf` per memory kind; ROM `u_sl_rom/VDDE` is observed in the hand UPF, so the descriptor carries a `{sram: VDD, rom: VDDE}` map. The `top_prefix` is an explicit descriptor constant precisely because `u_nanosoc_chip`/`u_system` are template labels, not model nodes — so M5 derives the path *tail*, not the whole path.)

---

## 8. Testing & validation

- **Schema (M1):** pytest loads every descriptor/pin-map and asserts cell names, counts, bonded bits. Cheap, runs in the generator's pytest suite (this adds the first `nanosoc_gen/tests/` for the *generator* itself — see `08`/CI doc which notes none exist today).
- **Equivalence (M2/M3):** the decisive test. For each variant, generate and **normalise-diff** against the hand file (strip comments/whitespace, sort `assign` blocks). A residual diff is a real defect. **The diff is net-name-exact, not "logically equivalent":** because the generator takes the GPIO net stem from `pin_map.gpio_net_template` (`pad_gpio_portN_*` for Architecture-A files, `pN_*` for Architecture-B), the generated nets match the hand file's nets character-for-character — so a normalise-diff is a legitimate bar even for the bare-`nanosoc_chip` variants (this is why §5.2.1 exists; without the template knob, Architecture-B diffs would be spuriously dirty and the bar would have to drop to functional equivalence). Back it with `python -m soc_model ... --lint` (slang) on the generated file: zero new errors/warnings vs the hand file elaborated standalone.
- **FPGA (M4):** port-list diff vs `nanosoc_chip_vivado_wrapper.v`; **IP-XACT consistency** — parse `package_nanosoc_ip.tcl` for every `set_property physical_name <p>` and assert `<p>` is a port of the generated wrapper. This is the guard against the existing "two IPs don't line up" drift.
- **UPF (M5):** `load_upf` in a dry `dc_shell`/`synthesis.tcl` run; assert derived mem paths resolve against the elaborated `nanosoc_chip_pads`.
- **Netlist equivalence (M7):** Formality (`fm_shell.tcl`) between the hand-file netlist and the generated-file netlist for 65nm/44pin — the tapeout-grade gate.
- **CI (M8):** matrix `{tsmc65lp:[28,44,60], tsmc28hpcp:[38,no_pads], tsmc16fcll:[28], fpga:[-]}` → generate + elaborate + consistency. Integrates with the cheap→expensive gate gradient described in the CI roadmap doc: schema/elaborate are seconds-to-minutes, Formality is the expensive opt-in.

---

## 9. Risks, tradeoffs, alternatives

- **Cell port-map expression grammar.** Real cells differ in *which* logical net drives which port (65nm `IE={z}`, 28nm `REN=~({z}&{o})`, no IE). The `{i}/{o}/{z}/{pad}` substitution + verbatim-Verilog escape hatch covers all observed cases, but a genuinely novel cell topology (e.g. separate output-enable polarity, schmitt/drive-strength straps as ports) may need a new logical net. **Mitigation:** the map is open (any extra physical port with a constant/expr is allowed), so most additions are pure data.
- **Tie-off semantics for unbonded bits.** The hand files use `i = o & e` (a loopback so lint sees a driver). This is a lint-satisfying convention, not silicon behaviour. The generator reproduces it exactly; if a tech wants a hard tie (`i = 1'b0`), that becomes a descriptor knob.
- **UPF path derivation depth (partial, not total).** The hand UPF lists memory instances by deep path; deriving them requires the model's SRAM hierarchy to match the *generated* RTL hierarchy. The top labels `u_nanosoc_chip` and `u_system` are **fixed in the chip template, not model nodes**, so they cannot be walked — they stay a declared `top_prefix` constant in `pad_tech.upf`. Everything below `u_system` (`u_ss_cpu/u_region_imem_0/...`, `u_ss_expansion/u_region_expram_*`) **is** model-derivable via `module.srams` + `instance.resolved_module`/`instance_name`. **Honest limitation:** M5's "derived not hard-coded" acceptance applies to the path *tail* only; the `u_nanosoc_chip/u_system` prefix remains a one-line descriptor constant. This still kills the rename-breakage class for the deep region/memory labels (which is what the multicore/DMA-250 renames actually churned).
- **`nanosoc_chip_cfg` coupling — Architecture-A only.** Only the three Architecture-A pad files (44pin/38pin/no_pads) instantiate `nanosoc_chip_cfg` (external IP, not in repo); the three Architecture-B files (65nm 28/60pin, 16nm) instantiate `nanosoc_chip` directly and do **not** reference it. For Architecture-A the generator references the cfg by name + `GPIO_TIO` only; if its port set changes per tech, that is out of this backend's control. Acceptable: it has been stable and tech-independent. The `body_flavour` knob means Architecture-B output carries no `nanosoc_chip_cfg` dependency at all.
- **Alternative considered — keep hand files, add only a linter** that checks counts/cells against a descriptor. Cheaper, but doesn't remove the authoring burden (the actual pain) and leaves drift. Rejected.
- **Alternative considered — generate full DEF/floorplan**, not just an `.io` template. Out of scope; needs a placer and PDK tech LEF. The `.io` template is the right altitude (data the model owns: side + order), leaving offsets to PnR.

---

## 10. Dependencies & sequencing

- **Builds on:** the existing `SoCChipBackend` and its **functional-boundary GPIO extraction in `chip.py:_build_context` (`:94-101`)** — that, not `protocol_utils`, is what the pad ring reuses (the chip backend does not route GPIO through `protocol_utils`, even though `protocol_utils.py:127` has a `gpio` branch used elsewhere). If a clean-backend-base refactor doc exists (e.g. `02-clean-architecture-adapters-backends.md`), `SoCPadRingBackend` should adopt its base class; otherwise it follows the current `SoCChipBackend` shape (no base class today).
- **Relates to the YAML-format doc** (descriptors are new lib YAMLs; reuse the `parse_*`/scan pattern; keep `yaml.safe_load`, no `!include`).
- **Relates to the FPGA-BD doc** (this doc generates the *packaged-IP boundary*; that doc consumes it to build block designs — M4's port/IP-XACT lock is the contract between them).
- **Unblocks:** any new tech bring-up (e.g. a fourth node) becomes two YAML files; and the FPGA wrapper stops being hand-maintained.
- **Effort:** **M** overall. M1–M2 ≈ S each; M3 ≈ S (data only); M4 ≈ S; M5 ≈ M (path derivation is the hard part); M6 ≈ S; M7 ≈ M (flow re-pointing + one Formality run for confidence); M8 ≈ S.

---

### Open questions (could not fully resolve from the code)

1. **Exact `nanosoc_chip_cfg` port set per tech (Architecture-A only).** The module is external IP (confirmed absent from this repo — no `nanosoc_chip_cfg.v` here); I confirmed only its instantiation in the three Architecture-A pad files (44pin/38pin/no_pads). Architecture-B files (65nm 28/60pin, 16nm) do not use it. If its port set ever varies by tech, the `cfg` body sub-template may need a per-tech `chip_cfg` section. Verify against the built copies under `nanosoc_m0_project/.../chip/verilog/nanosoc_chip_cfg.v` before M2.
2. **Memory leaf supply-pin names beyond SRAM/ROM.** Hand UPF shows `u_rf_sp_hdf/VDD` (SRAM) and `u_sl_rom/VDDE` (ROM); whether other macros (e.g. precompiled `rf_16k/rf_32k`) use yet other pin names was not verified — confirm from the macro LEF/lib before M5 and extend the descriptor's per-memory-kind pin map.
3. **Whether 28nm/16nm flows currently read their pad files** the same way 65nm does (verified only the 65nm/44pin scripts read `nanosoc_chip_pads_44pin.v`); the 28nm/16nm `Synopsys_FC` flows may use a different read path — confirm before M7 re-pointing.
4. **Power-pad ordering vs `.io`.** The hand `.v` lists power pads in source order but the `.io` places them interleaved on ring sides; M2 emits source-order instances and M6 emits placement — confirm no flow depends on source order matching ring order (they should be decoupled, but verify on one Innovus run).
