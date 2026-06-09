# 06 — Web-app GUI for interactive `sys_desc` YAML generation

> A browser-based editor that builds and edits the `sys_desc` SoC YAML interactively, with **live validity checking** (address overlaps, missing required fields, port/interface mismatches, illegal combinations) driven by the generator's **own** `SoCValidator` over a thin FastAPI backend — so the GUI can never drift from what `python -m soc_model` accepts.

---

## 1. Title & summary

This document designs a web application that lets an engineer assemble a NanoSoC system description (`sys_desc/*.yaml`) by adding subsystems/regions, editing register maps, and assigning addresses, while a server-side validator highlights errors *as they type*. The validation reuses `nanosoc_gen`'s parser, builder, and validator verbatim, and the import/export format is the same dict tree `SoCBuilder` already consumes (and, once shipped, the **simplified front-end format from `05-simplified-yaml-format.md`**). The canvas reuses the connectivity/address-map graph builders already implemented in `backends/html.py`.

---

## 2. Status & scope

**Status:** Greenfield feature, but it *extends two existing, running codebases* rather than starting from zero:

1. The generator core — `nanosoc_arch_tech/nanosoc_gen/soc_model/` (parser/builder/validator/model + `backends/html.py`).
2. The live FastAPI web app — `python/nanosoc_multicore/demo_gui/` (auto-discovering panel architecture, sim/hw HAL, WebSocket telemetry).

This roadmap deliberately builds the YAML builder as **a new panel + router inside the existing `demo_gui`** rather than a standalone app, because that app already solves: serving, templating (Jinja2), an auto-panel convention (`app.py:42-61`), a no-build-step JS stack (Alpine + vendored libs), and the dev-host/SSH-tunnel deployment story.

**In scope:**
- A read/edit/validate loop over the SoC model: load an existing top YAML, edit it in-browser, get live validation, export a YAML the generator accepts.
- Live validation that calls the *real* `SoCValidator.validate_all()` server-side (no re-implementation in JS).
- UI for the high-value structural edits: add/remove instances (subsystems/regions), edit interconnect targets/initiators (the address map), edit register maps.
- A visual canvas reusing `backends/html.py`'s `_build_*` graph/address builders.
- Round-trip import/export of YAML, including the simplified format from doc 05 when it exists.

**Out of scope (explicitly):**
- Running the full RTL generation pipeline from the GUI (`__main__.py` backends, `BuildBusMatrix.pl`, peakrdl). The GUI *validates and exports*; the user still runs `make -C sys_desc` to render RTL. (A "Generate" button that shells out is a stretch goal in M6, not the core.)
- Editing glue logic / assigns / passthrough heuristics as structured forms — these are expert-level (the `EXCLUDE: [hready]` boundary heuristic, `protocol_utils.py:132`); the GUI exposes them as raw-YAML text fields, not wizards.
- Any change to the RTL the generator emits, or to the validator's *checks* (those evolve under doc 03/04). This GUI is a *consumer* of the validator, designed to track it automatically.
- A WASM/Pyodide offline build (considered and rejected in §9).

---

## 3. Motivation

**The concrete problem.** Today the entire multicore SoC is described in a **single 117 KB hand-edited file**, `sys_desc/nanosoc_multicore_soc.yaml` (1882 lines). Editing it is the documented "how do I customise the address map?" answer (`docs/USER_GUIDE.md:268` points the user at editing this YAML by hand). The failure modes are silent and expensive:

- **Address arithmetic is hand-computed.** `base`/`size`/`offset`/`phys_size` are hand-aligned hex and string expressions; the file itself documents a 4× sizing error class ("The earlier '4 * 2^N' comments were wrong by 4x"). An overlap is only caught at `--validate-only` time, after a full edit.
- **`module` vs `rtl_module` is load-bearing.** A typo in `module: nanosoc_ss_cpu_plus` fails to resolve: `_resolve_instances` calls `parser.parse_module`, gets nothing back, and leaves `inst.resolved_module = None` (`builder.py:383-389`). It does **not** silently fabricate a stub — the empty-stub path (`builder.py:373-380`) is taken only for `rtl_module:` (`is_rtl_module`) instances. The unresolved `module:` typo *is* caught, but only at validate time: `_validate_instance_references` flags `resolved_module is None and not is_rtl_module` as an `error: "Module '…' not found"` (`validator.py:325-334`). So the editor still gets no feedback while typing — the error surfaces only on the next CLI/validate round-trip, which is exactly the gap this GUI closes.
- **Required RTL ports are easy to omit.** A `cmsdk_ahb_to_apb` bridge missing `PCLKEN/PREADY/PSLVERR` elaborates but hangs the bus — caught only by the `_REQUIRED_RTL_PORTS` guard (`validator.py:457`), which the editor never sees until a CLI run.
- **Initiator visibility re-states the whole target table** per initiator (lines ~1665-1773), so a single new region means hand-editing many places.

The validator *already knows* all of these (`SoCValidator.validate_all` runs six checks, `validator.py:32-41`), but the only way to invoke it is a CLI round-trip: edit file → `make -C sys_desc validate` → read terminal → re-edit. There is no feedback while editing.

**Why now.** Two enablers just landed. (a) `demo_gui` proved a working, hardware-free FastAPI web app with an auto-panel pattern (15 panel partials under `templates/panels/_*.html`, with matching auto-included routers) that already *consumes generator output* (`device_model.py` reads `build_soc/discovery/*.yaml`). (b) The roadmap's simplified YAML format (doc 05) and clean-architecture work (doc 02) will make the model far more amenable to round-tripping. A GUI is the natural front door for the simplified format — and the cheapest possible validity gate (pure-Python validate, "seconds") is exactly what a live editor needs.

**What good looks like.** An engineer opens a browser, loads `nanosoc_multicore_soc.yaml` (or starts blank), drags in a region, sees its address window auto-suggested and checked for overlap *live*, edits a register map in a table, and exports a YAML that passes `python -m soc_model … --validate-only` on the first try — because the GUI validated with the identical code path the whole time.

---

## 4. Current state (grounded)

### 4.0 The two directory roots (the biggest integration gotcha)

This feature spans **two separate git repositories**, and conflating them is the single biggest implementation trap. Pin the roots up front:

| Thing | Absolute root | Git unit |
| --- | --- | --- |
| The web app being extended (`demo_gui/`) | `nanosoc-multicore-system/python/nanosoc_multicore/demo_gui/` | **superproject** (top of the multicore system repo) |
| The top YAML being edited | `nanosoc-multicore-system/sys_desc/nanosoc_multicore_soc.yaml` | **superproject** |
| The generator being reused/patched (`soc_model/`, `backends/html.py`) | `nanosoc-multicore-system/nanosoc_arch_tech/nanosoc_gen/` | **submodule** `nanosoc_arch_tech` |
| This roadmap doc | `nanosoc-multicore-system/nanosoc_arch_tech/docs/roadmap/06-web-gui-yaml-builder.md` | **submodule** `nanosoc_arch_tech` |

(`.gitmodules` confirms `nanosoc_arch_tech` — along with `ethernet-subsystem-ahb`, `ahb_qspi`, `inter-processor-communications-ahb`, etc. — is a submodule with its own remote.)

Consequences this design must respect:
- The **one upstream change** (`SoCBuilder.build_from_dict`, §5.3) and the **new `gui_service.py`** land in the *submodule* (`nanosoc_arch_tech`); the **router + panel + nav-title** land in the *superproject* (`python/…/demo_gui/`). That is a two-repo commit and must be sequenced as two MRs (submodule first, then bump the submodule pointer in the superproject).
- The GUI process runs from the superproject but must `import soc_model` from the submodule — hence the importability question (open question #2): a `pip install -e nanosoc_arch_tech/nanosoc_gen` or a `SOCLABS_NANOSOC_GEN_DIR`-on-`sys.path` step is mandatory, not optional.
- The `_safe()` write-guard (§7) keys off `SOCLABS_PROJECT_DIR` (the *superproject* root), because `sys_desc/` lives there — not under the submodule.

### 4.1 The validator is a clean, reusable, pure-Python object

`SoCValidator` takes a built `Module` and returns a flat list of typed messages — no file I/O, no globals:

```python
# nanosoc_gen/soc_model/validator.py:25-49
class SoCValidator:
    def __init__(self, top_module: Module):
        self.top = top_module
        self.messages: List[ValidationMessage] = []

    def validate_all(self) -> List[ValidationMessage]:
        self.messages = []
        self._validate_connections(self.top)
        self._validate_interconnects(self.top)
        self._validate_address_overlaps(self.top)
        self._validate_instance_references(self.top)
        self._validate_known_rtl_modules(self.top)
        self._validate_driver_coverage(self.top)
        return self.messages

    @property
    def errors(self):   return [m for m in self.messages if m.level == 'error']
    @property
    def warnings(self): return [m for m in self.messages if m.level == 'warning']
```

`ValidationMessage` is already a dataclass with exactly the fields a UI needs — `level`, `category`, `instance`, `port`, `message` (`validator.py:11-22`). This is the JSON contract the GUI will surface. **No new validation logic is needed in the GUI**; this is the single most important fact in this design.

The six checks and what each catches (verified in `validator.py`):
- `_validate_connections` (`:51`) → width mismatch (error), bus/wire direction conflict (error/warn); bus members recognised via `protocol_utils.bus_member_names` (`:73`).
- `_validate_interconnects` (`:285`) → initiator references undefined target (error).
- `_validate_address_overlaps` (`:304`) → sorts targets by `base`, adjacent-pair overlap (error). Exact, model-driven.
- `_validate_instance_references` (`:325`) → unresolved `module:` ref (error).
- `_validate_known_rtl_modules` (`:461`) → `_REQUIRED_RTL_PORTS = {'cmsdk_ahb_to_apb': {'PCLKEN','PREADY','PSLVERR'}}` (`:457`).
- `_validate_driver_coverage` (`:336`) → undriven top output (error C1) / unreferenced wire (warn C2).

### 4.2 The parse→build→validate path is short and side-effect-free up to validation

`__main__.py:78-116` shows the exact sequence the GUI will replicate without the backends:

```python
parser  = SoCParser(str(base_dir), [str(d) for d in lib_dirs])     # __main__.py:82
builder = SoCBuilder(parser)
top_module = builder.build_system(yaml_path.name)                  # :86 — raises on bad input
...
validator = SoCValidator(top_module)
messages  = validator.validate_all()                              # :107-108
```

Everything *before* "Build directory structure" (`__main__.py:118`) is pure in-memory work: no files written, no tools shelled out. The GUI's validate endpoint is exactly this prefix. `builder.build_system` raises on a missing top-level `module:` key (`builder.py:26-27`); `parser.parse_module` returns `None` for unresolved refs (`parser.py:65`) which the validator then flags. So feeding the builder a dict the user is mid-editing is safe — worst case is a caught exception or a list of error messages.

**Important constraint:** the parser is *filesystem-driven*. `SoCParser.parse_module` scans `lib_dirs` for any YAML with a `module:` key and caches by `module.name` and filename stem (`parser.py:96-107`). `parse_top_level` reads `base_dir/filename` (`parser.py:50-53`). To validate a YAML the user is editing in-browser (not yet on disk), the GUI must either write a temp file or inject the edited dict directly into the builder — see §5.3.

### 4.3 The web app already exists, with an auto-panel convention

`demo_gui/app.py` discovers panels by globbing `templates/panels/_<id>.html` (`app.py:44`) and auto-includes any `routers/<name>.py` exposing a `router` (`app.py:54-60`). Adding a panel is "drop three files + one nav-title line" (docstring `app.py:4-7`). The index template literally just `{% include %}`s every discovered panel (`templates/index.html:3`). A router is a stock `APIRouter`:

```python
# demo_gui/routers/system.py:8-12,29-32
router = APIRouter(prefix="/api/system", tags=["system"])

@router.get("/device")
def device(request: Request):
    return request.app.state.hal.device.to_dict()
```

The app is launched with `python -m nanosoc_multicore.demo_gui serve --sim` (`demo_gui/__main__.py:17`), needs only `fastapi`/`uvicorn`/`jinja2`/`pyyaml` (`python/setup.py:21-27`), and runs hardware-free. **The builder panel needs no HAL** — it only touches files and the generator — so it works in `--sim` and even standalone.

### 4.4 `backends/html.py` already computes the canvas data

`SoCVisualizer` builds, server-side in pure Python, exactly the graph/address structures a builder canvas needs, each returning JSON-serialisable dicts (`html.py:16-31`):

```python
graph_data       = self._build_graph_data()        # nodes + links for the top module
all_graphs       = self._build_all_graph_data()    # per-subsystem graphs for drill-down
address_map      = self._build_address_map()       # recursive, register-level
initiator_maps   = self._build_initiator_maps()    # per-master visibility windows
interconnect_info= self._build_interconnect_info()
hierarchy_data   = self._build_hierarchy()
```

These methods take a `Module` and emit data; they're reusable as an API layer behind a builder canvas. The remap data is itself data-driven: `_build_initiator_maps` reads `remap.get('remap_bit', 0)` per window (`html.py:552`), and the emitted JS builds a *dynamic* `globalRemapBits` Set from those per-window values (`html.py:1948-1949`, `globalRemapBits.add(w.remap_bit)`) — nothing is hard-coded to a fixed bit count. We reuse the **data builders** not because the JS is wrong about remap, but because the *rendering* in `html.py` is a ~1800-line hand-rolled JS f-string (`_render_html`) that is view-only and has no write-back; a builder needs an editable, two-way component instead.

### 4.5 Gaps that must be filled

- **Nothing reads `sys_desc/*.yaml` for *editing*.** `device_model.py` reads generated `build_soc/discovery/*.yaml` (a consumer). There is no YAML *writer* anywhere except the generator's own `write_if_changed` (`utils.py:156`) and `yaml.dump` inside discovery/build_info backends. The GUI must own load/edit/dump of the *source* YAML.
- **No model→dict serialiser.** The builder goes dict→`Module` one way. To export an *edited* model the GUI needs the round-trip. Cleanest path: **edit the dict, not the `Module`** (the dict is the source of truth the builder already consumes), and only build a `Module` transiently for validation. This sidesteps writing a `Module`→YAML serialiser entirely.
- **No JSON-schema / structural validator.** `validator.py` checks *semantics*; an unknown key is silently `.get()`-ignored by the builder. The GUI should add a thin structural layer (required-field / enum-vocab) on top, but **as a server-side helper, not a JS reimplementation** (§5.4).

---

## 5. Proposed design

### 5.1 Architecture: thin backend + Alpine SPA panel (NOT WASM, NOT static-only)

```
 Browser (Alpine.js SPA, one demo_gui panel)
   │  - dict-tree editor (forms + raw-YAML escape hatch)
   │  - canvas (reuses html.py _build_* JSON)
   │  - validation gutter (live, debounced)
   │
   │  POST /api/builder/validate   {yaml_text | dict}
   │  GET  /api/builder/modules    (palette: discoverable module names)
   │  GET  /api/builder/canvas     (graph/address JSON for current dict)
   │  POST /api/builder/export     {dict} -> canonical YAML text
   │  GET  /api/builder/load?path= (open an existing top YAML)
   ▼
 FastAPI router  demo_gui/routers/builder.py
   │  delegates to a thin, framework-free service:
   ▼
 nanosoc_gen.soc_model.gui_service   (NEW, lives in the generator package)
   - validate(dict, lib_dirs) -> [ValidationMessage as dict]   (reuses SoCBuilder+SoCValidator)
   - canvas(dict, lib_dirs)   -> graph/address JSON            (reuses SoCVisualizer._build_*)
   - palette(lib_dirs)        -> [{name, kind, interfaces,...}] (reuses SoCParser scan)
   - to_yaml(dict)/from_yaml(text)                              (pyyaml, canonical dump)
```

**Why a small backend, not a WASM/Pyodide static SPA.** The validator and builder are the *single source of truth* and they live in Python that imports `pyyaml`, walks the filesystem (`SoCParser._scan_lib_dir`), and may (under doc 02) import `jinja2`/`peakrdl`. Re-running that in the browser via Pyodide means shipping CPython + the package + 8 lib-dir trees as a virtual FS, and re-syncing on every generator change — *exactly the drift this design exists to prevent*. A 4-endpoint FastAPI router that calls `SoCValidator.validate_all()` directly *cannot* drift: it imports the same function the CLI does. The cost is a running Python process, which the project already requires (`demo_gui` is the deploy story).

**Why a panel in `demo_gui`, not a new app.** Reuses serving/templating/panel-discovery/JS-stack/deploy for free (§4.3). The builder is just another `routers/builder.py` + `templates/panels/_builder.html` + `static/js/panels/builder.js`. It is HAL-independent, so it loads in `--sim` with no board.

### 5.2 The editing model: edit the **dict**, build a `Module` only to validate

The crux of avoiding a `Module`→YAML serialiser: the **YAML dict is the document**; the `Module` is a transient validation artifact.

```
 load:    YAML text  --pyyaml-->  dict  ---->  client edits dict (JSON over the wire)
 validate: dict  --SoCBuilder(inject)-->  Module  --SoCValidator-->  messages
 canvas:   dict  --SoCBuilder(inject)-->  Module  --SoCVisualizer._build_*-->  graph JSON
 export:   dict  --yaml.dump(canonical)-->  YAML text  (download / write to sys_desc/)
```

The client holds the parsed dict (a JSON object) in Alpine state and mutates it with form bindings. Every mutation is structural on the dict — `instances[]`, `interconnects[].targets[]`, etc. — i.e. exactly the keys `builder._build_*` reads (enumerated in the yaml-format research §1). On a debounce, it POSTs the dict to `/api/builder/validate`; the server builds a `Module` and runs the validator. **No information is lost** because we never down-convert the dict into a `Module` and back — the dict is preserved verbatim and only *read* for validation.

This is robust to the simplified format (doc 05): if doc 05 adds a builder *pre-pass* that expands sugar (`uses:`, auto-base) into the canonical dict before `_build_module`, the GUI's validate path automatically picks it up (it calls the same `SoCBuilder`). The GUI can offer "expand to canonical" by exposing that pre-pass as a service call (§5.6).

### 5.3 Validating an in-memory (unsaved) dict

`SoCBuilder.build_system(filename)` reads from disk via `parser.parse_top_level` (`builder.py:25`). The unsaved dict needs a way in. Two options; **prefer (B)**:

- **(A) Temp-file shim.** Dump the dict to a temp file in `base_dir`, call `build_system(tmpname)`, delete. Simple, zero generator change, but pollutes `base_dir` and races the parser's directory scan.
- **(B) A tiny generator addition: `SoCBuilder.build_from_dict(data, source_file='<gui>')`.** Factor the two lines after the `parse_top_level` call in `build_system` into a method that takes an already-parsed dict. This is a ~5-line, backward-compatible refactor:

```python
# nanosoc_gen/soc_model/builder.py  (proposed)
def build_system(self, filename: str) -> Module:
    data = self.parser.parse_top_level(filename)
    return self.build_from_dict(data, source_file=filename)

def build_from_dict(self, data: Dict[str, Any], source_file: str = '') -> Module:
    if 'module' not in data:
        raise ValueError("No 'module:' key in system description")
    module = self._build_module(data['module'], source_file)
    self._resolve_instances(module)
    return module
```

Lib-dir module resolution still works because `SoCParser` is constructed with the same `lib_dirs` the CLI uses (the `LIB_DIRS := …` block at `sys_desc/Makefile:61-69` — `$(CURDIR)` plus three `arch_tech/sys_desc{,/regions,/subsystems}` paths, two `ETH_SS/sys_desc{,/regions}` paths, one `ETHMAC_AHB/sys_desc`, and one `AHB_QSPI/sys_desc`: 8 entries total); only the *top* dict is injected. Note those paths are **not** all derivable from one env var — they expand from `SOCLABS_NANOSOC_ARCH_TECH_DIR`, `SOCLABS_ETH_SS_DIR`, `SOCLABS_ETHMAC_AHB_DIR`, and `SOCLABS_AHB_QSPI_DIR` (each defaulting off `SOCLABS_PROJECT_DIR` at `Makefile:27-41`), so the router must source the same four vars, not just `SOCLABS_PROJECT_DIR` (see §7's `_sys_desc_lib_dirs()`). This `build_from_dict` addition is the one and only change the GUI requires inside `nanosoc_gen`, and it's independently useful (e.g. for unit tests — see `01-unit-testing-nanosoc-gen.md`). Mark it as a hard dependency for M2.

### 5.4 Structural (schema) validation layered on top, server-side

The semantic validator does not catch unknown keys or bad enums (a typo'd `directon:` is silently dropped). The GUI adds a *thin* structural pass — but **in Python in the same service**, not in JS, so it lives next to the schema it guards and is testable:

```python
# nanosoc_gen/soc_model/gui_service.py  (NEW, structural helpers)
_IFACE_TYPES = {'wire','ahb','apb','axis','axis_byte','swd','gpio','dbg_ahb'}
_DIR_BY_TYPE = {
    'wire': {'in','out','inout'},
    'ahb':  {'initiator','target'}, 'apb': {'initiator','target'},
    'axis': {'in','out','sender','receiver'}, 'gpio': {'in','out','inout'},
}

def structural_lint(data: dict) -> list[dict]:
    """Cheap pre-build checks: unknown keys, enum vocab, module|rtl_module
    exclusivity, role:'None'-the-string. Returns ValidationMessage-shaped dicts
    so the UI renders them in the same gutter as semantic messages."""
    ...
```

These are the doc-grounded footguns: `module|rtl_module` exclusivity, `direction` vocab per `type`, `role: None` (string) vs `~` (null). Keep this small and additive; the *authoritative* checks remain `SoCValidator`. (If doc 02's clean-architecture work adds a real schema layer, this helper folds into it.)

> **The `_IFACE_TYPES` / `_DIR_BY_TYPE` sets above are illustrative, not authoritative.** An implementer must NOT freeze that enum from this doc. The generator's real interface-type handling lives in `backends/protocol_utils.py:bus_member_names` (`:95`), which treats `axis` and `axis_stream` as **aliases** (`:123`) and expands `ahb` (`:112`), `dbg_ahb` (`:118`), and `axis_byte` (`:125`) into bus members — but has **no `apb` branch** (apb gets no bus-member expansion there). So `structural_lint` should derive its vocabulary from the generator's own type tables (import or mirror `protocol_utils`), not from the hand-written set shown here, or it will reject/accept the wrong types and re-introduce drift. The body is left as `...` deliberately; pin the enum to `protocol_utils` when you implement it.

### 5.5 The UI model

Three coordinated views over the one dict, in a single Alpine panel:

1. **Tree / form editor (left).** A collapsible tree of the dict's structural nodes — `params`, `interfaces`, `instances`, `interconnects`, `firmware`, etc. Each node type gets a focused form:
   - **Add subsystem/region** = append to `instances[]`. The `module:` field is a typeahead populated from `GET /api/builder/modules` (the parser's discovered list, `parser.list_module_files()`); choosing one shows its declared `interfaces:` so `connections:` can be filled. `rtl_module:` toggles inline-interface editing and triggers the `_REQUIRED_RTL_PORTS` check live. *Caveat:* that list contains both the canonical `module.name` and the filename stem for each file (`parser.py:104-107`), so the typeahead can show two entries that resolve to the same file (e.g. a module name and its `.yaml` basename). Either is a legal `module:` value (the parser resolves both), so this is harmless, but the panel should label/group the stem aliases so users aren't confused by apparent duplicates.
   - **Interconnect / address map** = a table of `targets[]` (`name/instance/base/size/sw_access/region_type/protocol`). `base`/`size` editable as hex; an **"auto-pack"** button assigns `base` from `size`+order (the simplification opportunity from doc 05). Overlap is shown inline because the server returns `_validate_address_overlaps` errors keyed by target name.
   - **Initiator visibility** = checkbox matrix initiators × targets (re-using `_build_initiator_maps` data); "all except self" toggle (the file's own stated intent, doc 05 §5e).
   - **Register maps** = a table editor per `register_map` (registers × fields: `name/offset/bits/access/reset_value`), exported as a `register_maps/*.yaml` alongside the top YAML.
   - **Escape hatch:** any node can be edited as raw YAML (CodeMirror-style `<textarea>`), for glue/passthrough/expert fields the forms don't model. Raw edits re-validate like any other.

2. **Canvas (centre).** Renders `GET /api/builder/canvas` graph JSON — nodes (top/subsystem/region/interconnect/port) + typed links — using the *data* from `html.py._build_module_graph`. Drill-down into subsystems via `_build_all_graph_data`. Clicking a node selects it in the tree. (We render with a small Alpine + SVG/Canvas component, not the html.py f-string JS.)

3. **Validation gutter (right/bottom).** A live list of `ValidationMessage`s grouped by level; clicking a message focuses the offending `instance.port` / target in the tree. Re-runs on every debounced edit.

```
 +----------------------+--------------------------------+------------------+
 | TREE / FORMS         |  CANVAS (graph + address map)  | VALIDATION       |
 | ▸ params             |   [eth_ss_0]──ahb──[xbar]      | ✖ address overlap|
 | ▾ instances          |        │                        |   sram_0 ↔ qspi  |
 |   • u_eth_ss_0  ⚙    |   [cpu_ss_1]──┘                 | ⚠ port not found |
 |   • u_cpu_ss_1  ⚙    |   address map bars (per master)|   u_dma.PREADY   |
 | ▾ interconnects      |                                | ✖ module nanosoc_|
 |   • multicore_xbar   |                                |   ss_cpu_pls n/f |
 |     targets[10] ▸    |                                |                  |
 +----------------------+--------------------------------+------------------+
   [Load…] [Import YAML] [Auto-pack addr] [Validate] [Export YAML] [Download]
```

### 5.6 Import/export and the simplified format (doc 05)

- **Import** = `from_yaml(text)` → dict → validate → render. Works for both the current verbose format and (when shipped) doc 05's simplified format, because the *parser* (`yaml.safe_load`) is format-agnostic and the *builder pre-pass* expands sugar.
- **Export** = `yaml.dump(dict, sort_keys=False, default_flow_style=False)` with a canonical key order and a SoC Labs copyright header, written via `write_if_changed` so an unchanged export doesn't churn git. The GUI offers two export modes:
  - **Round-trip (default):** dump the dict as edited (preserves doc 05 sugar the user wrote).
  - **Canonical / expanded:** call the doc-05 pre-pass to expand sugar to the verbose dict, then dump — useful for diffing against the current hand-written file.
- **Write target:** download in the browser, or (when serving on the dev-host with write access) `POST /api/builder/save?path=sys_desc/<file>.yaml` guarded to the `sys_desc/` tree only. Never writes under `/research/AAA/ip_library/**` (user rule) — the save endpoint hard-rejects paths outside the project `sys_desc/`.

### 5.7 Why this can't drift from the generator

Single import line in the router:

```python
from nanosoc_multicore... ──X──   # NO: GUI must not vendor the validator
from soc_model.validator import SoCValidator      # YES: the same object the CLI uses
from soc_model.builder   import SoCBuilder
from soc_model.parser    import SoCParser
from soc_model.backends.html import SoCVisualizer
```

The GUI never reimplements a check. When doc 03/04 add a validator check or doc 05 changes the builder, the GUI's `/validate` and `/canvas` endpoints reflect it on the next request with zero GUI edits. The only GUI-owned validation is the *structural lint* (§5.4), which is small, additive, and explicitly secondary.

---

## 6. Implementation plan (milestones)

Each milestone is independently shippable and reviewable.

### M1 — Headless `gui_service` validate API (no UI)
**Changes:** new `nanosoc_gen/soc_model/gui_service.py` exposing `validate(data: dict, lib_dirs: list[str]) -> list[dict]` that builds a `Module` and runs `SoCValidator`, returning `ValidationMessage`-shaped dicts; plus `from_yaml`/`to_yaml`. Add `SoCBuilder.build_from_dict` (§5.3).
**Why:** the whole feature rests on validating an in-memory dict with the real validator. Prove it with no web layer.
**Acceptance:** a pytest loads `sys_desc/nanosoc_multicore_soc.yaml`, parses to dict, calls `gui_service.validate(dict, LIB_DIRS)`, and gets the **same** error/warning counts as `python -m soc_model … --validate-only`. Mutate the dict to create an address overlap → an `address`/`error` message appears.

### M2 — FastAPI builder router (validate + load + export), no canvas
**Changes:** `demo_gui/routers/builder.py` (`APIRouter(prefix="/api/builder")`) with `POST /validate`, `GET /load?path=`, `POST /export`, `GET /modules`. Add `pyyaml` (already a dep) and ensure `soc_model` is importable from the GUI process (it's on the same machine; add `SOCLABS_NANOSOC_GEN_DIR` to `sys.path` or pip-install `nanosoc-gen`). **The real work in M2 is `_sys_desc_lib_dirs()`** (§7): it must reproduce all 8 `LIB_DIRS` entries from the four `SOCLABS_*` env vars exactly as `sys_desc/Makefile:61-69` does — if it misses a dir, `palette()`/`validate()` see fewer module YAMLs than the CLI and the GUI quietly diverges. Treat this helper as the milestone's hardest, most test-worthy piece, not boilerplate.
**Why:** exposes the service over HTTP so the panel can be pure front-end.
**Acceptance:** `curl -X POST /api/builder/validate -d @soc.json` returns the validation list; `curl /api/builder/load?path=sys_desc/nanosoc_multicore_soc.yaml` returns the dict; `curl /api/builder/modules` returns the discovered module names — and a dedicated assert proves `set(palette(_SYS_DESC, _sys_desc_lib_dirs()))` equals `set(parser.list_module_files())` for a `SoCParser` built with the **same** 8 dirs the CLI/Makefile uses, so a missing lib-dir is caught here rather than as a silent "module not found" later. (Note: `list_module_files()` returns `list(self._module_cache.keys())`, which caches each YAML under **both** its `module.name` and its filename stem — `parser.py:104-107` — so the raw list contains stem aliases; `palette()` de-dups with `set()` but the typeahead will still surface both the module name and the file basename for a given file. Expected, not a bug.)

### M3 — Minimal panel: load, raw-YAML edit, live validate
**Changes:** `demo_gui/templates/panels/_builder.html` + `static/js/panels/builder.js`; add `"builder": "SoC builder"` to `_PANEL_TITLES`/`_PANEL_ORDER` in `app.py`. UI = a big YAML `<textarea>` + "Load" dropdown + a debounced validate that paints the gutter.
**Why:** smallest end-to-end vertical slice — a usable live-validating YAML editor — shippable on its own.
**Acceptance:** in `--sim`, open the panel, load the multicore YAML, edit a `base:` to overlap another, see the overlap error appear within ~500 ms without reloading; fix it, error clears.

### M4 — Structural forms for instances + interconnect targets
**Changes:** Alpine state holds the parsed dict; forms for `instances[]` (add/remove, `module:` typeahead from `/modules`, connection editing) and `interconnects[].targets[]` (table with hex `base`/`size`). Add `structural_lint` to `gui_service` and merge its messages into `/validate` output.
**Why:** turns the raw-text editor into a real builder for the two highest-value structural areas (subsystems/regions and the address map).
**Acceptance:** add a new region instance via the form, fill its module from the typeahead, add a target with auto-suggested base; export YAML; the exported file passes `python -m soc_model … --validate-only`. Omitting a `cmsdk_ahb_to_apb` required port shows the `_REQUIRED_RTL_PORTS` error live.

### M5 — Canvas via `html.py` builders + register-map table editor
**Changes:** `GET /api/builder/canvas` → reuse `SoCVisualizer._build_graph_data`/`_build_address_map`/`_build_initiator_maps` over the built `Module`; render with an Alpine SVG component (node-click → tree-select). Add a register-map table editor writing `register_maps/*.yaml`.
**Why:** visual feedback + the third structural area (register maps).
**Acceptance:** for the multicore top YAML, the canvas's node/link counts match the generator's own discovery artifact, `build_soc/discovery/multicore_ahb_interconnect_discovery.yaml` (the machine-readable, verified ground truth — prefer this over scraping the HTML), and visually match the rendered `build_soc/reports/nanosoc_multicore_soc_connectivity.html` (also present). Both come from the same `SoCVisualizer` data builders the canvas reuses, so equality is the anti-drift check. Editing a register field and exporting then produces a valid `register_map:` YAML that the generator's RDL backend renders without error.

### M6 (stretch) — "Auto-pack addresses" + "Generate RTL" button
**Changes:** an address auto-assign helper (`size`+order → `base`, doc 05 (b)); a `POST /api/builder/generate` that shells `make -C sys_desc` (or `python -m soc_model …`) and streams the log over the existing WebSocket/Hub.
**Why:** closes the loop from edit → RTL without leaving the browser. Kept separate because it shells out and needs the full toolchain/env (`source set_env.sh`), unlike M1-M5.
**Acceptance:** auto-pack produces a non-overlapping map for a hand-built set of sized regions; "Generate" runs the pipeline on the dev-host and surfaces success/failure + log.

---

## 7. File & module changes

### New files

**`nanosoc_arch_tech/nanosoc_gen/soc_model/gui_service.py`** — framework-free service used by the router (and unit tests). No FastAPI import here, so it stays testable in a minimal env (mirrors how `demo_gui/config.py` avoids importing FastAPI).

```python
# nanosoc_gen/soc_model/gui_service.py  (NEW)
"""Headless service for the web YAML builder: validate/canvas/palette/round-trip.

Reuses the generator's OWN parser/builder/validator/visualiser so the GUI can
never drift from `python -m soc_model`. No web-framework import here.
"""
from __future__ import annotations
import yaml
from pathlib import Path
from typing import Any, Dict, List

from .parser import SoCParser
from .builder import SoCBuilder
from .validator import SoCValidator, ValidationMessage
from .backends.html import SoCVisualizer


def _build(data: Dict[str, Any], base_dir: str, lib_dirs: List[str]):
    parser = SoCParser(base_dir, lib_dirs)
    return SoCBuilder(parser).build_from_dict(data, source_file="<gui>")


def validate(data: Dict[str, Any], base_dir: str, lib_dirs: List[str]) -> List[dict]:
    try:
        top = _build(data, base_dir, lib_dirs)
    except Exception as e:                      # bad/partial dict -> one error message
        return [{"level": "error", "category": "build", "instance": "",
                 "port": "", "message": str(e)}]
    msgs = SoCValidator(top).validate_all()
    return [vars(m) for m in msgs] + structural_lint(data)


def canvas(data: Dict[str, Any], base_dir: str, lib_dirs: List[str]) -> dict:
    top = _build(data, base_dir, lib_dirs)
    viz = SoCVisualizer(top)
    return {
        "graph":         viz._build_graph_data(),
        "all_graphs":    viz._build_all_graph_data(),
        "address_map":   viz._build_address_map(),
        "initiator_maps": viz._build_initiator_maps(),
    }


def palette(base_dir: str, lib_dirs: List[str]) -> List[str]:
    # list_module_files() returns list(_module_cache.keys()), which holds BOTH
    # each module's `name` AND its filename stem (parser.py:104-107) -> contains
    # aliases. set() de-dups exact repeats; both name and stem are valid `module:`
    # values, so we keep both for the typeahead (see M2 acceptance / §5.5 caveat).
    return sorted(set(SoCParser(base_dir, lib_dirs).list_module_files()))


def from_yaml(text: str) -> Dict[str, Any]:
    return yaml.safe_load(text) or {}


def to_yaml(data: Dict[str, Any]) -> str:
    return yaml.dump(data, sort_keys=False, default_flow_style=False)


def structural_lint(data: Dict[str, Any]) -> List[dict]:
    ...   # enum vocab, module|rtl_module exclusivity, role:'None' (§5.4)
    return []
```

> NOTE: reusing the `SoCVisualizer._build_*` "private" methods couples the GUI to internal names. Acceptable for M5 because the digest confirms these are stable, pure data builders; if doc 02 refactors them, promote the needed ones to public methods then (one-line rename in this service).

**`python/nanosoc_multicore/demo_gui/routers/builder.py`** — the HTTP surface.

```python
# demo_gui/routers/builder.py  (NEW)
"""Web YAML builder: validate/load/export the sys_desc system description.

Delegates entirely to soc_model.gui_service so validation == `python -m soc_model`.
HAL-independent: works in --sim with no board.
"""
from __future__ import annotations
import os
from pathlib import Path
from fastapi import APIRouter, Body, HTTPException, Query

from soc_model import gui_service   # the generator's own service

router = APIRouter(prefix="/api/builder", tags=["builder"])

_PROJ = Path(os.environ["SOCLABS_PROJECT_DIR"])          # superproject root
_SYS_DESC = _PROJ / "sys_desc"


def _sys_desc_lib_dirs() -> list[Path]:
    """The same 8 lib-dirs the CLI uses — a 1:1 port of `LIB_DIRS` in
    sys_desc/Makefile:61-69. These expand from FOUR env vars (each defaulting
    off SOCLABS_PROJECT_DIR, mirroring Makefile:27-41), NOT one — getting this
    list right (so palette()/validate() see every module YAML the CLI sees) is
    the load-bearing part of M2.
    """
    arch = Path(os.environ.get("SOCLABS_NANOSOC_ARCH_TECH_DIR", _PROJ / "nanosoc_arch_tech"))
    eth  = Path(os.environ.get("SOCLABS_ETH_SS_DIR",            _PROJ / "ethernet-subsystem-ahb"))
    mac  = Path(os.environ.get("SOCLABS_ETHMAC_AHB_DIR",        eth  / "ethernet-mac-ahb"))
    qspi = Path(os.environ.get("SOCLABS_AHB_QSPI_DIR",          _PROJ / "ahb_qspi"))
    return [
        _SYS_DESC,                                  # $(CURDIR)
        arch / "sys_desc", arch / "sys_desc/regions", arch / "sys_desc/subsystems",
        eth  / "sys_desc", eth  / "sys_desc/regions",
        mac  / "sys_desc",
        qspi / "sys_desc",
    ]


_LIB_DIRS = [str(p) for p in _sys_desc_lib_dirs()]

@router.post("/validate")
def validate(payload: dict = Body(...)):
    return {"messages": gui_service.validate(payload["data"], str(_SYS_DESC), _LIB_DIRS)}

@router.get("/load")
def load(path: str = Query(...)):
    p = _safe(path)
    return {"data": gui_service.from_yaml(p.read_text())}

@router.post("/export")
def export(payload: dict = Body(...)):
    return {"yaml": gui_service.to_yaml(payload["data"])}

@router.get("/modules")
def modules():
    return {"modules": gui_service.palette(str(_SYS_DESC), _LIB_DIRS)}

@router.get("/canvas")
def canvas(path: str = Query(None)):
    data = gui_service.from_yaml(_safe(path).read_text())
    return gui_service.canvas(data, str(_SYS_DESC), _LIB_DIRS)

def _safe(path: str) -> Path:
    p = (_PROJ / path).resolve()                    # _PROJ = superproject root
    if _SYS_DESC.resolve() not in p.parents and p != _SYS_DESC.resolve():
        raise HTTPException(400, f"path outside sys_desc/: {path}")
    return p
```

**`python/nanosoc_multicore/demo_gui/templates/panels/_builder.html`** — panel partial (auto-discovered by `app.py:44`):

```html
<!-- demo_gui/templates/panels/_builder.html -->
<section id="builder" x-data="builderPanel()" x-init="boot()" class="panel">
  <header class="panel-head">
    <h2>SoC builder</h2>
    <select x-model="path" @change="load()"><!-- discovered top YAMLs --></select>
    <button @click="validate()">Validate</button>
    <button @click="exportYaml()">Export YAML</button>
  </header>
  <div class="builder-grid">
    <div class="tree"><!-- forms / raw-YAML escape hatch (M3 = textarea) --></div>
    <div class="canvas"><svg x-ref="cv"></svg></div>
    <ul class="gutter">
      <template x-for="m in messages">
        <li :class="m.level"><span x-text="m.level"></span>
            <span x-text="m.instance + '.' + m.port"></span>
            <span x-text="m.message"></span></li>
      </template>
    </ul>
  </div>
</section>
```

**`python/nanosoc_multicore/demo_gui/static/js/panels/builder.js`** — Alpine component: holds the dict, debounced `validate()` POST, `exportYaml()` download, canvas render. Vendored Alpine only, no build step (matches `demo_gui/README.md:16`).

**`nanosoc_gen/soc_model/tests/test_gui_service.py`** — pytest for M1 (the project currently has no `nanosoc_gen/tests/`; this introduces it, dovetailing with `01-unit-testing-nanosoc-gen.md`).

### Modified files

- **`nanosoc_gen/soc_model/builder.py`** — add `build_from_dict(data, source_file)`; have `build_system` call it (§5.3). Backward compatible.
- **`python/nanosoc_multicore/demo_gui/app.py`** — add `"builder": "SoC builder"` to `_PANEL_TITLES` (`app.py:32-37`) and to `_PANEL_ORDER` (`app.py:38-39`). The router auto-includes via `_include_routers` (`app.py:54-60`) with no edit.
- **`python/setup.py`** — add `nanosoc-gen` (or a path/PYTHONPATH note) to the `demo_gui` extra so `from soc_model import gui_service` resolves; the generator currently installs separately (`nanosoc_gen/pyproject.toml`). Simplest: document `pip install -e nanosoc_arch_tech/nanosoc_gen` alongside `pip install -e "python[demo_gui]"`.
- **`python/nanosoc_multicore/demo_gui/README.md`** — document the builder panel + the `soc_model` import requirement.

---

## 8. Testing & validation

**M1 (the linchpin) — equivalence test.** Prove the service agrees with the CLI:

```python
# nanosoc_gen/soc_model/tests/test_gui_service.py
def test_validate_matches_cli(soc_yaml, lib_dirs):
    data = gui_service.from_yaml(Path(soc_yaml).read_text())
    msgs = gui_service.validate(data, str(Path(soc_yaml).parent), lib_dirs)
    errs = [m for m in msgs if m["level"] == "error"]
    # same as: python -m soc_model nanosoc_multicore_soc.yaml --validate-only
    assert len(errs) == EXPECTED_ERRORS   # captured from a known-good CLI run
```

This is the anti-drift guarantee, runnable in CI's cheap "validate" tier (the tier-1 "parse + validate, seconds, pure Python" of `03-ci-system-validity-matrix.md`). Add a deliberately-broken fixture (overlapping `base:`) asserting the overlap error fires — proving the service surfaces `_validate_address_overlaps`.

**M2 — endpoint tests** with FastAPI's `TestClient`: `POST /validate` round-trips a dict; `GET /modules` count equals `parser.list_module_files()`; `_safe()` rejects a `../` path.

**M3-M5 — the `verify` skill / manual + a Playwright-style smoke** (optional): start `demo_gui serve --sim`, load the multicore YAML, assert the gutter shows zero errors; introduce an overlap via the textarea, assert an error appears. M5 canvas: assert node/link counts equal those in the generated `build_soc/discovery/multicore_ahb_interconnect_discovery.yaml` for the same input (machine-readable ground truth; the `build_soc/reports/nanosoc_multicore_soc_connectivity.html` render is the human cross-check).

**CI hook.** The M1/M2 pytests slot into the generator's unit-test suite (see `01-unit-testing-nanosoc-gen.md` and `03-ci-system-validity-matrix.md`, plus the `.gitlab-ci.yml` `soc_gen` + a new `gen_pytest` job). They are pure-Python and fast — no EDA tools — so they run on any runner, unlike the cocotb/UVM tiers. M6's "Generate" needs the full `set_env.sh` toolchain and is *not* a CI gate; it's an interactive convenience.

**Cross-check with `--validate-only`.** Every exported YAML in M4/M5 acceptance is fed back through `python -m soc_model … --validate-only` — the definitive proof that the GUI's output is generator-clean.

---

## 9. Risks, tradeoffs, alternatives considered

- **Coupling to `SoCVisualizer._build_*` private methods (M5).** If doc 02 refactors `html.py`, the canvas breaks. *Mitigation:* the dependency is data-only and confined to `gui_service.canvas()`; promote the methods to public when doc 02 lands (a rename). Until M5 we don't touch them.
- **Editing the dict, not the `Module`, means no semantic *typing* while editing.** The dict can hold arbitrary keys; only on validate do we learn they're wrong. *Mitigation:* `structural_lint` (§5.4) gives fast enum/required-field feedback before the full build; this is a deliberate trade for avoiding a `Module`→YAML serialiser that would be a second source of truth (and a drift vector).
- **Running CPython in the loop (vs WASM static SPA).** Needs a server process. *Rejected WASM/Pyodide* because it would have to vendor the generator + 8 lib-dir trees into a browser FS and re-sync on every generator change — the exact drift this design eliminates. The project already mandates a Python deploy (`demo_gui`), so the marginal cost is ~one router.
- **`SoCParser` is filesystem-driven; the in-browser dict isn't on disk.** Solved by `build_from_dict` (§5.3) injecting only the top dict while lib-dir *module* resolution stays on disk. Sub-modules being edited in-browser but not saved won't resolve — *acceptable*: the GUI edits the *top* system; sub-module edits save to their own files first (consistent with how the generator resolves modules by file).
- **Save-to-disk is dangerous near the read-only IP trees.** *Mitigation:* `_safe()` hard-restricts writes to `sys_desc/`; never writes under `/research/AAA/ip_library/**` (user rule). Default UX is browser download, not server write.
- **The simplified format (doc 05) may not exist yet.** *Mitigation:* the design works on the *current* verbose format from day one (M1-M5 use it); doc 05 is an enhancement (round-trip sugar + auto-pack), not a prerequisite. If doc 05's pre-pass lands, the GUI picks it up for free via the shared `SoCBuilder`.
- **`build_from_dict` is a generator change.** Small (~5 lines), backward-compatible, and independently useful (unit tests). The only required upstream edit; everything else is additive in `demo_gui`.

---

## 10. Dependencies & sequencing

**Builds on / unblocked by:**
- **`05-simplified-yaml-format.md`** — the GUI is the natural authoring surface for the simplified format; its builder pre-pass (sugar→canonical) is what the GUI's "expand to canonical" export and `auto-pack` lean on. The GUI works without it but is much nicer with it. *This doc consumes 05.*
- **`02-clean-architecture-adapters-backends.md`** — if the validator/backends get a base-class/registry and public data-builders, the GUI's `gui_service` gets cleaner (public `canvas` builders, a real schema layer to fold `structural_lint` into). *This doc benefits from 02 but doesn't require it.*
- **`01-unit-testing-nanosoc-gen.md`** — M1/M2 pytests are the first `nanosoc_gen/tests/`; they slot directly into the unit-test suite that doc defines.
- **`03-ci-system-validity-matrix.md`** — the M1/M2 pytests ride the "parse + validate, seconds, pure Python" tier-1 of the CI validity matrix that doc describes, so they run on any runner with no EDA tools.

**Unblocks:**
- A non-expert path to author new SoC variants (regions/subsystems/address maps) without hand-editing a 117 KB file — the headline UX win for the whole generator.

**Sequencing:** M1 → M2 → M3 are a strict chain (service → API → minimal panel) and together are the MVP. M4 and M5 are parallelizable after M3. M6 is optional and last (needs full toolchain env).

**Effort estimate:**
- M1: **S** (one new module + a 5-line builder refactor + one test).
- M2: **S** (a stock `APIRouter`, four thin endpoints).
- M3: **M** (first real Alpine panel; debounce + gutter; mostly front-end).
- M4: **M** (structural forms + typeahead + structural_lint).
- M5: **M-L** (canvas rendering component + register-map table editor).
- M6: **M** (auto-pack helper is S; "Generate" shell-out + log streaming is M).
- **Overall: M (MVP = M1-M3), L (full M1-M5).**

---

### Open questions (could not resolve from the code)

1. **Sub-module editing scope.** The parser resolves modules by file on disk (`parser.py:96-107`); the GUI as designed edits the *top* system dict in memory. Whether users will expect to edit a region/subsystem YAML *and* see it reflected in the top canvas before saving is a UX decision not answerable from the code — current design requires saving the sub-module file first. Flagged for M4/M5 UX review.
2. **`soc_model` importability from the `demo_gui` process.** The generator (`nanosoc-gen`) and the GUI (`nanosoc_multicore`) are separate packages with separate `pyproject.toml`/`setup.py`; nothing in the tree installs both together. The design assumes a `pip install -e nanosoc_gen` alongside the GUI or a `PYTHONPATH`/`SOCLABS_NANOSOC_GEN_DIR` addition. The exact packaging choice (vendor vs path-dep vs namespace package) is a project-policy call.
3. **Doc 05 pre-pass shape.** Whether doc 05 implements sugar expansion as a `SoCBuilder` pre-pass (which the GUI would call) or as a separate preprocessing tool affects the "expand to canonical" export path (§5.6). Designed to work either way, but the cleanest integration assumes a builder pre-pass.
4. **Concurrent edits / multi-user.** `demo_gui` is single-session by design (one HAL, one board). The builder panel is stateless server-side (state lives in the browser dict), so multi-tab is fine, but there is no locking against two people editing the same `sys_desc/` file and both saving. Out of scope unless the project needs it.
