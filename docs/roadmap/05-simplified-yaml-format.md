# 05 — Simplified, More Readable YAML Format

> Make `sys_desc` YAML easier and safer to author by adding a thin, **opt-in preprocessing layer** in front of the existing `SoCBuilder`: presets/mixins for repeated blocks, address auto-assignment, terse bus wiring, derived sizes, and a JSON Schema for editor validation — all expanding to the exact dict shapes `builder._build_*` already consumes, so no backend changes are required.

---

## 1. Title & summary

This document specifies an incremental redesign of the human-authored YAML for the
nanosoc_gen SoC generator. The goal is to cut the volume and footgun density of the
hand-written description (a single `nanosoc_multicore_soc.yaml` is ~1880 lines; region
files are near-identical clones; the same ~13 Cortex-M0 params are copied through 3–4
levels by hand) **without changing the object model, the validator, or any backend**.

The mechanism is a **YAML sugar layer** (`expand`) that runs between `SoCParser`
(load + discovery) and `SoCBuilder` (dict → object model). Sugar is desugared into the
canonical dict the builder already reads. Every feature is independently shippable and
strictly opt-in: existing YAML continues to parse byte-for-byte unchanged.

---

## 2. Status & scope

**Status:** greenfield feature, but it *extends* an existing, stable parse→build
pipeline. No feature here is required to author a SoC today; each is a convenience that
desugars to current syntax.

**In scope**

- A preprocessing pass that expands sugar into canonical builder-input dicts.
- Six concrete sugar features (presets/`uses:`, address auto-assignment, terse bus
  wiring `bus:`, derived `phys_size` from `srams`, initiator visibility "all-except",
  param-group inheritance).
- A JSON Schema describing the **canonical** dict shape (for editor validation and a
  fail-fast unknown-key check), plus an optional schema for the sugar layer.
- A `--expand-only` / `--dump-expanded` CLI mode that prints the desugared YAML so the
  expansion is auditable and diffable against the hand-written form.
- BEFORE/AFTER conversions of real region and top-level files.

**Out of scope**

- Changing `model.py` dataclasses, `validator.py` checks, or any `backends/*` emitter.
  (Some features *enable* better validation — e.g. a schema — but the existing semantic
  validator is untouched.)
- Replacing the hard-coded protocol signal tables in
  `backends/protocol_utils.py:15-92` with the `lib/interfaces/*.yaml` files. That is a
  separate, larger change owned by the clean-architecture doc
  (see `02-clean-architecture-adapters-backends.md`); this doc only *reuses*
  `protocol_utils.bus_member_names()` for the terse-bus feature.
- The web GUI itself. This doc produces the schema + round-trippable format the GUI
  builds on (see `06-web-gui-yaml-builder.md` / whichever doc owns the GUI).
- Auto-deriving topology (number of cores/subsystems). Topology stays instance-listed;
  presets reduce per-instance boilerplate but do not invent instances.

---

## 3. Motivation

The single source of truth for a NanoSoC is hand-written YAML, and today that YAML is
verbose, repetitive, and silently forgiving of mistakes. Concrete pain, all verified in
the current tree:

1. **Region files are clones.** `sys_desc/regions/sram/nanosoc_region_sram.yaml` and
   `sys_desc/regions/imem/nanosoc_region_imem.yaml` are structurally identical: same
   `SYS_ADDR_W/SYS_DATA_W/RAM_ADDR_W/RAM_DATA_W` param block, same `HCLK/HRESETn`
   wires, same `ahb_slave` target with `EXCLUDE: [hburst, hmastlock]`, same single
   `srams` entry. imem only adds `MEM_FPGA_IMG`. (Read both files: they differ only in
   `desc` text and that one param.)

2. **Hand-aligned addresses.** The top-level target table (parent repo,
   `nanosoc-multicore-system/sys_desc/nanosoc_multicore_soc.yaml:1641-1651`) assigns
   `base:` by hand (`0x20000000`, `0x21000000`, `0x22000000`, …) with a 16-line ASCII
   comment block above it (`:1624-1639`) kept in sync by hand. The file itself documents a
   *4× sizing bug class*: the params block warns "The earlier '4 * 2^N' comments were
   wrong by 4x" (`:127`).

3. **`phys_size` is a hand-written string expression.** e.g.
   `phys_size: "2 ** $QSPI_FLASH_ADDR_W"` (parent
   `nanosoc_multicore_soc.yaml:1646`) at the top level, and the legacy `4 * 2^N` form in
   the submodule (`nanosoc_arch_tech/sys_desc/subsystems/cpu/nanosoc_ss_cpu.yaml:191-193`).
   The information needed to compute it usually already exists in the target's `srams`
   entry (`addr_width`) — but the byte-vs-word convention split (see §4.3) means there is
   no single formula.

4. **Buses spelled out signal-by-signal.** The Cortex-M0 debug-AHB slave bus is listed
   as 8 individual connections per core
   (`sys_desc/subsystems/cpu/nanosoc_ss_cpu.yaml:137-144`) and again as 8
   `internal_wires` ×2 cores at the top level. `protocol_utils.bus_member_names()`
   already knows the exact fan-out.

5. **Initiator visibility re-states the target table.** Each initiator re-lists target
   names already in `targets[]` (parent `nanosoc_multicore_soc.yaml`, initiators block
   `:1667-1773`); the file's own comments describe the intent as "all minus self" for the
   CPU initiators (`nanosoc_ss_cpu.yaml` `cpu_ss` initiator comments).

6. **No schema, no fail-fast.** `builder.py` uses `.get(key, default)` for every field
   (e.g. `_build_module` `builder.py:36-160`). A typo'd key (`interfces:`) is silently
   dropped. A mistyped non-RTL `module:` name is worse: in `_resolve_instances`
   (`builder.py:368-391`) `parse_module` returns `None`, the
   `if mod_data and 'module' in mod_data` guard (`builder.py:384`) is False, and
   `inst.resolved_module` is simply left **unset** (`None`) — no stub is built, no error
   is raised. (The empty-stub path at `builder.py:373-380` runs *only* for
   `is_rtl_module` instances.) Either way errors surface late, downstream, as missing
   ports or DECERRs.

**Why now.** The model is stable and the backends are mature, so a front-end sugar layer
is low-risk: it cannot regress RTL because it produces the same dicts. It also unblocks
the web YAML builder, which needs a schema and a round-trippable canonical form.

**What good looks like.** A new region is ~3 lines (`uses: [ahb_target_region]` + a
size). A peripheral added to the matrix needs no hand-picked `base:`. A wrong key fails
in <1 s with a precise message. The hand-written form and the expanded form are
diffable, so reviewers can see exactly what sugar produced.

---

## 4. Current state (grounded)

### 4.0 Repo boundary — this work spans TWO repos (read first)

This doc lives in `nanosoc_arch_tech/`, which is a **git submodule** of the
`nanosoc-multicore-system` superproject (`nanosoc_arch_tech/.git` →
`gitdir: ../.git/modules/nanosoc_arch_tech`). The artifacts this feature touches are
split across that boundary, and the split sets the per-milestone edit/commit/review
scope. Knowing it is mandatory: an engineer working *inside* `nanosoc_arch_tech/` will
not find `nanosoc_multicore_soc.yaml` or a `sys_desc/Makefile` there.

