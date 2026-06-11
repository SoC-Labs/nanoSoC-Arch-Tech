# 06a — SoC Configurator web app: implementation plan

*Refreshes and supersedes the phasing in `06-web-gui-yaml-builder.md`. Doc 06's
architecture survives; its scope was written before doc-05 (simplified YAML),
doc-07 (chip/pad/FPGA/UPF), and the constraints generator shipped — all of
which are now live, so the "run the whole build" goal moves from stretch to
core. This plan is grounded in the code as of `feature/nanosoc-gen-roadmap`
(nanosoc_gen `c2a03a2`) and superproject master `7cc0ebd`.*

---

## 1. Goal

A web app (local web server) that lets an engineer **configure a SoC end to
end**:

1. compose the system from a palette of known modules/subsystems and presets;
2. see a live **architecture diagram in the style of the multicore demo GUI**
   (bus-matrix spine, CPU/initiator blocks, peripheral grid — not the
   force-directed D3 view);
3. get **validation as they edit** — both the generator's semantic checks and
   a new **system-completeness rules** layer ("certain components must be in
   the system");
4. **emit the sys_desc YAML**, then
5. **run the entire build flow** from the browser — generate RTL (all
   backends incl. constraints/pads/FPGA wrapper), apply the Makefile
   post-passes, optionally build firmware — with live log streaming and an
   artifacts browser.

---

## 2. What already exists (asset inventory)

| Asset | Where | What it gives us |
|---|---|---|
| Semantic validator | `soc_model/validator.py` | `SoCValidator(module).validate_all()` → `List[ValidationMessage]` (level/category/instance/port/message). Pure Python, no file I/O, ~50–150 ms for real SoCs. Checks: width, direction, references, address overlaps, instance refs, driver coverage, known RTL pitfalls (e.g. `cmsdk_ahb_to_apb` PCLKEN/PREADY/PSLVERR). |
| Build-from-dict | `soc_model/builder.py` | `SoCBuilder._build_module(dict)` constructs the model from an in-memory dict — the GUI never needs files to validate. (M1 promotes this to a public `build_from_dict()`.) |
| Simplified-YAML expander | `soc_model/expand.py` | `PresetLibrary.from_dirs()`, `make_expander()` — preset catalog + desugar (`uses:`, `auto_base`). Identity-safe. |
| Option catalogs | `lib/{presets,interfaces,pad_tech,pin_map,chip_boundary,fpga_profile}/` + `parser.parse_pad_tech/pin_map/chip_boundary/fpga_profile()` | Everything a "Target technology / Package / FPGA board" dropdown needs. |
| Templates | `tests/fixtures/*.yaml` (minimal, two_region, apb_bridge, firmware, nested_subsystem, firmware_multicore, constraints, gpio_chip) | "New SoC from template" gallery, already hermetic and validated by the 940-test suite. |
| Demo-GUI frontend | `python/nanosoc_multicore/demo_gui/` | FastAPI app factory + panel auto-discovery (`app.py:53-66`), Jinja2 + vanilla-JS panel system, WebSocket Hub + telemetry pump (`streams.py:23-75`), toast/log UX, and — critically — the **SVG diagram builder**: `mk()/txt()/blk()/fitText()` helpers (`static/js/panels/dashboard.js:67-214`), bus-spine + peripheral-grid layout (`:230-348`), click-to-popover details (`:595-657`). |
| Deep-dive diagram | `soc_model/backends/html.py` | The self-contained D3 connectivity HTML (graph + address map + initiator maps + hierarchy + validation). Its `_build_*_data()` methods return JSON-serializable dicts reusable as API payloads; the rendered HTML embeds as an iframe "deep dive" view. |
| Build flow | `sys_desc/Makefile` + `soc_model/__main__.py` | The full pipeline incl. `--emit-constraints`, pads/FPGA/UPF, and the 4 Makefile post-passes (dma250 qctrl, memmap symlinks, compat header, `.ld` wrapping). `--validate-only` for the fast path. |
| Whole-flow timing facts | measured | parse+build+validate ≈ 0.15 s; `BuildBusMatrix.pl` ≈ 120 s **per interconnect** (needs `ARM_IP_LIBRARY_PATH` + perl); full multicore `make soc` ≈ minutes; firmware cmake ≈ 1 min. Drives the async/streaming design. |

**The one real gap:** there is no model→YAML serializer. Doc 06's answer
stands: the GUI edits the **raw dict** (what the parser loads / builder
consumes), builds a transient `Module` only for validation/diagram, and emits
YAML by dumping the dict. No round-trip serializer needed.

---

## 3. Architecture

### 3.1 Where it lives

A **standalone app inside nanosoc_gen** — `soc_model/configurator/` — *not* a
panel in the demo GUI:

- Design-time vs run-time: the demo GUI is a run-time cockpit bound to a HAL
  and a board; the configurator is design-time and must work for **any**
  nanosoc_gen project, with no superproject dependency.
- The proven frontend pieces (panel registry, SVG helpers, Hub, CSS) are
  **vendored** (copied) into `configurator/static/` rather than imported —
  they're ~hundreds of lines of dependency-free JS and the two apps should
  not be release-coupled.
- A thin **project adapter** binds it to a concrete repo (default: the
  multicore superproject):

```toml
# <repo>/configurator.toml  (or --project flags)
top_yaml   = "sys_desc/nanosoc_multicore_soc.yaml"
lib_dirs   = [ "sys_desc", "nanosoc_arch_tech/sys_desc", ... ]   # the 8 dirs
build_dir  = "build_soc"
make       = { soc = "make -C sys_desc soc_model_fpga", env = "set_env.sh" }
firmware   = { preset = "gcc-m0plus-le-25mhz", targets = ["generate_smoke_bootrom"] }
rules      = "lib/rules/nanosoc_completeness.yaml"               # see §5.3
```

### 3.2 Three layers

```
soc_model/gui_service.py      PURE python (no web deps) — unit-tested in the
                              existing pytest suite:
                                load_yaml/save_yaml (dict<->file, path-guarded)
                                validate(dict, lib_dirs) -> [msg]   (3 tiers, §5)
                                diagram(dict, lib_dirs)  -> layout JSON (§4)
                                catalogs(lib_dirs)       -> modules/presets/techs/
                                                            pin_maps/boundaries/
                                                            profiles/templates
                                expand_preview(dict)     -> canonical dict (doc-05)
                                pack_preview(ic)         -> auto_base packing result

soc_model/configurator/       FastAPI app (optional extra: fastapi+uvicorn+jinja2)
  app.py, routers/*.py          /api/* endpoints (§7) + /ws log-and-status Hub
  jobs.py                       build pipeline runner (§6)
  project.py                    project adapter loader

configurator/static+templates Vanilla JS + Jinja2, vendored demo-GUI patterns.
                              Panels: Compose | Diagram | Memory Map | YAML |
                                      Build | Artifacts
```

Launch: `python -m soc_model.configurator serve --project <repo> [--port 8090]`.

### 3.3 Editing model (from doc 06, unchanged)

The single source of truth in the browser is the **YAML dict** (JSON over the
wire). Forms and the diagram are projections of it; every mutation goes
through the dict; the server rebuilds a transient `Module` per validation
call. Export = `yaml.dump(dict)`. This avoids the missing model→YAML
serializer entirely and means hand-written YAML (including doc-05 sugar)
survives load→edit→save untouched except where edited.

---

## 4. The architecture diagram (demo-GUI style)

**Reuse the demo dashboard's visual language, but generate the layout from
the model instead of hardcoding it.** The demo's curated look comes from a
hand-written `PERIPH_META` dict (dashboard.js:39-64); the configurator
derives the same structure mechanically:

- **Initiator row** (top): one block per interconnect initiator, classified
  by its instance's module (`cpu*` → CPU block w/ sub-rows, `dap`/`debug` →
  debug block, `dma` → DMA). Subsystems render as containers with their
  passthrough ports.
