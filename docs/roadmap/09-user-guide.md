# 09 — Intuitive End-User Guide for the Whole Flow

> Design/outline for the single, newcomer-facing guide that teaches the mental model of `nanosoc_gen`, how to write a YAML config (using the simplified format from `05-simplified-yaml-format.md`), how to run the generator, how to read every output artifact, and how the FPGA/ASIC/sim paths diverge — anchored by a worked "hello SoC" walkthrough, a YAML field reference, a footgun-driven FAQ, and a glossary. Most of it is hand-written prose; a defined subset is auto-generated from the model so it cannot drift.

---

## 1. Title

**The NanoSoC Generator User Guide** — the one document a newcomer reads first; it ties every other roadmap doc to a concrete "do this, get that" flow.

---

## 2. Status & scope

**Status:** Greenfield document, with a small auto-generated appendix that extends the existing `SoCDocsBackend` (`nanosoc_gen/soc_model/backends/docs.py`).

**In scope:**
- A single, canonical, hand-written user guide at a fixed path (see §5 for where).
- The *structure/outline* of that guide, section by section, with enough content sketched that a writer can fill it in.
- A specification for the **auto-generated portions** (field reference table, artifact table, glossary stubs) so the prose never goes stale against the code.
- A "hello SoC" minimal example (a real, runnable, ~40-line YAML SoC) that doubles as the walkthrough and as a CI smoke test for the guide itself.
- Cross-links to every other roadmap doc.