| Lives in **submodule** `nanosoc_arch_tech/` | Lives in **parent** `nanosoc-multicore-system/` |
|---|---|
| `nanosoc_gen/` (parser, builder, model, backends, utils) | `sys_desc/nanosoc_multicore_soc.yaml` (top SoC, **1882 lines**) |
| `nanosoc_gen/lib/interfaces/` (+ the new `lib/presets/`, `schema/`, `tests/`) | All top-level peripheral YAMLs (`dma_230_ahb.yaml`, `qspi_flash_ahb.yaml`, `cc_periph_subsystem.yaml`, `cpu1_remap_ctrl.yaml`, `evt_route_ctrl.yaml`, `ipc_mbx_ahb.yaml`) |
| `sys_desc/regions/` (sram/imem/dmem region template YAMLs) | `sys_desc/Makefile` (the `soc` build entry) |
| `sys_desc/subsystems/` (cpu/eth subsystem template YAMLs) | The interconnect `targets[]`/`initiators[]` tables (inside the top YAML) |
| `sys_desc/register_maps/` | `build_soc/` (generated RTL output — the diff gate) |

**Consequence for the milestones (§6):** every change to the **engine and presets**
(`expand.py`, `parser.py`, `__main__.py`, `lib/presets/`, `schema/`, `tests/`) is a
**submodule** edit. Every **content conversion** of a top-level or peripheral YAML
(`auto_base`, `phys_size: {auto,kind}`, initiator `all/except`, the DBGAHB `bus:` bundles
in the *top* file) is a **parent-repo** edit. Conversions of the **region/subsystem** template
YAMLs (the `uses:` proof in M2, the DBGAHB `bus:` in `nanosoc_ss_cpu.yaml`) are
**submodule** edits. A milestone that touches both (e.g. M4 converts both
`nanosoc_ss_cpu.yaml` *and* the top file) lands as two commits — submodule first, then a
superproject commit that bumps the submodule pointer.

**The build/test entry point is the parent root, not this repo.** There is no
`sys_desc/Makefile` inside `nanosoc_arch_tech/`. The regeneration command is `make soc`
from the **parent** root, which is `$(MAKE) -C sys_desc` against the **parent's**
`sys_desc/Makefile` (parent `Makefile:31-32`). The acceptance harness in §8 uses this
entry, not a bare `make -C sys_desc` from the submodule.

### 4.1 The pipeline and where sugar fits

`soc_model/__main__.py:82-89` is the only place the parser feeds the builder:

```python
parser = SoCParser(str(base_dir), [str(d) for d in lib_dirs] if lib_dirs else None)
builder = SoCBuilder(parser)
top_module = builder.build_system(yaml_path.name)
```

`SoCBuilder.build_system` (`builder.py:23-34`) calls `self.parser.parse_top_level(filename)`
to get a raw dict, asserts a top-level `module:` key, then `_build_module` walks the dict
with `.get()` calls. Submodules are resolved in `_resolve_instances` (`builder.py:368-391`)
via `self.parser.parse_module(inst.module_name)`, which returns another raw dict from the
discovery cache.

**Critical insight for parser-compatibility:** the builder *only* reads dicts. So a sugar
layer that rewrites a dict before `_build_module` sees it is fully compatible. There are
exactly two dict sources to intercept:

- `SoCParser.parse_top_level` (`parser.py:50-53`) — the top SoC dict.
- `SoCParser.parse_module` (`parser.py:55-65`) — each submodule dict (from the cache
  populated by `_scan_lib_dir`, `parser.py:67-107`).

Both call `self._load_yaml` (`parser.py:170-181`), which is plain `yaml.safe_load` — no
custom tags, no `!include` constructor (confirmed: the `!include` shown in
`lib/interfaces/ahb_slave.yaml:14` header comments is **never implemented**, and
`parser.parse_interface_definition` `parser.py:141-161` has zero call sites).

### 4.2 The canonical keys the builder consumes (the desugar target)

From `builder.py`, the module dict keys actually read:

| Key | Builder site | Shape |
|---|---|---|
| `name`, `gen`, `desc` | `:38,45,46` | scalars |
| `params` | `:51-60` | `{NAME: {type,default,desc}}` **or** `{NAME: scalar}` (both accepted) |
| `clocks`, `resets` | `:63-77` | lists of dicts |
| `interfaces` | `:80-81` → `_build_interface` `:162-170` | `[{name,type,direction,params,desc}]` |
| `instances` | `:84-85` → `_build_instance` `:172-198` | `module`/`rtl_module`, `connections`, `params`, `condition` |
| `internal_wires` | `:100-107` | `[{name,type,params:{WIDTH},desc}]` |
| `glue_logic` | `:110-132` | typed entries |
| `interconnects` | `:135-136` → `_build_interconnect` `:200-255` | `targets[]`, `initiators[]`, `connections[]` |
| `address_decode` | `:139-140` | nested slot decode |
| `firmware`, `build_info`, `srams` | `:143-157` | as documented |

Interconnect targets (`_build_interconnect` `:218-234`) read
`name, instance, base, size, phys_size, sw_access, region_type, role, subordinate_bus,
protocol, apb_config, passthrough, desc`. Initiators (`:236-253`) read
`name, instance, passthrough, targets[]`, where each target is a bare string or
`{name, visibility}`.

### 4.3 Sizing math the model already knows — and the byte-vs-word conflict

`model.py:330-345` `ResolvedSram` already computes:

```python
@property
def depth(self) -> int:        return 2 ** self.addr_width        # model.py:338
@property
def size_bytes(self) -> int:   return self.depth * (self.data_width // 8)   # model.py:343
```

and `SramEntry.addr_width` (`model.py:316-327`) may be a `$PARAM` string resolved via
`utils.resolve_param_ref`. **But two incompatible sizing conventions actually coexist in
the tree, and the `phys_size` feature (§5.5) must not paper over the difference:**

- **Word-width (model.py).** `SramEntry.addr_width` is documented as a *word* address
  width (`model.py:324`: `# word address width`), so `size_bytes = 2**addr_width *
  (data_width//8)`. For `addr_width=14, data_width=32` that is `16384 * 4 = 64 KB`.
- **Byte-width (top-level SoC YAML).** `sys_desc/nanosoc_multicore_soc.yaml:122-129`
  states **`RAM_ADDR_W` is a BYTE-address width: physical size = 2^N bytes**, and
  explicitly calls the old `4 * 2^N` form *"wrong by 4x (they assumed N was a word-address
  width)"*. For `RAM_ADDR_W=14` that is `2^14 = 16 KB`.
- **The legacy `4 * 2^N` form is still live in the submodule.** The region/subsystem
  template YAMLs still carry the old convention: `nanosoc_ss_cpu.yaml:191-193` uses
  `phys_size: "4 * (2 ** $BOOTROM_ADDR_W)"` and `nanosoc_region_sram.yaml:25` documents
  `RAM_ADDR_W` as `phys = 4 * 2^N bytes`.

These three disagree by a factor of 4. The §5.5 feature therefore cannot apply a single
`2**N * (data_width/8)` formula blindly — see §5.5 for the per-target rule that respects
whichever convention the *named param* already implies.

### 4.4 Param resolution available to a pre-pass

`utils.resolve_param_ref(value, params)` (`utils.py:8-38`) resolves `"$FOO"` and
expressions like `"2 ** $N"` against a flat `{name: value}` params dict (guarded
`_safe_eval`, `utils.py:41-46`). `utils.flatten_params` (`utils.py:122-130`) converts the
`{NAME: {default: …}}` form into `{NAME: value}`. A sugar pre-pass can reuse both to
evaluate sizes/addresses at expansion time, or leave them as strings for the builder.

### 4.5 What is missing