- **Bus spine** (middle): one horizontal AHB bar per interconnect (the
  multicore has one main matrix; nested-subsystem SoCs get nested spines on
  drill-down).
- **Target grid** (bottom): targets grouped by `region_type`
  (memory / periph / subordinate-bus), labelled with name + base/size,
  unknowns falling into an "other" bin exactly like the demo.
- Vendored helpers: `mk/txt/blk/fitText` (text-overflow guard is the thing
  that makes these diagrams stay legible) + the details popover.

Interactions:
- **click block → opens that element's edit form** (the Compose panel scrolls
  to/focuses the instance or target) — the diagram is a navigation surface,
  not just a picture;
- **validation badges**: blocks with errors/warnings get red/amber dots; the
  completeness checklist (§5.3) highlights *missing* required blocks as
  ghosted placeholders ("⬚ bootrom — required, not present: click to add");
- **drill-down** into `gen: True` subsystems (recurse on the resolved child
  module — same renderer);
- a **"Deep dive" tab** embeds the generated D3 connectivity HTML
  (`SoCVisualizer.generate_html()` to a temp file, served in an iframe) for
  the full force-directed graph + per-initiator maps when wanted.

Server side, `gui_service.diagram()` returns a layout-neutral JSON
(initiators/spines/targets/groups/badges) so the JS stays a dumb renderer.