**Out of scope:**
- Implementing the simplified YAML format itself — that is `05-simplified-yaml-format.md`. This guide *teaches* whatever format exists; it ships in two passes (today's verbose format first, the `uses:`/auto-base sugar once 05 lands).
- A web-based YAML builder/editor (that is `06-web-gui-yaml-builder.md`, and `python/nanosoc_multicore/demo_gui/`).
- New generator features beyond the doc-generation hooks needed to keep the field/artifact/glossary tables current.
- Replacing the LaTeX datasheet flow (`nanosoc_arch_tech/makefile:294` `make docs` → `pdflatex`) — that is a separate, vendor-facing artifact and is only cross-referenced, not merged.

---

## 3. Motivation

**The concrete problem.** There is no single document that takes a newcomer from "I have a clone" to "I have generated, simulated, and built an SoC." The docs that exist are fragmented and partly wrong:

- The project-root `README.md` (460 lines) is the closest thing, but it is a feature catalogue, not a learning path.
- `nanosoc_gen/README.md` documents a *different* invocation than this project uses: it tells you to run `make all` from `nanosoc_m0_soc/`, and the legacy `nanosoc_arch_tech/makefile:303` `soc_model:` target hard-codes `nanosoc_m0_soc.yaml`/`nanosoc_m0_system.yaml` — the wrong input files for this repo (which uses `sys_desc/nanosoc_multicore_soc.yaml`). A newcomer who reads the submodule README runs the wrong command and fails.
- The generator's output is **not self-sufficient**: `sys_desc/Makefile` runs `scripts/patch_ahb_to_apb.py` and wraps the MEMORY-only `.ld` files into complete linker scripts after generation. This post-processing is documented only as Makefile comments, so anyone running `python -m soc_model` directly gets RTL that will not elaborate and `.ld` files that will not link.
- The YAML format has **no schema doc** — the "spec" is prose in `nanosoc_gen/README.md:79-108` plus one 117 KB example file (`sys_desc/nanosoc_multicore_soc.yaml`). `docs/USER_GUIDE.md:268` answers "How do I customise the address map?" with "edit this YAML by hand," with no field reference.
- Footguns are severe and undocumented for newcomers: the 100 MHz-sim vs 25 MHz-FPGA firmware clock trap (silent 4× baud garbage), `module:` vs `rtl_module:`, the `lib/interfaces/*.yaml` files that *look* authoritative but are dead code (the real protocol tables are Python tuples in `backends/protocol_utils.py`), `role: ~` vs `role: None` (null vs the literal string), and Verilog literals leaking into `conn:` strings.

**Why now.** The roadmap docs (01–08) each redesign one slice of the toolchain. A newcomer cannot navigate eight design docs; they need one front door that explains the mental model and routes them to the right deep-dive. Writing it now also forces the simplified YAML format (`05-simplified-yaml-format.md`) and the artifact inventory to be pinned down in user terms, which surfaces inconsistencies early.

**What good looks like.**
- A first-time engineer, given only this guide and a working lab account, can `source set_env.sh`, write a small SoC YAML, run the generator, simulate it, and read the output — in under an hour, without reading any other doc.
- Every field a user can write in YAML has exactly one reference entry, and that entry is generated from the builder so it cannot drift.
- Every output file has a one-line "what it is / who consumes it" entry, generated from the backend list.
- The worst footguns are each a numbered FAQ entry with the exact error message and the fix (seven ship in M-FAQ — see §5.6).

---

## 4. Current state (grounded in the codebase)

### 4.1 What documentation exists today

| Doc | Path | Role today | Problem |
|---|---|---|---|
| Project README | `nanosoc-multicore-system/README.md` (460 L) | Feature catalogue + "Getting started" at `:276-317` | Not a learning path; assumes context |
| Generator README | `nanosoc_arch_tech/nanosoc_gen/README.md` | Describes `make all` from `nanosoc_m0_soc/`, format prose at `:79-108` | Wrong invocation for this repo; no field ref |
| User guide | `nanosoc-multicore-system/docs/USER_GUIDE.md` (17 KB) | FAQ-style, address-map/peripheral/DMA customisation at `:268-295` | Points at editing the 117 KB YAML by hand |
| Architecture | `docs/ARCHITECTURE.md` (30 KB) | Deep architecture | Not entry-level |
| Register map | `docs/REGISTER_MAP.md` (3 KB) | "auto-generated from RDL" per README:432 | Actually a static stub; **not** wired to `build_soc/rdl/` |
| Generated design doc | `build_soc/docs/<top>_design_doc.md` (40 KB) | Per-SoC Markdown from `docs.py` | **Not linked** from any hand-written doc |
| LaTeX datasheet | `doc/doc/tex/nanosoc_datasheet.tex` via `makefile:294` | Vendor datasheet | Separate toolchain, no cross-link |

The generated `design_doc.md` and the hand-written `docs/*.md` are **disjoint** — the generator emits good per-SoC reference material that nobody links to.

### 4.2 The real generation pipeline (what the guide must teach)

The canonical flow is **not** `nanosoc_gen/README.md`'s. It is:

```
source set_env.sh            # env + recursive submodule init + auto-regen if build_soc stale
make -C sys_desc             # the real generator invocation + mandatory post-processing
make firmware                # CMake firmware, clock baked in
make -C cocotb <env>         # simulate
```

`sys_desc/Makefile` is the single source of truth for *how* to invoke the generator. The real `soc_model:` target is at `sys_desc/Makefile:102-…`. The snippet below is a **condensed paraphrase** (the real recipe also has `@echo`/`@mkdir` setup lines at `:103-104`, an inline `for ext in cmake mk` symlink loop at `:120-125`, and a multi-line `printf` that writes the compat `nanosoc_memmap.h` at `:129-…`) — read the Makefile for the verbatim text; the load-bearing steps it shows are all present:

```make
soc_model: $(SYS_DESC_YAML)                 # :102
	@echo "[sys_desc] Generating SoC from $<"
	@mkdir -p $(BUILD_SOC_DIR)
	cd $(SOCLABS_NANOSOC_GEN_DIR) && $(PYTHON) -m soc_model \
		$(SYS_DESC_YAML) $(LIB_DIR_FLAGS) $(PARAM_OVERRIDES) \
		--build-dir $(BUILD_SOC_DIR)        # :105-109
	@find $(BUILD_SOC_DIR)/rtl -type f \( -name '*.sv' -o -name '*.v' \) \
	  | xargs $(PYTHON) $(SOCLABS_PROJECT_DIR)/scripts/patch_ahb_to_apb.py   # :113-114
	# then (real shell loops, not comments):
	#   :120-125  symlink nanosoc_multicore_soc_memmap.{cmake,mk} → nanosoc_memmap.*
	#   :129-…    printf a compat nanosoc_memmap.h wrapper (re-exports unprefixed macros)
	#   later      wrap MEMORY-only *.ld into full linker scripts
```

`LIB_DIRS` is **8 paths** (verified, `sys_desc/Makefile:61-69`): the project `sys_desc/` (`$(CURDIR)`); three under `nanosoc_arch_tech/sys_desc{,/regions,/subsystems}`; two eth-ss (`$(SOCLABS_ETH_SS_DIR)/sys_desc{,/regions}`); ethmac (`$(SOCLABS_ETHMAC_AHB_DIR)/sys_desc`); and ahb_qspi (`$(SOCLABS_AHB_QSPI_DIR)/sys_desc`). Cross-repo module resolution depends on all 8 resolving — i.e. on submodules being initialised.

The post-processing (`patch_ahb_to_apb.py`, `.ld` wrapping, `nanosoc_memmap.h` compat wrapper) is **mandatory**: the guide must tell users to run `make -C sys_desc`, never `python -m soc_model` directly, unless they understand they will get unusable RTL.

### 4.3 The CLI the guide documents (`__main__.py`)

Verified flags from `soc_model/__main__.py:38-61`:

| Flag | Purpose |
|---|---|
| `yaml_file` (positional) | Top-level SoC YAML |
| `--build-dir`/`-b` | Output root (default `<yaml_dir>/build_soc`, `:128`) |
| `--lib-dir`/`-l` (repeatable) | Component YAML search dirs |
| `--validate-only` | Validate then exit; exit 1 if errors (`:115-116`) |
| `--no-validate` | Skip validation |
| `--system-yaml` | Also emit system + chip wrappers (`:267, :294`) |
| `--config-override KEY=VALUE` (repeatable) | Int-coerced via `int(v,0)` else string (`:64-71`); flows only to `SoCConfigPkgBackend` |
| `--arm-ip-library-path` | Overrides `ARM_IP_LIBRARY_PATH` (consumed by AHB backend's BuildBusMatrix.pl) |
| `--lint`/`--lint-flist`/`--slang-bin`/`--slang-args` | slang lint of generated RTL |

One run emits **everything unconditionally** (it is a fixed batch — no flag selects a single backend). The print output is a useful tour: it prints module/param/interface/instance counts (`:91-101`), validation messages (`:110-113`), then a section header per backend (`:139-313`).

### 4.4 Output artifacts (what the guide must explain)

The build tree layout is documented inline in `__main__.py:118-128`:

```
build_soc/rtl/          — all generated RTL (.sv, .v)
build_soc/flist/        — file lists (.flist)
build_soc/firmware/     — linker MEMORY blocks, memmap.{h,mk,cmake}, adp
build_soc/rdl/          — SystemRDL register descriptions
build_soc/discovery/    — device discovery YAML tables
build_soc/interconnect/ — XML/ipxact/logs/address_maps (ARM BuildBusMatrix)
build_soc/docs/         — design doc (Markdown)
build_soc/reports/      — HTML connectivity, text maps, Python model, SRAM report
```

Each backend's outputs (verified against `__main__.py` invocation order):

| Backend (file) | Class | Key artifact(s) |
|---|---|---|
| `html.py` | `SoCVisualizer` | `<top>_connectivity.html` (~516 KB interactive viewer) |
| `text.py` | `SoCTextBackend` | `<top>_memory_map.txt`, `<top>_hierarchy.txt` |
| `python.py` | `SoCPythonBackend` | `<top>_model.py` (re-importable model, ~197 KB) |
| `sram.py` | `SoCSramBackend` | `<top>_sram_report.txt` |
| `ahb.py` | `SoCAhbBackend` | per-interconnect SV + flist + config_pkg + XML + BuildBusMatrix RTL |
| `subsystem.py` | `SoCSubsystemBackend` | `<subsystem>.sv` + flist per `gen:True` child |
| `rdl.py` | `SoCRdlBackend` | `<name>.rdl` + regblock RTL |
| `discovery.py` | `SoCDiscoveryBackend` | `<ic>_discovery.yaml` (fed back into rdl) |
| `build_info.py` | `SoCBuildInfoBackend` | `<top>_build_info.yaml` + `.h` (git hash, timestamp) |
| `soc_config_pkg.py` | `SoCConfigPkgBackend` | `<top>_soc_config_pkg.sv`, `.vh`, flist |
| `toplevel.py` | `SoCTopLevelBackend` | `<top>.sv` + `<top>_toplevel.flist` |
| `firmware.py` | `SoCFirmwareBackend` | `*_memory.ld`, `*_memmap.{h,mk,cmake}`, `*_adp.{vh,py}` |
| `system.py` | `SoCSystemBackend` | `<system>.sv` (only with `--system-yaml`) |
| `chip.py` | `SoCChipBackend` | `nanosoc_chip.v`, `nanosoc_chip_pads.v` (only with `--system-yaml`) |
| `docs.py` | `SoCDocsBackend` | `<top>_design_doc.md` |

### 4.5 The YAML format the guide documents

There is a **single module schema** for regions, subsystems, and the SoC top (`builder.py:_build_module`). Every key is `.get()`-defaulted, so nothing is strictly required at parse time. A verified minimal region (`sys_desc/regions/sram/nanosoc_region_sram.yaml`):

```yaml
module:
  name: nanosoc_region_sram
  gen: False
  params:
    SYS_ADDR_W: { type: int, default: 32, desc: "System address width" }
    RAM_ADDR_W: { type: int, default: 14, desc: "RAM address width" }
  interfaces:
    - { name: HCLK,    type: wire, direction: in,     params: { WIDTH: 1 } }
    - { name: HRESETn, type: wire, direction: in,     params: { WIDTH: 1 } }
    - { name: ahb_slave, type: ahb, direction: target,
        params: { ADDR_WIDTH: $SYS_ADDR_W, DATA_WIDTH: $SYS_DATA_W, EXCLUDE: [hburst, hmastlock] } }
  srams:
    - { name: u_sram, addr_width: $RAM_ADDR_W, data_width: $RAM_DATA_W }
```

The **footgun the guide must surface up front**: interface signal definitions are hard-coded Python tuples in `backends/protocol_utils.py` (`AHB_INITIATOR_SIGNALS`, `AHB_TARGET_SIGNALS`, `AXIS_SIGNALS`, `GPIO_SIGNALS`, …), **not** loaded from `lib/interfaces/*.yaml`. Verified: `parse_interface_definition` (`parser.py:141`) has zero call sites, and there is no `!include` constructor (`grep` for `!include`/`add_constructor` in `soc_model/*.py` returns nothing). The `lib/interfaces/*.yaml` files are documentation that silently drifts (they use `ADDR_W`/`parameters`/`role: slave` while real modules use `ADDR_WIDTH`/`params`/`direction: target`).

### 4.6 The validator (the guide's "validate before you build" story)

`SoCValidator.validate_all()` runs six checks in fixed order (verified `validator.py:35-40`): `_validate_connections`, `_validate_interconnects`, `_validate_address_overlaps`, `_validate_instance_references`, `_validate_known_rtl_modules`, `_validate_driver_coverage`. The "known RTL pitfall" check is driven by a hard-coded dict `_REQUIRED_RTL_PORTS` (`validator.py:457`) — currently only `cmsdk_ahb_to_apb` must declare `PCLKEN`/`PREADY`/`PSLVERR` or the APB bus hangs. `make -C sys_desc validate` is the seconds-cheap gate.

### 4.7 The three downstream paths

- **Sim:** `make -C cocotb <env>` (27 envs wired into the `ENVS` list in `cocotb/Makefile:25-35`; there are 42 env subdirectories on disk, but only those 27 are wired into `ENVS`), `SIM=vcs`, `TOPLEVEL=tb_top`, firmware preloaded via `+CODEFILENAME=` + `+define+RAM_PRELOAD`. Pass = absence of `<failure>` in `cocotb/<env>/results.xml`. (See `04-testbench-generation-default-tests.md` for default test generation and `03-ci-system-validity-matrix.md` for the CI conventions.)
- **FPGA:** `make -C sys_desc soc_model_fpga` (FPGA-sized memmap via `--config-override`), then `make -C pynq {package_ip,synth_only,build_design,pynq-deploy}`. Firmware must be the **25 MHz** tree. (See `07-toplevel-wrapper-generation-fpga-asic.md` for the FPGA wrapper and `08-vivado-block-diagram-generation.md` for the Vivado BD.)
- **ASIC:** `make -C syn/asic/design-compiler MODULE=nanosoc_multicore`; pads are hand-written per tech under `asic/ASIC/nanosoc_chip_pads/<tech>/`. (See `07-toplevel-wrapper-generation-fpga-asic.md` — it covers the ASIC top-level wrapper and chip-pads/tech.)

---

## 5. Proposed design

### 5.1 Where the guide lives

Create **one canonical guide** at:

```
nanosoc_arch_tech/docs/USER_GUIDE.md      # the generator-centric guide (this doc's deliverable target)
```

Rationale for `nanosoc_arch_tech/docs/`:
- `nanosoc_arch_tech` is the generator's home; the guide travels with the tool it documents, so it stays correct when the generator is reused in another project.
- It sits beside `docs/roadmap/` (where this design doc lives), so the roadmap and the user-facing guide are co-located.
- The existing project-root `docs/USER_GUIDE.md` is FAQ-style and project-specific (multicore IPC, PTP, SWD). We **do not duplicate** it; we make the new guide the *generator* manual and add a one-line pointer from the project-root guide ("To author your own SoC, see `nanosoc_arch_tech/docs/USER_GUIDE.md`").

> Note: the assignment writes *this design doc* to `nanosoc_arch_tech/docs/roadmap/09-user-guide.md`. The *implemented guide* that this doc specifies lands at `nanosoc_arch_tech/docs/USER_GUIDE.md`. Keep the two distinct.

### 5.2 The guide's structure (the outline to implement)

```
nanosoc_arch_tech/docs/USER_GUIDE.md
├── 1. The mental model (one diagram, ~1 page)
├── 2. Setup (source set_env.sh; what it does; prerequisites)
├── 3. Hello SoC walkthrough (the runnable minimal example — §5.3)
├── 4. Writing a YAML config
│   ├── 4a. Today's format (verbose) — with the simplified format from 05 flagged as "preferred once available"
│   ├── 4b. Field reference (AUTO-GENERATED table — §5.4)
│   └── 4c. Param refs ($NAME), $PARAM strings, EXCLUDE semantics
├── 5. Running the generator
│   ├── 5a. The right way: make -C sys_desc (and WHY not python -m soc_model directly)
│   ├── 5b. CLI reference (from __main__.py)
│   └── 5c. validate-only / config-override
├── 6. Understanding the outputs
│   ├── 6a. The build_soc/ tree
│   └── 6b. Artifact reference (AUTO-GENERATED table — §5.5)
├── 7. The three paths
│   ├── 7a. Sim (cocotb)         → cross-link 03 (CI) + 04 (testbench gen)
│   ├── 7b. FPGA (vivado)        → cross-link 07 (wrapper) + 08 (Vivado BD)
│   └── 7c. ASIC (pads/tech)     → cross-link 07 (wrapper + chip-pads)
├── 8. Troubleshooting / FAQ (footgun-driven — §5.6)
├── 9. Glossary (partly auto-stubbed — §5.7)
└── 10. Where to go next (roadmap cross-link index — §5.8)
```

### 5.3 The mental model diagram (goes at the top of §1)

```
                    YOU WRITE                         GENERATOR                       YOU CONSUME
   ┌──────────────────────────────────┐   ┌───────────────────────────┐   ┌────────────────────────────┐
   │ sys_desc/<soc>.yaml  (top)        │   │  parser  → builder         │   │ build_soc/rtl/*.sv  ──► sim │
   │   instances: [ region, subsys ]   │──►│    ↓ (Module object graph) │──►│ build_soc/firmware/ ──► fw  │
   │   interconnects: [ addr map ]     │   │  validator (6 checks)      │   │ build_soc/reports/*.html    │
   │ regions/*.yaml   subsystems/*.yaml│   │    ↓                       │   │ build_soc/docs/*.md         │
   │   (referenced BY NAME, found via  │   │  backends (15, fixed batch)│   │ build_soc/discovery/*.yaml  │
   │    --lib-dir scan)                │   └───────────────────────────┘   └────────────────────────────┘
   └──────────────────────────────────┘            ▲                                    │
                                          make -C sys_desc ALSO runs:                    │
                                          patch_ahb_to_apb.py + .ld wrap ◄───────────────┘ (post-process: REQUIRED)
```

Three sentences accompany it:
1. You describe the SoC as a tree of YAML *modules* (regions and subsystems) wired by an *interconnect* (the address map).
2. The generator turns the tree into one `Module` object graph, validates it, and emits RTL + firmware + reports.
3. `make -C sys_desc` is the real entry point — it runs the generator **and** the mandatory post-processing; `python -m soc_model` alone is the engine, not the car.

### 5.4 The field reference — auto-generated

The single worst maintenance hazard in a YAML guide is a field table that drifts from `builder.py`. We make it generated.

**Source of truth:** the `.get()` calls in `builder._build_*` methods plus the `model.py` dataclasses. We add a tiny introspection backend (or a standalone script) that walks the dataclass fields and emits a Markdown table the guide `INCLUDE`s.

Two options, in order of preference:

- **Option A (preferred): a new doc backend `SoCSchemaDocBackend`** that introspects the `model.py` dataclasses (`Module`, `Interface`, `Connection`, `Interconnect`, `InterconnectTarget`, `Register`, …) via `dataclasses.fields()` and emits `build_soc/docs/<top>_yaml_schema.md`. Field name, type, default, and the `desc`-from-docstring become rows. This shares the doc pipeline and runs every `make -C sys_desc`.
- **Option B (lighter): a checked-in generated file** `nanosoc_arch_tech/docs/_generated/yaml_field_reference.md` produced by a small `tools/gen_field_reference.py` run in CI, with a CI check that fails if it is stale (the same write-if-changed pattern `utils.write_if_changed` already uses).

Either way, the hand-written guide §4b contains a one-line "this table is generated from `model.py`; do not edit by hand" banner and an include/transclude of the generated table.

### 5.5 The artifact reference — auto-generated

Same hazard for the output table. The authoritative list is the backend invocation block in `__main__.py:139-313`. Generate it:

- Add to the introspection backend (Option A above) a pass that records, per backend, `(class_name, output_glob, one_line_role)`. The one-line role is a new class attribute `DOC_SUMMARY` on each backend (default `""`), so the table is generated from the code that produces the file, not from a parallel list. Emit `build_soc/docs/<top>_artifact_reference.md`.

This also fixes the existing drift where `nanosoc_gen/README.md:31-48` omits the SRAM report and the Python model.

### 5.6 The FAQ — built from real footguns

The FAQ is hand-written but each entry is *derived from a real, verified failure mode*. The seven that ship in M-FAQ:

1. **"My generated RTL won't elaborate / has duplicate ports / no `timescale`."** → You ran `python -m soc_model` directly. Run `make -C sys_desc` instead; it runs `patch_ahb_to_apb.py`. (`sys_desc/Makefile`.)
2. **"My linker script won't link — undefined sections."** → The generator emits MEMORY-only `.ld`. `make -C sys_desc` wraps them with `lib-nosys.ld` + `sections.ld`. Don't use `*_memory.ld` directly. (`sys_desc/Makefile`.)
3. **"UART prints 4× baud garbage on the board."** → Sim firmware (100 MHz) deployed to FPGA (25 MHz). Build the FPGA tree (`make firmware-fpga`) and guard with `scripts/check_firmware_clock.sh` (project root; there is no `ci/scripts/` dir). (`Makefile:54-67`, `README.md:319-344`.)
4. **"Module not found / instance has no resolved module."** → Module references are by `name`, resolved by scanning `--lib-dir` paths; a missing submodule or a typo silently yields an empty stub. Confirm all 8 lib-dirs resolve; init submodules. (`builder._resolve_instances`, `parser._scan_lib_dir`.)
5. **"I edited `lib/interfaces/ahb_slave.yaml` and nothing changed."** → Those files are dead code. The real signal tables are Python tuples in `backends/protocol_utils.py`. (Verified: `parse_interface_definition` has no call sites.)
6. **"`role: None` behaves differently from `role: ~`."** → `~` is YAML null; `None` is the literal string. Use `~`. (Both appear in the live YAML.)
7. **"APB bus hangs / `cmsdk_ahb_to_apb` floating inputs."** → A bare `rtl_module:` instance omitted `PCLKEN`/`PREADY`/`PSLVERR`. The validator catches this (`_REQUIRED_RTL_PORTS`, `validator.py:457`) — run `make -C sys_desc validate`.

Each entry: **symptom (the literal error/observation) → root cause → fix → cross-link**.

### 5.7 The glossary — partly auto-stubbed

Hand-written definitions for: `region`, `subsystem`, `interconnect`, `target`/`initiator`, `passthrough`, `EXCLUDE`, `gen` flag, `module` vs `rtl_module`, `address decode`, `discovery table`, `RDL`, `flist`, `ADP`, `HOSTIO4`, `BuildBusMatrix`, `config_pkg`, `memmap`, `linker profile`, `lib-dir`. The set of module/interconnect *names* in a given SoC can be auto-listed from the model (a "vocabulary of this SoC" sub-section), but the conceptual definitions stay hand-written.

### 5.8 Cross-link index (§10 of the guide)

The sibling roadmap docs **all already exist** in `docs/roadmap/` (verified by `ls docs/roadmap/*.md`). There is **no `00-*` overview doc** — the index below starts at 01. Topics and filenames are taken from each doc's title line:

| When you want to… | Read |
|---|---|
| Unit/golden-test the generator itself | `01-unit-testing-nanosoc-gen.md` |
| Understand the generator internals / add a backend or adapter | `02-clean-architecture-adapters-backends.md` |
| Sweep configs across a parameter range in CI | `03-ci-system-validity-matrix.md` |
| Generate testbenches + a default test set | `04-testbench-generation-default-tests.md` |
| Use the simplified YAML format | `05-simplified-yaml-format.md` |
| Build a web YAML editor/builder | `06-web-gui-yaml-builder.md` |
| Build/understand the FPGA **and** ASIC top-level wrappers (incl. chip-pads/tech) | `07-toplevel-wrapper-generation-fpga-asic.md` |
| Generate a Vivado block diagram with typed interconnect ports | `08-vivado-block-diagram-generation.md` |

> The index above is grounded against the current `docs/roadmap/*.md`. Because filenames can still be renamed mid-batch, the guide's implemented §10 should **regenerate this table from `ls docs/roadmap/*.md`** (parsing each doc's first `# ` heading for the topic) so it self-heals rather than hard-coding the strings.

### 5.9 The "hello SoC" example — design

A real, committed, runnable minimal SoC under `nanosoc_arch_tech/docs/examples/hello_soc/`:

- `hello_soc.yaml` — top module with **one CPU-less skeleton**: a single SRAM region + a single AHB interconnect with one initiator (a debug/HOSTIO master) and one target (the SRAM). Small enough to read in full (~40 lines), large enough to exercise parse → validate → AHB interconnect → toplevel → firmware → reports.
- `README.md` — the exact commands, expected console output, and the resulting `build_soc/` tree, copy-pasteable.

Why a real file and not a fictional snippet: it doubles as a **CI smoke test for the guide** (M-EXAMPLE). If `python -m soc_model hello_soc.yaml` ever stops producing the documented artifacts, CI fails and the guide is provably stale.

**Grounding caveat (verified):** in the real `sys_desc/nanosoc_multicore_soc.yaml`, *every* AHB-Lite interconnect initiator carries a backing `instance:` (e.g. `eth_ss_m → u_eth_ss_0`, `dma_230_0_m → u_dma_230_0`, `dap_ss_0_m → u_dap_ss_0`; `sys_desc/nanosoc_multicore_soc.yaml:1665-1666`). There is **no** instance-less initiator in any live SoC YAML. So the M4 sketch's instance-less `debug_m` initiator is the one unconfirmed construct. Treat it as a hypothesis to validate, not a known-good pattern.

If a CPU-less / instance-less initiator turns out not to satisfy the AHB backend's BuildBusMatrix expectations (`BuildBusMatrix.pl` may require a real initiator *instance*, not just an `initiators:` entry — Open Question #1), the example **falls back to a known-generatable shape**: add a minimal real master instance (e.g. a `nanosoc_dbg_ahb_bridge`-style or a single CPU subsystem) as the initiator's backing instance, OR document the smallest *existing* generatable config (a trimmed copy of the multicore SoC) instead of inventing one. The fallback is concrete and incremental — it does not block M1–M3.

---

## 6. Implementation plan

Each milestone is independently shippable: even M1 alone is a usable improvement over today.

### M1 — Skeleton guide + mental model + setup (hand-written)
- **Changes:** Create `nanosoc_arch_tech/docs/USER_GUIDE.md` with §1 mental model (diagram from §5.3), §2 setup (what `source set_env.sh` does — submodule init, env vars, auto-regen), and §10 cross-link index. Add a one-line pointer from project-root `docs/USER_GUIDE.md`.
- **Why:** Establishes the front door and the routing; immediately useful even before the generated tables exist.
- **Acceptance:** A reviewer who has never seen the repo can, following §2, get a green `make -C sys_desc validate` on the existing `nanosoc_multicore_soc.yaml`. The diagram matches the verified pipeline (parser→builder→validator→backends + mandatory post-process).

### M2 — Running the generator + outputs (hand-written, grounded)
- **Changes:** §5 (run the generator: `make -C sys_desc` vs `python -m soc_model`, full CLI table from `__main__.py:38-61`, `--validate-only`, `--config-override`) and §6 (the `build_soc/` tree and a *manually written first draft* of the artifact table).
- **Why:** The single biggest correctness win — stops people running the engine without the post-processing.
- **Acceptance:** Every CLI flag in the §5 table appears in `argparse` (`__main__.py`); every `build_soc/` subdir in §6 appears in the comment block at `__main__.py:118-128`. A reviewer runs each documented command and gets the documented files.

### M3 — Auto-generated field & artifact reference
- **Changes:** Add `SoCSchemaDocBackend` (new file `nanosoc_gen/soc_model/backends/schema_doc.py`) that introspects `model.py` dataclasses and the backend list, emitting `build_soc/docs/<top>_yaml_schema.md` and `<top>_artifact_reference.md`. Wire it into `__main__.py` after `docs.py`. Add `DOC_SUMMARY` class attrs to the backends. Guide §4b and §6b transclude/reference these.
- **Why:** Kills the drift hazard for the two tables most likely to rot.
- **Acceptance:** Generated schema table lists every public field of `Module`/`Interface`/`Interconnect*`/`Register*` with type+default; artifact table lists every file the run actually produced. Diff the artifact table against `ls build_soc -R` — no missing/extra rows. `write_if_changed` means a no-op rerun produces no diff.

### M4 — "Hello SoC" worked example + walkthrough
- **Changes:** Add `nanosoc_arch_tech/docs/examples/hello_soc/{hello_soc.yaml,README.md}`. Write guide §3 as a step-by-step against it (commands + expected output + resulting tree).
- **Why:** Concrete, runnable anchor; removes "where do I even start."
- **Acceptance (two-tier, because the minimal form is unconfirmed):**
  1. *Gate that always holds:* `make -C docs/examples/hello_soc validate` (i.e. `python -m soc_model hello_soc.yaml --lib-dir <sram region dir> --validate-only`) exits 0. Validation is instance/connection-level and does not invoke `BuildBusMatrix.pl`, so this passes regardless of the Open Question #1 outcome.
  2. *Full-generation gate:* `python -m soc_model hello_soc.yaml --lib-dir <sram region dir> --build-dir /tmp/hello` produces the documented artifacts and the §3 transcript matches actual console output. **If** the instance-less initiator is rejected by the AHB backend, the committed `hello_soc.yaml` is the instance-backed fallback (§5.9) instead — so this gate is written against whichever form is actually committed, and the doc never claims an un-run command works.

### M5 — Troubleshooting/FAQ + glossary
- **Changes:** §8 (the seven footgun FAQ entries from §5.6, each with literal symptom/cause/fix/link) and §9 (glossary from §5.7, plus optional auto-listed "vocabulary of this SoC").
- **Why:** Converts the lab's tribal knowledge (and project MEMORY.md hard-won fixes) into discoverable doc.
- **Acceptance:** Each FAQ entry references a real symbol/path (verified); the clock-trap entry matches `scripts/check_firmware_clock.sh`; the `_REQUIRED_RTL_PORTS` entry matches `validator.py:457`.

### M6 — The three-paths chapter + simplified-format pass + CI doc-staleness gate
- **Changes:** §7 (sim/FPGA/ASIC) cross-linking `03`/`04` (sim/CI + testbench gen), `07`/`08` (FPGA wrapper + Vivado BD), and `07` (ASIC wrapper + chip-pads). Once `05-simplified-yaml-format.md` lands, add §4a's "preferred format" examples. Add a CI job (`make -C docs check` or a `ci/` script) that re-runs M3's generation and M4's example and fails on diff or on missing artifacts.
- **Why:** Completes the guide and makes it self-defending against rot. Ties into the CI doc (`03-ci-system-validity-matrix.md`).
- **Acceptance:** CI fails if the field/artifact tables are stale or the hello-SoC example breaks; passes on a clean tree.

---

## 7. File & module changes

### New files

| Path | Purpose |
|---|---|
| `nanosoc_arch_tech/docs/USER_GUIDE.md` | The guide itself (M1–M6) |
| `nanosoc_arch_tech/docs/examples/hello_soc/hello_soc.yaml` | Runnable minimal SoC (M4) |
| `nanosoc_arch_tech/docs/examples/hello_soc/README.md` | Walkthrough transcript (M4) |
| `nanosoc_arch_tech/nanosoc_gen/soc_model/backends/schema_doc.py` | `SoCSchemaDocBackend` (M3) |

### Modified files

| Path | Change |
|---|---|
| `nanosoc_gen/soc_model/__main__.py` | Import + invoke `SoCSchemaDocBackend` after the docs backend (M3) |
| `nanosoc_gen/soc_model/backends/*.py` | Add a `DOC_SUMMARY` class attr per backend (M3) |
| `nanosoc-multicore-system/docs/USER_GUIDE.md` | One-line pointer to the new generator guide (M1) |
| `nanosoc_gen/README.md` | Fix the wrong invocation; point at `docs/USER_GUIDE.md` (M2) |
| `.gitlab-ci.yml` and/or `ci/` | Doc-staleness gate (M6) |

### Signatures introduced (M3)

The new backend follows the existing per-backend shape (`__init__(top_module)`, a `generate(...)` returning a `Path`), staying consistent with `SoCDocsBackend`:

```python
# nanosoc_gen/soc_model/backends/schema_doc.py
import dataclasses
from pathlib import Path
from .. import model
from ..utils import write_if_changed


class SoCSchemaDocBackend:
    """Emit Markdown reference tables (YAML field schema + artifact inventory)
    by introspecting model.py dataclasses and the backend list, so the
    user guide's reference tables cannot drift from the code."""

    # Dataclasses whose fields become the YAML field reference.
    _SCHEMA_TYPES = [
        model.Module, model.Interface, model.Connection,
        model.Interconnect, model.InterconnectTarget,
        model.InterconnectInitiator, model.Register, model.RegisterField,
    ]

    def __init__(self, top_module):
        self.top = top_module

    def generate(self, docs_dir: Path) -> Path:
        docs_dir.mkdir(parents=True, exist_ok=True)
        schema_md = self._render_schema()
        out = docs_dir / f"{self.top.name}_yaml_schema.md"
        write_if_changed(str(out), schema_md)
        return out

    def _render_schema(self) -> str:
        lines = ["# YAML Field Reference (generated from model.py — do not edit)\n"]
        for cls in self._SCHEMA_TYPES:
            lines.append(f"\n## `{cls.__name__}`\n")
            lines.append("| field | type | default |")
            lines.append("|---|---|---|")
            for f in dataclasses.fields(cls):
                default = (f.default if f.default is not dataclasses.MISSING
                           else f.default_factory() if f.default_factory is not dataclasses.MISSING  # type: ignore
                           else "—")
                lines.append(f"| `{f.name}` | `{_type_str(f.type)}` | `{default}` |")
        return "\n".join(lines) + "\n"
```

```python
# nanosoc_gen/soc_model/__main__.py  (after the docs backend block, ~:313)
from .backends.schema_doc import SoCSchemaDocBackend
...
print("\n--- Schema & Artifact Reference ---")
schema_backend = SoCSchemaDocBackend(top_module)
schema_path = schema_backend.generate(docs_dir)
print(f"  Generated: {schema_path}")
```

> Confirm the exact `model.py` class names against the file before listing them in `_SCHEMA_TYPES` (the digest lists `Module`/`Interface`/`Connection`/`Interconnect`/`InterconnectTarget`/`InterconnectInitiator`/`Register`/`RegisterField` — re-read `model.py` to be sure none were renamed).

### Hello-SoC YAML sketch (M4) — verbose format, today's schema

```yaml
# nanosoc_arch_tech/docs/examples/hello_soc/hello_soc.yaml
module:
  name: hello_soc
  gen: True
  desc: "Minimal example SoC: one debug master, one SRAM target."
  params:
    SYS_ADDR_W: { type: int, default: 32 }
    SYS_DATA_W: { type: int, default: 32 }
  clocks: [ { name: HCLK,    source: clk_i } ]
  resets: [ { name: HRESETn, active: low, source: nrst_i } ]
  interfaces:
    - { name: HCLK,    type: wire, direction: in, params: { WIDTH: 1 } }
    - { name: HRESETn, type: wire, direction: in, params: { WIDTH: 1 } }
  instances:
    - instance_name: u_sram_0
      module: nanosoc_region_sram        # resolved via --lib-dir scan
      addressable: True
      connections:
        - { port: HCLK,    conn: HCLK }
        - { port: HRESETn, conn: HRESETn }
  interconnects:
    - name: hello_interconnect
      gen: True
      type: ahb_lite
      targets:
        - { name: sram_0, instance: u_sram_0, base: 0x80000000, size: 0x00010000,
            sw_access: rwx, region_type: memory }
      initiators:
        # UNCONFIRMED: every real SoC initiator has a backing `instance:`
        # (verified in nanosoc_multicore_soc.yaml:1665-1666). This instance-
        # less form must be validated against BuildBusMatrix before shipping;
        # if it fails, switch to the `instance:`-backed form shown below.
        - { name: debug_m, targets: [ sram_0 ] }
```

> The instance-less `debug_m` above is **not** how any live SoC declares an initiator — in `nanosoc_multicore_soc.yaml` every initiator names a backing `instance:` (e.g. `eth_ss_m`/`u_eth_ss_0` at `:1665-1666`). Validate the instance-less form against `BuildBusMatrix.pl` at implement time (Open Question #1). If it is rejected, use the verified instance-backed form instead, e.g.:
>
> ```yaml
>   instances:
>     - instance_name: u_dbg_master_0
>       module: nanosoc_dbg_ahb_bridge   # or a minimal AHB master that resolves via --lib-dir
>       # ... clock/reset connections ...
>   interconnects:
>     - name: hello_interconnect
>       type: ahb_lite
>       initiators:
>         - { name: debug_m, instance: u_dbg_master_0, targets: [ { name: sram_0 } ] }
> ```
>
> (Note the verified initiator `targets:` shape is a list of `{ name: <target> }` mappings, as at `:1667-1671`, not a bare list of strings.)

---

## 8. Testing & validation

- **M1/M2 (prose correctness):** A reviewer follows the guide on a clean checkout. The acceptance is behavioural — `make -C sys_desc validate` green, every documented file present. Pair with a `grep`-based check that each CLI flag named in §5 exists in `__main__.py` `argparse`.
- **M3 (generated tables):** Unit-testable. Add a pytest under the generator (the project has `python/tests/` for the GUI; the generator currently has no `nanosoc_gen/tests/` — M3 is a good reason to start one) that asserts `SoCSchemaDocBackend._render_schema()` contains a row for a known field (e.g. `Module.gen`, `InterconnectTarget.base`). Idempotency: run twice, `write_if_changed` produces no second diff.
- **M4 (hello SoC):** CI job runs the example end-to-end and diffs the produced artifact set against the committed expectation. This is the canary for guide rot.
- **M5 (FAQ):** Each entry must cite a verified symbol/path; reviewer cross-checks against the file. The clock-trap entry is testable by running `scripts/check_firmware_clock.sh` against mismatched presets.
- **M6 (CI gate):** The doc-staleness job is itself the test — it re-generates M3's tables and M4's example into a temp dir and fails on diff or missing artifact. This is exactly the cheap "validate before build" gradient described in `03-ci-system-validity-matrix.md` (parse+validate in seconds; the doc gate sits at that tier).

Interaction with the CI/unit-testing docs (`03-ci-system-validity-matrix.md` for the CI matrix, `01-unit-testing-nanosoc-gen.md` for the generator's own unit tests): the doc-staleness gate is a new, cheap CI stage that runs alongside `--validate-only`. It must run **after** the `soc_gen` stage (it consumes `build_soc/docs/`), and it should be `allow_failure: false` once M3 is stable so the guide cannot silently drift.

---

## 9. Risks, tradeoffs, alternatives considered

- **Risk: prose still rots despite generated tables.** Mitigation: keep hand-written prose conceptual (mental model, FAQ, glossary) and push everything enumerable (fields, artifacts, vocabulary, roadmap index) into generation. The hand-written FAQ rots slowest because footguns are stable; M6's CI gate covers the enumerable parts.
- **Risk: the hello-SoC example can't be generated without a CPU/interconnect minimum.** This is the biggest unknown (the AHB backend shells out to ARM `BuildBusMatrix.pl`, which may require a real initiator). Mitigation: M4 falls back to the smallest *existing* config and documents that; the example is "nice to have," not load-bearing for M1–M3.
- **Risk: two USER_GUIDE.md files confuse readers.** Mitigation: distinct titles ("NanoSoC Generator User Guide" vs the project-root project guide) + explicit cross-pointers. Alternative considered: merge into one — rejected, because the generator guide must travel with `nanosoc_arch_tech` when reused elsewhere, while the project guide is multicore-specific.
- **Tradeoff: `SoCSchemaDocBackend` adds another backend to the already-procedural `__main__.py` batch.** Accepted — it follows the exact existing pattern (`__init__(top)`, `generate(dir)`), and the alternative (a standalone script run in CI, Option B in §5.4) is lighter but lives outside the generation run and can be forgotten. Prefer A; B is the fallback if `02-clean-architecture` hasn't introduced a backend base class yet.
- **Tradeoff: documenting today's verbose YAML before 05 lands.** Accepted — the guide ships in two passes; teaching the real format now beats waiting. When 05 lands, §4a gets the sugar; the field reference (generated) updates automatically if the builder pre-pass expands sugar into the same dict shape.
- **Alternative considered: auto-generate the *entire* guide from the model.** Rejected — the mental model, FAQ, and glossary are pedagogical and need a human voice; over-generating produces a reference, not a guide.

---

## 10. Dependencies & sequencing

**Builds on (cross-links):**
- `05-simplified-yaml-format.md` — the §4a "preferred format" content (M6) depends on it; until then the guide teaches the verbose format and flags 05 as upcoming.
- `02-clean-architecture-adapters-backends.md` — if a backend base class lands there, `SoCSchemaDocBackend` (M3) should subclass it; otherwise it follows the current ad-hoc pattern.
- `03-ci-system-validity-matrix.md` — the doc-staleness CI gate (M6) depends on its CI conventions; `04-testbench-generation-default-tests.md` backs the sim chapter (§7a).
- `07-toplevel-wrapper-generation-fpga-asic.md` (FPGA + ASIC wrappers and chip-pads, §7b/§7c) and `08-vivado-block-diagram-generation.md` (Vivado BD, §7b) — cross-linked by the three-paths chapter.

**Unblocks / ties together:**
- This is the **integrating doc** — it is the front door that routes a newcomer into every other roadmap doc (§5.8 index). It does not unblock new *features*, but it unblocks *adoption*: a newcomer cannot use 02–08 without 09 to orient them.

**Sequencing:** M1→M2 can ship immediately (pure prose against verified code). M3 can ship in parallel (independent backend). M4 depends on confirming the minimal-SoC generation question. M5 ships anytime after M1. M6 depends on 05 (for §4a) and on M3+M4 existing (for the CI gate).

**Effort estimate:**
- M1 **S**, M2 **S**, M3 **M** (new backend + dataclass introspection + tests), M4 **M** (depends on the minimal-SoC unknown), M5 **S**, M6 **M** (CI wiring + 05 dependency).
- Total: **M–L** overall; M1+M2+M5 alone (≈**M**) already replace the misleading status quo.

---

### Open questions (could not resolve from the code alone)

1. **Can a minimal CPU-less SoC be generated?** The AHB backend shells out to ARM `BuildBusMatrix.pl` (`ahb.py`). Whether it tolerates a single-initiator/single-target matrix, or requires a real initiator *instance* (not just an interconnect `initiators:` entry), determines whether the hello-SoC example in M4 is buildable as sketched or must fall back to an existing config. Needs a trial run.
2. **Exact `model.py` class names for `_SCHEMA_TYPES`.** The digest names them, but they must be re-read from `model.py` at implement time in case of renames (the project has had recent hierarchy renames per MEMORY.md).
3. **Final filenames of sibling roadmap docs.** All eight siblings (01–08) plus this `09-user-guide.md` are confirmed present in `docs/roadmap/` and §5.8 is grounded against them. The remaining (low) risk is a mid-batch rename, so the implemented §10 cross-link index should still be **generated from `ls docs/roadmap/*.md`** (parsing each first `# ` heading for the topic) so it self-heals rather than hard-coding strings.
4. **Whether `02-clean-architecture` introduces a backend base class** before M3 — if yes, `SoCSchemaDocBackend` should inherit it; if no, it follows today's ad-hoc per-backend convention.