- No schema. No structural validation; only the semantic `SoCValidator`
  (`validator.py:32-41`) runs, after build, on the object model.
- No inheritance/templating. No `uses:`/`inherit:` is read anywhere
  (`grep -n "uses\|inherit\|extends\|template" builder.py parser.py` → nothing).
- No address auto-assignment, no terse-bus, no derived `phys_size`.
- No expander module, no `nanosoc_gen/lib/presets/`, no `nanosoc_gen/schema/`, and no
  `nanosoc_gen/tests/` dir (all confirmed absent). `nanosoc_gen/lib/` itself exists but
  holds only `interfaces/`.

---

## 5. Proposed design

### 5.1 Architecture: one expansion pass, two interception points

Introduce a new module `soc_model/expand.py` exposing a single pure function:

```python
def expand_module_dict(raw: dict, *, presets: "PresetLibrary",
                       params_ctx: dict | None = None) -> dict:
    """Desugar a raw module dict into the canonical shape SoCBuilder reads.

    Idempotent: expand(expand(x)) == expand(x). Pure: no I/O, no mutation of
    `raw` (returns a deep-copied, rewritten dict).
    """
```

`SoCParser` gains an optional `expander` callback that it applies to every dict it
returns from `parse_top_level` and `parse_module`. Default `expander=None` → today's
behaviour exactly.

```
            sys_desc/*.yaml
                  │  yaml.safe_load           (parser.py:170)
                  ▼
        ┌──────────────────────┐
        │ raw dict (may have    │
        │  sugar: uses:, bus:,  │
        │  auto-base, ...)      │
        └──────────┬───────────┘
                   │  expand_module_dict()    ◀── NEW (expand.py), opt-in
                   ▼
        ┌──────────────────────┐
        │ canonical dict        │  ── byte-identical in shape to today's hand YAML
        └──────────┬───────────┘
                   │  _build_module()         (builder.py:36, UNCHANGED)
                   ▼
              Module object  ──▶ validator ──▶ backends (ALL UNCHANGED)
```

Why a separate pass rather than teaching the builder new keys: it keeps the builder a
"dumb container" filler (its design today), keeps every backend ignorant of sugar, and
makes the expansion **auditable** — `--dump-expanded` prints the canonical YAML so a
reviewer diffs sugar vs. golden. It also means the schema can validate the *canonical*
output (a stable, fully-enumerated shape) independently of evolving sugar.

Presets are loaded from a new bundled dir `nanosoc_gen/lib/presets/*.yaml` plus any
user `--preset-dir`, discovered like modules. A `PresetLibrary` is just a name→dict map.

### 5.2 Feature 1 — Presets / `uses:` (mixins for repeated blocks)

A preset is a partial module dict. `uses: [name, ...]` deep-merges each named preset
**under** the module's own keys (module keys win on conflict), in list order.

Preset `nanosoc_gen/lib/presets/ahb_target_region.yaml`:

```yaml
preset:
  name: ahb_target_region
  params:
    SYS_ADDR_W: { type: int, default: 32, desc: "System address width" }
    SYS_DATA_W: { type: int, default: 32, desc: "System data width" }
    RAM_ADDR_W: { type: int, default: 14, desc: "RAM address width (phys = 2^N bytes)" }
    RAM_DATA_W: { type: int, default: 32, desc: "RAM data width" }
  interfaces:
    - { name: HCLK,    type: wire, direction: in, params: { WIDTH: 1 }, desc: AHB clock }
    - { name: HRESETn, type: wire, direction: in, params: { WIDTH: 1 }, desc: AHB reset (active low) }
    - { name: ahb_slave, type: ahb, direction: target,
        params: { ADDR_WIDTH: $SYS_ADDR_W, DATA_WIDTH: $SYS_DATA_W, EXCLUDE: [hburst, hmastlock] },
        desc: AHB slave port }
```

**BEFORE** (`sys_desc/regions/sram/nanosoc_region_sram.yaml`, 38 lines):

```yaml
module:
  name: nanosoc_region_sram
  gen: False
  params:
    SYS_ADDR_W: { type: int, default: 32, desc: "System address width" }
    SYS_DATA_W: { type: int, default: 32, desc: "System data width" }
    RAM_ADDR_W: { type: int, default: 14, desc: "RAM address width (phys = 4 * 2^N bytes)" }
    RAM_DATA_W: { type: int, default: 32, desc: "RAM data width" }
  interfaces:
    - { name: HCLK,    type: wire, direction: in, params: { WIDTH: 1 }, desc: AHB clock }
    - { name: HRESETn, type: wire, direction: in, params: { WIDTH: 1 }, desc: AHB reset (active low) }
    - { name: ahb_slave, type: ahb, direction: target,
        params: { ADDR_WIDTH: $SYS_ADDR_W, DATA_WIDTH: $SYS_DATA_W, EXCLUDE: [hburst, hmastlock] },
        desc: AHB slave port for SRAM access }
  srams:
    - { name: u_sram, addr_width: $RAM_ADDR_W, data_width: $RAM_DATA_W, desc: "General-purpose SRAM" }
```

**AFTER**:

```yaml
module:
  name: nanosoc_region_sram
  gen: False
  uses: [ahb_target_region]
  srams:
    - { name: u_sram, addr_width: $RAM_ADDR_W, data_width: $RAM_DATA_W, desc: "General-purpose SRAM" }
```

Merge rule (deterministic, easy to reason about):

- **dicts** (`params`, an interface's `params`): recursive merge, module value wins.
- **lists** (`interfaces`, `instances`, `srams`): preset items first, then module items;
  an interface/instance/sram whose `name`/`instance_name` matches one from a preset
  **replaces** the preset's (so a module can override one inherited interface without
  re-listing all). This is the only "smart" list merge and is keyed strictly on the
  identity field.
- **scalars** (`gen`, `desc`): module wins.

> Decision: presets do **not** support recursive `uses:` in v1 (a preset cannot use
> another preset). Keeps the merge a single, non-cyclic pass. Revisit only if needed.

### 5.3 Feature 2 — Address auto-assignment

Add an optional `auto_base:` flag and per-target `size:` (no `base:`) to an interconnect.
The expander packs *unpinned* targets into an alignment-respecting map and writes back
concrete `base:` values, leaving any target that *does* specify `base:` pinned (mixed
mode). It must handle the real map's two non-uniform features: a target larger than the
default stride (`qspi_flash_xip` is **64M**, not 16M), and a **reserved gap** between the
packed band and the next pinned window.

The real top-level interconnect (parent
`nanosoc_multicore_soc.yaml:1641-1651`) is a **13-entry** table, not a uniform run:

```
name              base          size     pin?   notes
eth_ss_slave      0x00000000    512M     pin    subordinate_bus admin window
dma_230_0         0x20000000     16M     auto   ┐
qspi_flash_0      0x21000000     16M     auto   │ dense 16M-aligned peripheral band
phc_0             0x22000000     16M     auto   │
ipc_mailbox_0     0x23000000     16M     auto   ┘
qspi_flash_xip    0x24000000     64M     auto   <- 64M, spans 0x24..0x27, eats the gap
(reserved gap)    0x25..0x27FFFFFF        —      consumed by the 64M xip aperture
cc_periph_0       0x28000000     16M     auto   ┐ band resumes at 0x28M after the 64M hole
cpu1_remap_0      0x29000000     16M     auto   │
reset_ctrl_0      0x2A000000     16M     auto   │
evt_route_0       0x2B000000     16M     auto   ┘
cpu_ss_1_slave    0x80000000    512M     pin    subordinate_bus admin window
```