---

## 5. Validation (three tiers)

Runs server-side on every debounced edit (~300 ms idle), aggregated into one
message list with `tier` tags; the UI shows a gutter (YAML panel), per-field
errors (forms), block badges (diagram), and a completeness checklist.

### 5.1 Tier 1 — structural lint (instant)
Schema-level checks the builder silently tolerates (doc 06 §5.4): required
keys (`instance_name`, target `name`), enum values (`direction`, `type`,
`region_type`, `sw_access`), `module:` vs `rtl_module:` exclusivity, hex
parseability, `uses:` preset existence, duplicate names. Pure dict walking,
no model build.

### 5.2 Tier 2 — semantic validation (the real validator, ~150 ms)
`build_from_dict()` → `SoCValidator.validate_all()` — identical results to
`--validate-only`, so what's green in the GUI is green in CI/make. Builder
exceptions (bad refs) are caught and surfaced as messages, not 500s.

### 5.3 Tier 3 — system-completeness rules (NEW — "ensure certain components")
A small declarative rules engine in `gui_service` reading a per-project rules
file, because "what makes a *complete* system" is project policy, not
generator semantics:

```yaml
# lib/rules/nanosoc_completeness.yaml
rules:
  - id: cpu-initiator        # at least one CPU master on the main matrix
    level: error
    require: { initiator_module_matches: "(cpu|cm0|m0plus|eth_ss)" }
  - id: reset-vector-memory  # something fetchable at the boot address
    level: error
    require: { target_at_address: 0x10000000, region_type: memory }
    hint: "Add a bootrom (role: bootrom) or an IMEM with preload"
  - id: bootrom-role         { level: warning, require: { target_role: bootrom } }
  - id: clock-reset          { level: error, require: { external_wires: [sys_fclk|sys_hclk, "*resetn"] } }
  - id: debug-access         { level: warning, require: { initiator_module_matches: "(dap|swj|debug)" },
                               hint: "No debug initiator — SWD bring-up will not work" }
  - id: firmware-targets     # every linker-profile region resolves to a real window
    level: error
    require: { firmware_regions_resolve: true }
  - id: uart-present         { level: info, require: { instance_module_matches: "uart" },
                               hint: "No UART — console bring-up will be blind" }
  - id: apb-config           { level: error, require: { apb_targets_have_config: true } }
```

Each `require` keyword maps to one ~10-line predicate over the built model.
The GUI renders these as a **checklist** ("System completeness 6/8 ✓") and
the diagram ghosts the missing blocks. Errors **gate the build button**;
warnings need an explicit override tick.

---

## 6. YAML emission + the build pipeline

### 6.1 Workspace → apply → build

- Edits live in a **draft workspace** (`<repo>/.configurator/drafts/<name>/`)
  with autosave + named snapshots — never directly in `sys_desc/`.
- **Apply to project** writes the top YAML (and any region/register-map files
  the session created) into `sys_desc/`, showing a **unified diff vs the
  current file** first. Path-guarded (no writes outside the project; never
  under `ARM_IP_LIBRARY_PATH`/`/research/AAA`).