So the "gap" 0x25M..0x27M is *not* free space the packer must reserve separately — it is
swallowed by the 64M `qspi_flash_xip` window. The packer simply rounds the running cursor
up to `align` and advances by each target's (rounded) `size`, so a 64M target naturally
consumes four 16M slots and the next auto target lands at 0x28M. The only requirement is
that auto-packed `size` values round to `align` and that the cursor never overruns a
pinned window (checked at expansion).

**BEFORE** (parent `nanosoc_multicore_soc.yaml:1642-1650`, abridged to the auto band):

```yaml
targets:
  - { name: dma_230_0,      instance: u_dma_230_apb_bridge, base: 0x20000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "DMA-230 APB cfg" }
  - { name: qspi_flash_0,   instance: u_qspi_apb_bridge,    base: 0x21000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "QSPI ctrl APB cfg" }
  - { name: phc_0,          instance: u_phc_0,              base: 0x22000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "PTP Hardware Clock" }
  - { name: ipc_mailbox_0,  instance: u_ipc_mailbox_0,      base: 0x23000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "IPC mailbox" }
  - { name: qspi_flash_xip, instance: u_qspi_flash_0,       base: 0x24000000, size: 0x04000000, phys_size: "2 ** $QSPI_FLASH_ADDR_W", sw_access: rx, region_type: memory, role: None, desc: "QSPI XiP" }
  - { name: cc_periph_0,    instance: u_cc_periph_0,        base: 0x28000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "CPU1 CMSDK periph" }
  - { name: cpu1_remap_0,   instance: u_cpu1_remap_0,       base: 0x29000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "CPU1 remap ctrl" }
  - { name: reset_ctrl_0,   instance: u_reset_ctrl_0,       base: 0x2A000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "Reset controller" }
  - { name: evt_route_0,    instance: u_evt_route_0,        base: 0x2B000000, size: 0x01000000, sw_access: rw, region_type: periph, role: None, desc: "Event routing" }
```

**AFTER**:

```yaml
auto_base: { from: 0x20000000, align: 16M }   # pack the dense periph band from 0x20M, 16M-aligned
targets:
  # eth_ss_slave / cpu_ss_1_slave keep explicit base (subordinate_bus) and are skipped by the packer
  - { name: dma_230_0,      instance: u_dma_230_apb_bridge, size: 16M, sw_access: rw, region_type: periph, desc: "DMA-230 APB cfg" }
  - { name: qspi_flash_0,   instance: u_qspi_apb_bridge,    size: 16M, sw_access: rw, region_type: periph, desc: "QSPI ctrl APB cfg" }
  - { name: phc_0,          instance: u_phc_0,              size: 16M, sw_access: rw, region_type: periph, desc: "PTP Hardware Clock" }
  - { name: ipc_mailbox_0,  instance: u_ipc_mailbox_0,      size: 16M, sw_access: rw, region_type: periph, desc: "IPC mailbox" }
  - { name: qspi_flash_xip, instance: u_qspi_flash_0,       size: 64M, phys_size: { auto: $QSPI_FLASH_ADDR_W, kind: byte }, sw_access: rx, region_type: memory, desc: "QSPI XiP" }  # 64M -> lands 0x24M, next auto = 0x28M; phys_size form per §5.5
  - { name: cc_periph_0,    instance: u_cc_periph_0,        size: 16M, sw_access: rw, region_type: periph, desc: "CPU1 CMSDK periph" }
  - { name: cpu1_remap_0,   instance: u_cpu1_remap_0,       size: 16M, sw_access: rw, region_type: periph, desc: "CPU1 remap ctrl" }
  - { name: reset_ctrl_0,   instance: u_reset_ctrl_0,       size: 16M, sw_access: rw, region_type: periph, desc: "Reset controller" }
  - { name: evt_route_0,    instance: u_evt_route_0,        size: 16M, sw_access: rw, region_type: periph, desc: "Event routing" }
```

Size shorthand: the expander accepts `16M`/`64K`/`512M`/`4G` (and plain ints / hex) and
writes back the integer `size:`. Auto-packed `base:` values are computed in YAML order,
each rounded up to `align`, advancing the cursor by the (align-rounded) `size`. Overlap
with pinned windows is detected at expansion time and errors out (this complements
`_validate_address_overlaps`, `validator.py`, which runs after build as a backstop).

> Decision: keep `auto_base` opt-in per-interconnect rather than global. The DAP windows
> (`0xA0000000/0xB0000000`) and the two `subordinate_bus` admin windows (`eth_ss_slave`
> @0x00000000, `cpu_ss_1_slave` @0x80000000) are deliberately placed and stay pinned;
> auto-packing only the dense `0x20M..0x2BM` peripheral band matches how the file is
> actually authored.

### 5.4 Feature 3 — Terse bus wiring (`bus:`)

A single connection with `bus: <protocol>` expands to the per-member connections using
`protocol_utils.bus_member_names()` — the *same* fan-out the toplevel/subsystem backends
emit, so names cannot drift.

**BEFORE** (`nanosoc_ss_cpu.yaml:137-144`):

```yaml
connections:
  - { port: DBGAHB_SLVADDR,  conn: cpu_0_dbgahb_slvaddr }
  - { port: DBGAHB_SLVWDATA, conn: cpu_0_dbgahb_slvwdata }
  - { port: DBGAHB_SLVTRANS, conn: cpu_0_dbgahb_slvtrans }
  - { port: DBGAHB_SLVWRITE, conn: cpu_0_dbgahb_slvwrite }
  - { port: DBGAHB_SLVSIZE,  conn: cpu_0_dbgahb_slvsize }
  - { port: DBGAHB_SLVRDATA, conn: cpu_0_dbgahb_slvrdata }
  - { port: DBGAHB_SLVREADY, conn: cpu_0_dbgahb_slvready }
  - { port: DBGAHB_SLVRESP,  conn: cpu_0_dbgahb_slvresp }
```

**AFTER**:

```yaml
connections:
  - { bus: dbg_ahb, port: DBGAHB_SLV, conn: cpu_0_dbgahb, desc: "Debug AHB-AP slave bus" }
```

Expansion uses the suffix list for `dbg_ahb`
(`DBGAHB_TARGET_SIGNALS`, `protocol_utils.py:76-85`): for each `(suffix, _, _)` it emits
`{port: <PORT_PREFIX><suffix.upper()>, conn: <conn>_<suffix>}`. So `port: DBGAHB_SLV` +
`bus: dbg_ahb` → `DBGAHB_SLVADDR ← cpu_0_dbgahb_slvaddr`, etc. The same applies to the
8-signal `internal_wires` bundles for these buses, which can be declared as one entry:

```yaml
internal_wires:
  - { bus: dbg_ahb, name: cpu_0_dbgahb, desc: "CPU0 debug-AHB slave bus" }
```

> Decision: the per-signal *widths* for the internal_wires expansion come from the
> protocol signal table (e.g. `slvaddr` width `32`). The expander emits each wire as the
> canonical `{name, type: wire, params: {WIDTH: <n>}}` so the builder/validator see plain
> wires exactly as today. This intentionally does **not** require the larger
> "data-driven protocol from lib/interfaces" change owned by doc 02 — it reuses the
> already-shared Python table.

### 5.5 Feature 4 — Derived `phys_size` (weakest feature — read the caveat)

> **Caveat up front.** This is the least clean of the six features and the least
> incremental. The §4.3 byte-vs-word conflict means there is *no single formula* that is
> correct across the tree, and the cross-module form would break the "pure pre-pass"
> architecture. v1 is therefore deliberately narrow (a per-target **string rewrite from a
> named param**, never a numeric formula) and could reasonably be **deferred or dropped
> from v1** if the conversion count (Open Question 1) turns out to be tiny.

Goal: let a target opt into a `phys_size: {auto: $P, kind: ...}` annotation instead of
hand-writing the size-expression string, **without committing to a numeric size** at
expansion time — because the right multiplier depends on which convention the named param
follows:

- a *word*-address param needs `phys = 2^N * (data_width/8)` (model.py convention),
- a *byte*-address param needs `phys = 2^N` (top-level SoC YAML convention),
- the legacy submodule form is `phys = 4 * 2^N` (`nanosoc_ss_cpu.yaml:191-193`).

Because the multiplier is ambiguous, v1 does **not** evaluate a number. Instead the target
declares the *param* and the convention, and the expander emits the exact string the
builder already accepts — byte-identical to what is hand-written today:

```yaml
# v1 form: name the param and its convention; the expander writes the canonical string.
phys_size: { auto: $QSPI_FLASH_ADDR_W, kind: byte }   # -> "2 ** $QSPI_FLASH_ADDR_W"
phys_size: { auto: $BOOTROM_ADDR_W,    kind: word }   # -> "4 * (2 ** $BOOTROM_ADDR_W)"
```

**BEFORE** (parent `nanosoc_multicore_soc.yaml:1646`):

```yaml
- { name: qspi_flash_xip, instance: u_qspi_flash_0, base: 0x24000000, size: 0x04000000,
    phys_size: "2 ** $QSPI_FLASH_ADDR_W", sw_access: rx, region_type: memory, role: None }
```

**AFTER**:

```yaml
- { name: qspi_flash_xip, instance: u_qspi_flash_0, base: 0x24000000, size: 64M,
    phys_size: { auto: $QSPI_FLASH_ADDR_W, kind: byte }, sw_access: rx, region_type: memory }
```

The expander rewrites `phys_size: {auto: $P, kind: byte|word}` to the canonical string
(`"2 ** $P"` or `"4 * (2 ** $P)"`) and leaves the rest to the builder/`resolve_param_ref`.
This is a pure string rewrite from a *named* param: no cross-module resolution, no
dependence on whether the child module's `srams` is resolved yet, and no risk of the
4×-wrong size the §4.3 conflict would otherwise produce. The bare `phys_size: auto`
(no param) is **not** supported in v1, precisely because the convention cannot be inferred.

Deferred (out of v1): a builder *post-pass* that reads `inst.resolved_module.srams`
directly and computes the number from `ResolvedSram.size_bytes`. That removes the `kind:`
annotation but contradicts the pure-pre-pass design and pulls in the same byte-vs-word
question one level deeper — defer unless the string-rewrite form proves insufficient.

### 5.6 Feature 5 — Initiator visibility "all-except"