- Export modes: *round-trip* (dict as edited, sugar preserved), *canonical*
  (doc-05 expander applied — for diffing against legacy files), and
  *download* (browser file, no repo write).

### 6.2 The pipeline (the user's "entire build flow")

`jobs.py` runs a staged pipeline, one job at a time (lock), each stage a
subprocess with stdout/stderr streamed line-by-line over the WS Hub and a
status chip in the Build panel:

| Stage | Command | Typical time | Gate |
|---|---|---|---|
| 1. Emit YAML | gui_service.save (apply) | instant | tier-1..3 clean |
| 2. Validate | `python -m soc_model … --validate-only` | ~5 s | exit 0 |
| 3. Generate | `make -C sys_desc soc_model[_fpga]` (full backends incl. constraints + post-passes) | minutes (BuildBusMatrix ≈120 s/IC) | exit 0 |
| 4. Firmware *(opt)* | `cmake --preset … --target …` | ~1 min | exit 0 |
| 5. Reports | collect `build_soc/reports`, memory map, sram report, constraints | instant | — |
| 6. Sim smoke *(stretch, opt-in)* | one cocotb env | tens of min | — |
| 7. FPGA bitstream *(stretch, opt-in)* | `make -C pynq build_design` | ~30 min | — |

Environment: the runner sources the project adapter's `env` script
(`set_env.sh`) in the subprocess shell; stage 3 hard-fails early with a clear
message if `ARM_IP_LIBRARY_PATH`/perl are missing (the #1 support trap).

### 6.3 Artifacts panel
After stage 3: rendered memory map + hierarchy text, the SRAM report, the
generated SDC/XDC, the connectivity HTML (iframe), flist tree, and a
**zip-download of `build_soc/`**. After stage 4: the `.bin/.hex` list.

---

## 7. API surface

```
GET  /api/project                      adapter info, env health (perl? ARM IP? jinja2?)
GET  /api/catalog/{modules|presets|pad_techs|pin_maps|boundaries|fpga_profiles|templates}
GET  /api/draft / POST /api/draft      list/create (from template or existing top yaml)
GET  /api/draft/{id}/yaml              raw dict (JSON)  |  PUT … update
POST /api/draft/{id}/validate          → {tier1[], tier2[], tier3[], checklist}
GET  /api/draft/{id}/diagram           → layout JSON (§4)
GET  /api/draft/{id}/deepdive          → generated D3 HTML
POST /api/draft/{id}/pack              auto_base packing preview/apply
POST /api/draft/{id}/expand            doc-05 canonical preview
GET  /api/draft/{id}/export?mode=…     YAML download
POST /api/draft/{id}/apply             write into sys_desc (returns diff first w/ ?dry=1)
POST /api/build  {stages:[…]}          start pipeline   |  GET /api/build/status
WS   /ws                               logs, stage status, validation pushes
GET  /api/artifacts/…                  build_soc browser + zip
```

---

## 8. Additional features (brainstorm, prioritized)

**High value, low cost (fold into core milestones):**
- **Memory-map ruler** — horizontal address bar per interconnect with target
  windows drawn to scale, overlap regions flashing red (data already exists
  in `_build_address_map()`); an **"auto-pack" button** running the doc-05
  `auto_base` packer with a before/after preview.
- **Diff-vs-built** — show what changed between the draft and the YAML that
  produced the current `build_soc/` (catches "did I regenerate?" confusion —
  the staleness gotcha set_env only partially covers).
- **Env health banner** — green/amber checks for python deps, perl,
  `ARM_IP_LIBRARY_PATH`, jinja2, peakrdl at startup (most first-run failures).
- **Explain-this-field tooltips** sourced from the USER_GUIDE's field
  reference (4b) — the guide is already code-accurate; link each form field
  to its anchor.
- **Param/override panel** — edit top params + `PARAM_OVERRIDES`
  (`--config-override`) with the explicit note that overrides change
  memmap/linker numbers, not RTL store sizes (the documented trap).

**Medium (post-MVP):**
- **Register-map editor** — table editor for `register_maps/*.yaml`
  (offset/width/access/fields) feeding rdl/discovery.
- **IRQ map editor** — a matrix of IRQ sources → NVIC lines, generating the
  `concat` glue (today the #1 hand-editing pain; the cpu1-periph IRQ gap
  showed the cost).
- **Firmware linker-profile editor** — visual MEMORY-block editor with the
  `size_adjust`/`phys_size` semantics enforced.
- **Config snapshots + shareable JSON** — save/load named configurations,
  export a single JSON blob for issue reports.
- **Undo/redo** on the dict (command stack — cheap once all edits flow
  through one mutation path).
- **Headless CI mode** — `python -m soc_model.configurator check <yaml>`
  running tier 1–3 (completeness rules in CI, not just the browser).

**Later / opt-in:**
- Sim-smoke + FPGA-bitstream pipeline stages (§6.2 stages 6–7) with board
  selection via fpgahub.
- Multi-SoC workspaces; preset *authoring* UI (write new `lib/presets`);
  Pyodide/offline mode (rejected in doc 06 — stays rejected).

---

## 9. Milestones

| M | Effort | Deliverable (each independently shippable) |
|---|---|---|
| **M1** | S | `gui_service.py` core: public `build_from_dict()`, `validate()` (tiers 1+2), `catalogs()`, load/save w/ path guard. Pytest coverage in the existing suite. |
| **M2** | S–M | Completeness rules engine + `nanosoc_completeness.yaml` + checklist API (tier 3). Headless `check` CLI. |
| **M3** | M | FastAPI app + project adapter + endpoints + WS Hub + env-health. No frontend yet (curl-able). |
| **M4** | M | Frontend shell (vendored panel system) + **YAML panel** (textarea + debounced validation gutter) + template gallery. *First end-to-end usable slice.* |
| **M5** | M | **Compose forms** (instances, interconnect targets/initiators, params) + completeness checklist UI. |
| **M6** | M | **Architecture diagram** (demo-style SVG, click-to-edit, badges, drill-down) + memory-map ruler + auto-pack. |
| **M7** | M | **Emit + apply**: export modes, diff-vs-project, apply-to-sys_desc. |
| **M8** | M–L | **Build pipeline**: stages 1–5, WS log streaming, artifacts browser + zip, deep-dive iframe. |
| **M9** | stretch | Firmware stage polish, sim/FPGA stages, register-map + IRQ editors, snapshots/undo. |

MVP = M1–M4 (a validated YAML editor with templates). The user-visible
"configure → diagram → validate → YAML → full build" loop = M1–M8.

## 10. Risks / open questions

1. **Two-repo seam** — service + app in nanosoc_gen, rules + adapter in the
   project. Mitigation: adapter file in the superproject, everything else
   generator-side; the 8 lib-dirs are duplicated between Makefile and adapter
   (single biggest drift risk — consider `make -C sys_desc help` parsing or a
   shared include).
2. **Long stage-3 builds** in a web request lifecycle — solved by the job
   runner + WS, but needs robust cancel (kill process group) and a
   one-job-at-a-time lock shared with CLI users (advisory lockfile in
   `build_soc/`).
3. **Shell-out security** — server binds 127.0.0.1 by default; all paths
   validated against the project root; no arbitrary-command endpoint; the
   make targets come from the adapter file, not the request.
4. **Diagram generality** — the curated layout derives from heuristics
   (module-name classes); odd SoCs degrade to the "other" bin, never break.
   The D3 deep-dive is the always-correct fallback.
5. **Rules engine scope creep** — keep predicates tiny and data-driven;
   anything needing real graph analysis belongs in `SoCValidator` instead.

## 11. Relationship to doc 06

Doc 06's layering (pure `gui_service` + FastAPI router + dict-centric
editing + reuse of `SoCValidator`/`SoCVisualizer` data builders) is adopted
unchanged. Changes: (a) standalone configurator app in nanosoc_gen instead of
a demo-GUI panel (reusability + lifecycle separation); (b) the diagram
follows the demo dashboard's curated-SVG style with generated layout, with
the D3 view demoted to deep-dive; (c) build-flow integration promoted from
M6-stretch to core M8 (its blockers shipped); (d) the new tier-3 completeness
rules engine; (e) doc 06's stale references to doc-05/07 as future work are
superseded by this doc.