Add `targets: all` + optional `except: [...]` to an initiator. The expander materialises
the full target-name list (from the interconnect's `targets[]`) minus the exceptions,
emitting the canonical per-name list the builder reads.

**BEFORE** (parent `nanosoc_multicore_soc.yaml`, `cpu_ss_1_m` initiator `:1685-1697`):

```yaml
- name: cpu_ss_1_m
  instance: u_cpu_ss_1
  targets:
    - name: eth_ss_slave
    - name: dma_230_0
    - name: qspi_flash_0
    - name: phc_0
    - name: ipc_mailbox_0
    - name: qspi_flash_xip
    - name: cc_periph_0
    - name: cpu1_remap_0
    - name: reset_ctrl_0
    - name: evt_route_0
```

**AFTER**:

```yaml
- name: cpu_ss_1_m
  instance: u_cpu_ss_1
  targets: all
  except: [cpu_ss_1_slave]   # the only target this interconnect lists that CPU1 is not granted (its own admin window)
```

`targets: all` materialises from this interconnect's own `targets[]` — the 11 names
`eth_ss_slave, dma_230_0, qspi_flash_0, phc_0, ipc_mailbox_0, qspi_flash_xip, cc_periph_0,
cpu1_remap_0, reset_ctrl_0, evt_route_0, cpu_ss_1_slave` — minus the `except` list. For
`cpu_ss_1_m` the single exception `cpu_ss_1_slave` yields exactly the hand-written 10
above. (There are no separate `cpu_0_dbg_window`/`cpu_1_dbg_window` targets in this
interconnect; the DAP debug routing lives on a different initiator path.)

Per-target `visibility:`/`remap:` overrides (e.g. `nanosoc_ss_cpu.yaml:198-244`) are
*not* sugar — they stay as explicit dicts. The expander only handles the bare-name list
case; any initiator target that needs a `visibility` block is written long-form, and
`targets: all` can be combined with an explicit `overrides:` list that replaces specific
materialised entries. (v1: `all` produces bare names only; mixing with `visibility`
overrides is a documented v2 extension.)

### 5.7 Feature 6 — Param-group inheritance for passthrough chains

The ~13 Cortex-M0 params (`CLKGATE_PRESENT…ROMTABLE_BASE`, parent
`nanosoc_multicore_soc.yaml:167-179`) are declared at the top level and re-declared in the
submodule's `nanosoc_ss_cpu.yaml`, `nanosoc_ss_cpu_plus.yaml`, and the core YAMLs. A
`params_from: [cortex_m0_core]` group (a preset that contributes only `params`) lets each
level pull the group instead of re-typing it:

```yaml
params_from: [cortex_m0_core]   # supplies CLKGATE_PRESENT..ROMTABLE_BASE with defaults
```

This is a thin specialisation of Feature 1 (`uses:` that merges only the `params` key).
It does **not** auto-wire the instance `params: { PORT: $TOP }` passthrough — that is
connectivity, left explicit. (A later sugar `params_passthrough: cortex_m0_core` could
emit the `{NAME: $NAME}` mirror, but that is out of v1 scope to avoid surprising
auto-wiring.)

### 5.8 JSON Schema for editor validation

Ship `nanosoc_gen/schema/module.schema.json` describing the **canonical** module dict
(post-expansion): enumerated keys, `additionalProperties: false` at each level,
`module|rtl_module` exclusivity on instances, `direction` enum gated per interface
`type`, `bits` as string, and forbidding `role: "None"` (the string) vs `~` (null).

Two consumers:

1. **Editor (web GUI / VS Code):** point at the schema for autocomplete + red squiggles
   on unknown keys.
2. **Fail-fast CLI check:** a new `--schema-check` flag validates each loaded+expanded
   dict against the schema *before* build, turning today's silent `.get()`-drops into
   explicit errors. Uses the `jsonschema` package (added as an optional dep, guarded like
   jinja2 is in the backends).

A second, looser `module.sugar.schema.json` describes the sugar layer (`uses`,
`auto_base`, `bus`, `targets: all`, size shorthand) for editor support on hand-written
files.

---

## 6. Implementation plan

Each milestone is independently shippable: it adds opt-in sugar, leaves all existing YAML
working, and is acceptance-checked by re-rendering `build_soc/` and diffing.

**Per-milestone repo scope (see §4.0).** Every milestone splits across the submodule
boundary, and the split sets the commit/review unit. As a rule:

- **Engine + presets + schema + tests** (`expand.py`, `parser.py`, `__main__.py`,
  `lib/presets/`, `schema/`, `tests/`) → **submodule** `nanosoc_arch_tech` commit.
- **Region/subsystem template conversions** (`sys_desc/regions/*`,
  `sys_desc/subsystems/*`) → **submodule** commit.
- **Top-level / peripheral YAML conversions** (`sys_desc/nanosoc_multicore_soc.yaml`,
  `sys_desc/*_ahb.yaml`, …) → **parent** `nanosoc-multicore-system` commit.
- A milestone that edits both repos lands as **two commits**: the submodule first, then a
  superproject commit that bumps the submodule pointer. The byte-identical `build_soc/`
  diff gate is run from the **parent root** (`make soc`) after both are in place.

Per-milestone repo column below: **(sub)** = submodule, **(par)** = parent.

### M1 — Expander scaffold + `--dump-expanded` (no sugar yet) — **(sub)** only

- New `soc_model/expand.py` with `expand_module_dict(raw, presets, params_ctx)` that is
  initially the identity (returns a deep copy unchanged) plus the `PresetLibrary` loader.
- Wire an optional `expander` callback into `SoCParser.parse_top_level`/`parse_module`
  (default off). Add `--expand/--dump-expanded` to `__main__.py`.
- **Why:** lands the seam and the audit tool with zero behaviour change.
- **Acceptance:** with `--expand` on, `make soc` from the **parent root** produces a
  byte-identical `build_soc/` (compare `git status` / `diff -r` of `build_soc/` before/
  after). With `--dump-expanded`, the printed canonical YAML round-trips to the same
  `Module` (`SoCBuilder` on dumped YAML → same `*_model.py` report).

### M2 — Presets / `uses:` (Feature 1) + `params_from:` (Feature 6) — **(sub)** only

- Implement deep-merge in `expand.py`; ship `lib/presets/ahb_target_region.yaml` and
  `lib/presets/cortex_m0_core.yaml`.
- Convert `sys_desc/regions/sram` and `sys_desc/regions/imem` (submodule) to `uses:` as
  the proof.
- **Why:** kills the biggest, safest clone duplication first.
- **Acceptance:** `build_soc/` byte-identical before/after the region conversions
  (the desugared dict equals the old hand dict). `--dump-expanded` of the sram region
  reproduces the original 38-line form. **Note the `4 * 2^N` vs `2^N` convention:** the
  `ahb_target_region` preset's `RAM_ADDR_W` desc must match whichever the converted region
  uses (`nanosoc_region_sram.yaml:25` currently says `phys = 4 * 2^N bytes`) or the
  desugared `params` desc string will diff.

### M3 — Size shorthand + address auto-assignment (Feature 2) — **(sub)** engine + **(par)** YAML

- Parse `16M`/`64K`/etc.; implement the packer with pinned-window exclusion, larger-than-
  stride targets (e.g. 64M xip), and overlap detection. *(engine = submodule)*
- Convert the dense `0x20M..0x2BM` peripheral band in the **parent**
  `sys_desc/nanosoc_multicore_soc.yaml` to `auto_base`. *(content = parent)*
- **Why:** removes the hand-aligned base table and the 4×-bug class.
- **Acceptance:** packed `base:` values match the current hand-assigned ones exactly
  (`build_soc/reports/*_memory_map.txt` unchanged), **including the 64M xip landing at
  0x24M and the band resuming at 0x28M**; a deliberately overlapping pin fails expansion
  with a clear message. Run `make soc` from the parent root after both commits.

### M4 — Terse bus wiring (Feature 3) — **(sub)** engine + region; **(par)** top file

- Implement `bus:` expansion for `connections` and `internal_wires` reusing
  `protocol_utils.bus_member_names()` + the signal tables for widths. *(engine = submodule)*
- Convert the DBGAHB connection bundles in the submodule's
  `sys_desc/subsystems/cpu/nanosoc_ss_cpu.yaml:137-144` **and** the 16 `internal_wires` at
  the parent top level (`nanosoc_multicore_soc.yaml:1246-1263`). *(two repos)*
- **Why:** removes the ~5× hand-listed 8-signal buses.
- **Acceptance:** expanded connections/wires equal the long-form; `build_soc/` and the
  validator output unchanged.

### M5 — `phys_size: {auto,kind}` (Feature 4) + initiator `all/except` (Feature 5) — **(par)** content, **(sub)** engine

- Engine: rewrite `phys_size: {auto: $P, kind: byte|word}` to the canonical string;
  materialise `targets: all` minus `except`. *(submodule)*
- Content: convert the `qspi_flash_xip` `phys_size` and the `cpu_ss_1_m`/peer initiators in
  the parent top file. *(parent)*
- **Why:** removes remaining string-expr `phys_size` and the initiator re-lists.
- **Acceptance:** `build_soc/` byte-identical for the converted targets/initiators. (Feature
  4 is the weakest — see §5.5; verify Open Question 1 before committing the conversions.)

### M6 — JSON Schema + `--schema-check` — **(sub)** only

- Author `schema/module.schema.json` (canonical) and `schema/module.sugar.schema.json`.
- Add `--schema-check` (optional `jsonschema` dep, guarded import — the same try/except
  pattern as jinja2 in `backends/soc_config_pkg.py:19-23`).
- **Why:** turns silent typos into fail-fast errors; feeds the editor/GUI.
- **Acceptance:** a fixture with a typo'd key (`interfces:`) fails `--schema-check`
  with the key path; all real `sys_desc` files (both repos) pass; `--validate-only`
  semantics unchanged.

---

## 7. File & module changes

### New files

```
nanosoc_gen/soc_model/expand.py                      # the sugar/desugar pass
nanosoc_gen/lib/presets/ahb_target_region.yaml       # Feature 1 preset
nanosoc_gen/lib/presets/cortex_m0_core.yaml          # Feature 6 param group
nanosoc_gen/schema/module.schema.json                # canonical dict schema (M6)
nanosoc_gen/schema/module.sugar.schema.json          # sugar-layer schema (M6)
nanosoc_gen/tests/test_expand.py                     # unit tests (see §8)
```

### Modified files

- `nanosoc_gen/soc_model/parser.py` — add `expander` param to `__init__`; apply it in
  `parse_top_level` and at the end of `_scan_lib_dir` caching (so cached module dicts are
  expanded once). Minimal diff, ~10 lines:

```python
class SoCParser:
    def __init__(self, base_dir, lib_dir=None, expander=None):
        ...
        self._expander = expander          # callable(raw_dict) -> dict, or None

    def parse_top_level(self, filename):
        data = self._load_yaml(self.base_dir / filename)
        return self._expander(data) if self._expander else data
    # in _scan_lib_dir, expand `data` before caching by name/stem
```

- `nanosoc_gen/soc_model/__main__.py` — build a `PresetLibrary` from
  `lib/presets/` + `--preset-dir`; construct the expander; pass it to `SoCParser`. Add
  `--expand`, `--dump-expanded`, `--preset-dir`, `--schema-check`. ~25 lines, mirrors the
  existing arg/flow style at `:45-61` and `:82-83`.

- `nanosoc_gen/pyproject.toml` / `soc_model/requirements.txt` — add optional
  `jsonschema` (M6 only), guarded import in `expand.py` exactly like the jinja2 try/except
  in `nanosoc_gen/soc_model/backends/soc_config_pkg.py:19-23` (and `chip.py`, `ahb.py`,
  `docs.py`, etc.).

> All of the above are **submodule** (`nanosoc_arch_tech`) edits.

**Parent-repo (`nanosoc-multicore-system`) content edits — different commit/review unit:**

- `nanosoc_arch_tech/sys_desc/regions/sram/nanosoc_region_sram.yaml`,
  `…/regions/imem/nanosoc_region_imem.yaml` — these region templates live in the
  **submodule** at `nanosoc_arch_tech/sys_desc/regions/` (NOT under `nanosoc_gen/`);
  convert to `uses:` (M2). *(submodule edit)*

- `nanosoc_arch_tech/sys_desc/subsystems/cpu/nanosoc_ss_cpu.yaml` — convert the per-core
  DBGAHB connection bundle (`:137-144`) to `bus:` (M4). *(submodule edit)*

**Parent-repo (`nanosoc-multicore-system`) content edits — different commit/review unit:**

- `sys_desc/nanosoc_multicore_soc.yaml` — the **top SoC file lives in the parent repo**,
  not the submodule. Convert peripheral targets to `auto_base` (M3), the top-level DBGAHB
  `internal_wires` (`:1246-1263`) to `bus:` (M4), `phys_size: {auto,kind}` + initiator
  `all/except` (M5). These are *content* edits in the **parent**, applied per-milestone,
  each guarded by a byte-identical `build_soc/` check run via `make soc` from the parent
  root.

### Core expander signature & merge helper (illustrative)

```python
# soc_model/expand.py
from copy import deepcopy

_SIZE_SUFFIX = {'K': 1 << 10, 'M': 1 << 20, 'G': 1 << 30}

def parse_size(v):
    if isinstance(v, int):
        return v
    s = str(v).strip()
    if s[-1].upper() in _SIZE_SUFFIX:
        return int(s[:-1], 0) * _SIZE_SUFFIX[s[-1].upper()]
    return int(s, 0)

def _merge(into: dict, frm: dict, list_key_field: dict) -> dict:
    """Deep-merge `frm` UNDER `into` (into wins). list_key_field maps
    list-valued keys to their identity field (e.g. 'interfaces'->'name')."""
    out = deepcopy(frm)
    for k, v in into.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _merge(v, out[k], list_key_field)
        elif k in out and isinstance(out[k], list) and isinstance(v, list) and k in list_key_field:
            idf = list_key_field[k]
            base = {item.get(idf): item for item in out[k] if isinstance(item, dict)}
            merged = []
            seen = set()
            for item in out[k]:                       # preset items first
                name = item.get(idf) if isinstance(item, dict) else None
                ov = next((x for x in v if isinstance(x, dict) and x.get(idf) == name), None)
                merged.append(ov if ov else item)
                if name: seen.add(name)
            for item in v:                            # module-only items appended
                if not isinstance(item, dict) or item.get(idf) not in seen:
                    merged.append(item)
            out[k] = merged
        else:
            out[k] = v
    return out

_LIST_KEYS = {'interfaces': 'name', 'instances': 'instance_name',
              'srams': 'name', 'clocks': 'name', 'resets': 'name'}

def expand_module_dict(raw, presets, params_ctx=None):
    mod = deepcopy(raw.get('module', raw))
    for pname in mod.pop('uses', []):
        mod = _merge(mod, presets.params_and_all(pname), _LIST_KEYS)
    for pname in mod.pop('params_from', []):
        mod.setdefault('params', {})
        mod['params'] = {**presets.params_only(pname), **mod['params']}
    _expand_interconnects(mod, params_ctx)     # auto_base, phys_size:{auto,kind}, all/except
    _expand_buses(mod)                          # bus: -> per-member conns/wires
    return {'module': mod} if 'module' in raw else mod
```

`_expand_buses` uses `protocol_utils.bus_member_names()` and the signal tables; the
exact suffix-uppercasing for port names mirrors the existing `cpu_0_dbgahb_*` naming in
`nanosoc_ss_cpu.yaml:137-144`.

---

## 8. Testing & validation

A `nanosoc_gen/tests/` dir does not exist yet (confirmed); M1 creates the first one. Use
pytest.

**Where the regeneration / acceptance command lives (important).** There is **no**
`make -C sys_desc` target inside `nanosoc_arch_tech` — `sys_desc/Makefile` lives in the
**parent** repo. The canonical regen entry is `make soc` from the **parent root**
(`nanosoc-multicore-system/Makefile:31-32`), which runs `$(MAKE) -C sys_desc` against the
parent's `sys_desc/Makefile`. The CI `soc_gen` stage does exactly this:
`cd "$WORK_DIR" && source set_env.sh && make -C sys_desc clean && make -C sys_desc` (from
the parent root). All `make soc` commands below are run from the parent root with
`set_env.sh` sourced.

**On CI wiring (do not over-claim).** There is currently **no pytest / generator-unit-test
job in `.gitlab-ci.yml`** — `soc_gen` only regenerates RTL, and the existing
`python/tests/` suite (parent repo) is the **demo-GUI** test suite (`test_dashboard.py`,
`test_ethernet.py`, `test_ipc.py`, …), not generator tests, and is not wired into CI. So
`tests/test_expand.py` is a **new** test surface; adding a pytest job to run it is itself a
CI change owned by the unit-testing/CI roadmap doc (see below), not an existing hook this
doc can lean on.

**Unit tests (`tests/test_expand.py`):**

- `expand(no_sugar) == no_sugar` (identity for current files) — load every real
  `sys_desc` module file from **both** the submodule (`nanosoc_arch_tech/sys_desc/regions`,
  `…/subsystems`, `…/register_maps`) and the parent
  (`nanosoc-multicore-system/sys_desc/*.yaml`), and assert expansion is a no-op when no
  sugar keys are present.
- `uses:` merge: a fixture with `uses: [ahb_target_region]` expands to a dict equal to
  the hand-written long form (golden-dict comparison).
- Override semantics: a module that re-declares one inherited interface gets the override,
  keeps the rest.
- `auto_base`: packs to expected bases; overlap with a pinned window raises.
- size shorthand: `16M == 0x01000000`, `512M`, `64K`, hex passthrough.
- `bus:` expansion: `{bus: dbg_ahb, port: DBGAHB_SLV, conn: cpu_0_dbgahb}` →
  the exact 8 connections, matching `bus_member_names`.
- `targets: all` + `except`: materialised list equals `targets[] - except`.
- idempotency: `expand(expand(x)) == expand(x)`.

**End-to-end golden check (the load-bearing one):** the strongest proof is that the
*generated RTL does not change*. Run from the **parent root** for each conversion
milestone:

```
# baseline (parent root, set_env.sh sourced)
make soc && cp -r build_soc /tmp/build_soc.gold
# apply the milestone's sugar conversion (submodule and/or parent), then:
make soc
diff -r /tmp/build_soc.gold build_soc      # see caveat below on what counts as "empty"
```

**Caveat — what the diff gate actually tolerates.** `utils.write_if_changed`
(`utils.py:156-168`) compares via `_strip_timestamps` (`utils.py:148-153`), but that
regex (`_TIMESTAMP_LINE_RE`, `utils.py:137-145`) strips **only** two line shapes:
`// | * | #  Generated: <YYYY-MM-DD HH:MM:SS>` and `// Copyright <YYYY>,…`. It does
**not** strip anything else. `write_if_changed` only governs whether a file is *rewritten*;
a fresh `diff -r` against `/tmp/build_soc.gold` compares the **raw** files and will flag a
`Generated:` line that differs by timestamp. So the gate is "empty diff" **only after**
applying the same strip to both trees, e.g.:

```
diff -r /tmp/build_soc.gold build_soc \
  -I '^\(//\|\*\|#\)[[:space:]]*Generated:' -I '^//[[:space:]]*Copyright [0-9]\{4\},'
```

Before relying on the gate, confirm no backend emits any *other* run-varying content (host
name, abs path, PID, dict-iteration order). If any does, extend the `-I` ignore set (or
`_strip_timestamps`) to cover it — an unstripped volatile line would otherwise produce a
false-positive diff and mask real equivalence.

**Interaction with the testing/CI docs:**

- The `--validate-only` cheap gate (`__main__.py:115-116`) is unchanged and still the
  fastest per-config signal; `--schema-check` is an *additional*, even-cheaper structural
  gate that runs before build. The unit-testing/CI roadmap doc
  (`01-unit-testing-nanosoc-gen.md` / `03-ci-system-validity-matrix.md`) is the right place
  to **introduce a generator pytest job** (none exists today) running
  `tests/test_expand.py`, and to add `--schema-check` to the `soc_gen` stage — both are new
  CI surface, not pre-existing hooks.
- The config-sweep tooling (CI doc) can sweep `--config-override` exactly as today;
  expansion runs before override application and has no effect on it (overrides flow only
  into `SoCConfigPkgBackend`, `__main__.py:64-71`).

---

## 9. Risks, tradeoffs, alternatives considered

**Risk: expansion changes generated RTL subtly.** Mitigated by the byte-identical
`diff -r build_soc` gate on every conversion and by keeping expansion a pure pre-pass that
emits canonical dicts. If a diff appears, the conversion (not the engine) is wrong.

**Risk: `--dump-expanded` and the real expansion drift.** They share one code path
(`expand_module_dict`); the dumper just YAML-serialises its output. No second
implementation.

**Risk: merge semantics surprise.** Deep-merge with module-wins + identity-keyed list
replacement is the only non-obvious rule. Documented, unit-tested, and made auditable via
`--dump-expanded`. Recursive presets are deliberately excluded in v1.

**Risk: `phys_size` derivation is ambiguous (byte vs word vs `4*2^N`).** This is the
weakest feature (§5.5) and the real risk is a 4×-wrong size, not just deferral. v1 avoids
it entirely by emitting a **string** from a *named param + `kind:` annotation*, never a
computed number, so the result is byte-identical to today's hand-written expression.
Cross-module numeric resolution (read `inst.resolved_module.srams`) is deferred — and even
then would have to pick a convention. Honest stance: Feature 4 is droppable from v1 if the
conversion count is tiny (Open Question 1).

**Risk: schema lags the model — and the drift test is non-trivial.** The canonical schema
must track `model.py`/`builder.py`, but there is **no single key registry** to diff
against: `_build_module` reads keys via scattered `.get()` calls (`builder.py:38-157` —
`data.get('name')`, `data.get('gen')`, `data.get('params')`, `data.get('clocks')`, …), and
each `_build_*` sub-builder adds more. Auto-enumerating "every key the builder reads" from
code is therefore not free. Two concrete, implementable options (pick one):
  1. **Maintain an explicit `CANONICAL_KEYS` registry** next to the builder (a module-level
     `frozenset` per build function) that the builder *and* the drift test both import;
     a code reviewer adding a `.get('newkey')` must add it to the registry, and the test
     asserts `registry == schema_keys`. Low magic, one-line maintenance per new key.
  2. **AST-scan the builder** in the test: walk `ast.parse(builder source)` for
     `Call(func=Attribute(attr='get'), args=[Constant(str)])` on the `data`/`d` params of
     each `_build_*`, collect the string literals, and assert that set ⊆ schema keys.
     Heavier but zero ongoing maintenance.
Option 1 is recommended for v1 (explicit > clever); option 2 is the fallback if the
registry drifts in practice. Either way this is the one piece of ongoing maintenance the
feature adds.

**Alternative considered — teach `SoCBuilder` the new keys directly.** Rejected: it
spreads sugar awareness into the builder and (via shared `_built_modules` caching,
`builder.py:40`) risks the same expanded module leaking across parents. A pure pre-pass
keeps the builder dumb and the model identical.

**Alternative considered — implement `!include` YAML tags.** Rejected: `!include`
operates at the file level (textual), not the semantic level; it cannot do identity-keyed
list overrides or address packing, and it would couple authoring to file layout. The
preset/merge model is strictly more capable and stays inside `safe_load`.

**Alternative considered — make `lib/interfaces/*.yaml` the source of truth for the
`bus:` expansion.** Rejected for this doc: those files currently disagree with
`protocol_utils.py` (`ADDR_W` vs `ADDR_WIDTH`, `parameters` vs `params`) and are
unused/dead. Wiring them in is the clean-architecture doc's job
(see `02-clean-architecture-adapters-backends.md`); here we reuse the already-canonical
Python table so the two never disagree.

---

## 10. Dependencies & sequencing

**Builds on / aligns with:**

- `02-clean-architecture-adapters-backends.md` — must not contradict the planned
  protocol/adapter refactor. This doc deliberately *reuses* `protocol_utils` rather than
  reworking it, so it composes cleanly whether 02 lands before or after. If 02 makes the
  interface tables data-driven from `lib/interfaces/*.yaml`, Feature 3's `bus:` expansion
  switches its data source with no change to the sugar surface.

**Unblocks:**

- The web GUI YAML builder (see `06-web-gui-yaml-builder.md`): the canonical JSON Schema
  (M6) is the contract the editor validates against, and `--dump-expanded` /
  `expand_module_dict` give the GUI a way to round-trip terse user edits to canonical form
  and back.
- The testbench-generation and config-sweep docs benefit from `--schema-check` as a
  pre-build gate and from terser, less error-prone swept configs.

**Sequencing within this doc:** M1 → (M2, M3, M4, M5 independent, any order) → M6. M6 is
best last so the schema describes the final canonical shape, but it can also land early to
catch typos in the conversions of M2–M5.

**Rough effort:** **M** overall.
- M1 scaffold: S. M2 presets+merge: S–M. M3 auto-base+sizes: M. M4 bus expansion: S
  (reuses existing tables). M5 phys_size/all-except: S. M6 schema+check: M (schema
  authoring + the schema↔builder drift test). No EDA tools needed; all validation is
  Python + `make soc` (parent root) `build_soc/` diffing.

---

### Open questions (could not resolve from code alone)

1. **`phys_size: {auto,kind}` coverage and the byte-vs-word convention.** Several memories
   size from *subsystem-local* params (e.g. `ETH_IMEM_RAM_ADDR_W` is top-level, but a
   generic region uses `$RAM_ADDR_W` set per-instance), and the tree carries three
   conventions (byte = `2^N`, word = `2^N * data/8`, legacy = `4 * 2^N`; see §4.3). The v1
   string-rewrite form requires the author to name the param **and** its `kind:`, which
   covers top-scoped params cleanly but means each conversion is a manual, per-target
   decision — not an automatic sweep. **Confirm how many targets actually warrant
   conversion before committing to Feature 4 at all**; if the count is small, drop it from
   v1 (§5.5 caveat) and leave the hand-written strings.

2. **Whether `auto_base` should regenerate the ASCII comment block** in the parent
   `nanosoc_multicore_soc.yaml:1624-1639`. The block is hand-maintained today; the
   expander could emit it as `desc` per target, but that block lives *above* `targets:`
   as a YAML comment (lost on `safe_load`). Generating the equivalent into
   `build_soc/reports/*_memory_map.txt` (already produced by `text.py`) may be the better
   home — decide during M3.

3. **Identity-keyed list-merge for `connections`.** Presets don't currently contribute
   `connections`, so `_LIST_KEYS` omits it. If a future preset needs to supply default
   connections, the identity field is `port` — confirm no `port:` collisions across
   merged sources before enabling.
