# 02 — Clean Architecture for Adapters & Backends

> Give `nanosoc_gen` a tiny, explicit backend contract (a base class + registry) and a
> single data-driven source of truth for bus protocols ("adapters"), so adding a new
> artifact emitter or a new bus type is a small, reviewable, independently-testable change
> instead of a multi-file surgery on a 1351-line `toplevel.py`.

---

## Status & scope

**Status:** Proposed. Greenfield contract + incremental refactor of existing code. Nothing here
changes generator *output* — every milestone must produce byte-identical artifacts (modulo the
already-stripped timestamp/copyright lines, see `utils.write_if_changed`) until a milestone
explicitly opts into a behaviour change.

**Where this lives (superproject vs submodule — read this first if you only have one repo checked
out).** This doc, `nanosoc_gen/` (the `soc_model` tool), and the `sys_desc/` that holds
`regions/register_maps/subsystems` all live inside the **`nanosoc_arch_tech` submodule**. But the
top-level SoC description and its build harness do **not** live here — they live in the
**superproject root** (`nanosoc-multicore-system/`): `sys_desc/nanosoc_multicore_soc.yaml` and
`sys_desc/Makefile`. The arch_tech-submodule `sys_desc/` has **no** `Makefile` and **no** top YAML.
Consequently the full generate (and therefore M1's golden harness) cannot be driven from the
arch_tech submodule alone — it needs the superproject checkout *and* its sibling submodules
(`eth-ss`, `ethmac-ahb`, `ahb-qspi`) present, because the superproject `sys_desc/Makefile`'s
`LIB_DIRS` (`sys_desc/Makefile:61-69`) span all four submodules via `SOCLABS_*` env vars. Those env
vars (`SOCLABS_NANOSOC_ARCH_TECH_DIR`, `SOCLABS_ETH_SS_DIR`, `SOCLABS_ETHMAC_AHB_DIR`,
`SOCLABS_AHB_QSPI_DIR`, `SOCLABS_NANOSOC_GEN_DIR`) are populated by sourcing the superproject's
`set_env.sh` first; without it the make invocation fails on unresolved `${SOCLABS_*}` paths. All file
references below are **relative to the `nanosoc_arch_tech` submodule** unless prefixed `sys_desc/`
(superproject) or otherwise noted.

**In scope**
- A `Backend` base class / abstract contract and a `BackendRegistry` (replacing the hand-written
  import block + linear call script in `soc_model/__main__.py`).
- A `Protocol`/adapter abstraction that makes the bus-signal tables data-driven and gives each bus
  type one place to live (replacing the duplicated hard-coded tables in
  `backends/protocol_utils.py` and the per-backend `_expand_*` methods).
- A shared `WalkingBackend` mixin for the hierarchy-walk + param-overlay + `_fmt_size` +
  RegisterMap→YAML logic that is copy-pasted across ~9 backends.
- Decoupling `toplevel.py` (~1351 LOC) and `ahb.py` (~815 LOC) from each other and from
  cross-backend reach-ins (e.g. `firmware.py` doing `SoCAhbBackend.__new__(...)`).
- A migration path that refactors existing backends one at a time, each shippable.

**Out of scope (other roadmap docs own these)**
- The YAML front-end format / `uses:` mixins / auto-address packing — see
  `01-*` (YAML schema) once it exists.
- Tech-specific chip-pad generation — see the pad/tech-descriptor doc.
- A Vivado/BD backend, a TB-generation backend — these are *consumers* of the contract this doc
  defines; once the registry exists they become "drop one file" features.
- Unit-test harness and CI matrix — see `06-unit-testing-*.md` / `07-ci-*.md` (filenames TBD).
  This doc defines the *seams* those docs hang tests on; it does not write the test suite.

---

## Motivation

### The concrete problem

`nanosoc_gen` has no backend abstraction. Adding a backend means editing two unrelated regions of
`soc_model/__main__.py` in lockstep:

1. An import in the static block (`__main__.py:19-34`):
   ```python
   from .backends.html import SoCVisualizer
   from .backends.text import SoCTextBackend
   ...                       # 16 explicit imports
   from .backends.sram import SoCSramBackend
   ```
2. A bespoke construct-and-call block in the ~200-line procedural `main()` body
   (`__main__.py:139-313`), where **every backend invents its own constructor and entry method**:
   ```python
   ahb_backend = SoCAhbBackend(top_module, arm_ip_library_path=args.arm_ip_library_path)
   generated = ahb_backend.generate_all(build_dir)                       # __main__.py:171-172
   subsystem_results = SoCSubsystemBackend.generate_all(top_module, build_dir)  # classmethod, :183
   toplevel_path = SoCTopLevelBackend(top_module).generate(rtl_dir, flist_dir)  # :252-253
   ```
   Entry methods are `generate` / `generate_all` / `generate_single` / `generate_memory_map` /
   `generate_html`; constructors take `(top_module)`, `(top_module, arm_ip_library_path)`,
   `(system_module, core_module)`, `(slang_bin)`. They cannot be iterated over generically.

Because there is no contract:
- **No backend can be tested in isolation** without re-deriving its odd constructor/method shape.
- **Ordering is implicit** in line order. `discovery`/`build_info`/`rdl` form a 3-way pipeline by
  hand-threading `RegisterMap` objects through `rdl_backend.generate_single` (`__main__.py:214,233`).
- **Cross-backend reach-ins** are required: `firmware.py` does `SoCAhbBackend.__new__(SoCAhbBackend)`
  to borrow `_compute_effective_address_map`/`_build_initiator_data` (the address-map logic is
  trapped inside the AHB backend).

The adapter (bus-protocol) story is worse. There are **three sources of truth** for what signals an
AHB port has and they can silently disagree:
- `backends/protocol_utils.py:15-92` — the *real* tables (`AHB_INITIATOR_SIGNALS`, etc.), hard-coded
  Python tuples.
- `nanosoc_gen/lib/interfaces/*.yaml` — advertise themselves with `!include` but **`!include` is
  never registered** (parser uses plain `yaml.safe_load`, `parser.py:174`) and
  `parse_interface_definition` (`parser.py:141`) has **zero call sites**. Dead.
- `backends/interfaces/ahb_lite.yaml` — also dead; its values are duplicated by hand into
  `_AHB_LITE_DEFAULTS` (`ahb.py:42-48`).

Adding a new bus type (AXI4, full AHB5) today means editing `protocol_utils.py`, the `bus_member_names`
if-ladder, **and** the `_expand_*` methods in `toplevel.py`, `subsystem.py`, `system.py` — with the
`subsystem.py`/`toplevel.py` pair warning in docstrings that changes must be mirrored in both.

### Why now

The roadmap wants several *new* backends (Vivado/BD, TB generation, pad/tech) and at least one new
adapter-ish concept (typed FPGA interconnect ports). Each of those is currently a fork of the
`__main__.py` surgery. Paying down the contract first turns each later feature into a single file
plus a registry decorator.

### What good looks like

- Adding a backend = create `backends/<name>.py`, subclass `Backend`, decorate with
  `@register_backend(...)`. No edit to `__main__.py`.
- Adding a bus protocol = add one `Protocol` definition (data) + register it. No edit to any backend.
- Each backend and each protocol is unit-testable in isolation (see `06-unit-testing-*.md`).
- `toplevel.py` shrinks because signal expansion and hierarchy walking move to shared modules.
- `python -m soc_model --list-backends` prints the pipeline; `--only ahb,toplevel` runs a subset
  (huge for the per-config validity sweep in `07-ci-*.md`).

---

## Current state (grounded)

### Orchestrator

`soc_model/__main__.py` is a single `main()` (no pipeline object). Verified shape:
- argparse (`:38-61`), config-override parsing (`:64-71`).
- parse → `SoCParser`/`SoCBuilder.build_system` (`:82-86`); validate → `SoCValidator.validate_all`
  (`:107-108`); exits on `--validate-only` (`:115-116`).
- Build dirs `build_soc/{rtl,flist,reports,...}` (`:128-135`).
- Then 16 backends invoked in a fixed sequence (`:139-313`), each with its own ctor/method.

### Backends — no base class, no registry

Confirmed by `ls backends/` (18 `.py`) and grep: there is **no** `class Backend`, no ABC, no
registry, no entry-points. `pyproject.toml` declares only the `soc-model` console script and
`setuptools.packages.find`. The only inheritance in the tree is
`class SoCSubsystemBackend(SoCTopLevelBackend)` (`subsystem.py:26`).

Representative ctor/method divergence (all verified):

| Backend | file:line | constructor | entry method |
|---|---|---|---|
| `SoCTopLevelBackend` | `toplevel.py:44,48` | `(top_module)` | `generate(rtl_dir, flist_dir)` |
| `SoCAhbBackend` | `ahb.py:160,164` | `(top_module, arm_ip_library_path)` | `generate_all(build_dir)` |
| `SoCSubsystemBackend` | `subsystem.py:34` | `(subsystem_module)` | `generate_all(top, build_dir)` **classmethod** |
| `SoCSramBackend` | `sram.py:29,32` | `(top_module)` | `generate(output_path)` |
| `SoCRdlBackend` | `rdl.py` | `(top_module)` | `generate_all` + `generate_single(rm, build_dir)` |
| `SoCDiscoveryBackend` | `discovery.py:108,111,114` | `(top_module)` | `generate(build_dir)` → `List[Tuple[str, RegisterMap, Path]]` |
| `SoCSystemBackend` | `system.py:38` | `(system_module, core_module)` | `generate(rtl_dir, flist_dir)` |
| `SoCChipBackend` | `chip.py:31` | `(system_module, core_module)` | `generate(...)` → `(chip, pads)` |
| `SoCLintBackend` | `lint.py:108` | `(slang_bin)` | `lint_and_report(...)` |

### jinja2 boilerplate, duplicated ≥6×

Every template backend repeats this (verified in `toplevel.py:31-35,53-55,60-66`, same in
`ahb.py:30-34`, `subsystem.py` via inheritance, `system.py`, `chip.py`, `firmware.py`,
`soc_config_pkg.py`, `docs.py`):
```python
try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    Environment = None
    FileSystemLoader = None
_BACKEND_DIR = Path(__file__).resolve().parent
_TEMPLATE_DIR = _BACKEND_DIR / 'templates'
...
if Environment is None:
    print("  WARNING: jinja2 not available — skipping ...")
    return None
env = Environment(loader=FileSystemLoader(str(_TEMPLATE_DIR)), trim_blocks=True,
                  lstrip_blocks=True, keep_trailing_newline=True)
```

### Adapter (protocol) logic — hard-coded tables + per-backend expansion

`protocol_utils.py:15-92` defines the canonical tables as `(suffix, direction, width_expr)` tuples;
`bus_member_names(iface)` (`:95-129`) is a per-type `if`-ladder reproducing the *names*. Each SV
backend re-expands these into ports with its own `_expand_ahb_port` / `_expand_axis_port` etc.
`subsystem.py:52` overrides `_expand_ahb_port` with a near-duplicate. The load-bearing boundary
heuristic `passthrough_initiator_uses_initiator_boundary` (`protocol_utils.py:132-164`) decides AHB
boundary form by inspecting whether `EXCLUDE` contains `hready` — a string heuristic, documented only
in a 30-line docstring.

### Model is clean and reusable

`model.py` dataclasses are dumb containers (`Module:363`, `Interface:60`, `Interconnect`,
`InterconnectTarget`, `RegisterMap`, etc.). `Interface` already exposes
`is_input/is_output/addr_width/data_width` (`model.py:92/96/78/84`). There is an unused
`InterfaceSignal`/`InterfaceDefinition` pair (`model.py:41/50`) that the new Protocol layer can
adopt or replace. **No backend mutates the model** today (they `.append` to RegisterMaps they own),
so a read-only contract is safe to declare.

### No tests

`find nanosoc_gen -name 'test_*.py'` → empty. The generator's only self-check is
`--validate-only`. This refactor must therefore be guarded by a **golden-output diff** (see Testing),
since there is no existing suite to lean on.

---

## Proposed design

Three orthogonal pieces. Each can land independently.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  CLI (__main__.py)                                                    │
  │   parse → build → validate → registry.run_pipeline(ctx, selection)   │
  └───────────────────────────────┬─────────────────────────────────────┘
                                   │ GenContext (top, system, build_dir, opts, messages)
                ┌──────────────────┴───────────────────┐
                ▼                                       ▼
      ┌───────────────────┐                  ┌─────────────────────┐
      │  BackendRegistry  │  iterate, order  │  ProtocolRegistry   │
      │  @register_backend│ ───────────────► │  AHB / APB / AXIS / │
      └─────────┬─────────┘                  │  SWD / GPIO / DBGAHB│
                │                             └──────────┬──────────┘
   ┌────────────┼─────────────┐                         │ expand(iface) -> [SignalPort]
   ▼            ▼             ▼                          │
 Backend     Backend      Backend  ◄── WalkingBackend ──┘  (shared walk + fmt + emit_template)
 (toplevel)  (ahb)        (sram)        mixin / base
```

### 1. The `Backend` contract

A small ABC. Every backend declares its name, the phase it runs in, its dependencies, and a single
`run(ctx)` method. The registry orders and invokes them. Constructors take **nothing** (state comes
from `ctx`), which kills the ctor-divergence problem.

```python
# soc_model/backends/base.py  (NEW)
from __future__ import annotations
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import IntEnum
from pathlib import Path
from typing import Any, Dict, List, Optional

from ..model import Module
from ..validator import ValidationMessage


class Phase(IntEnum):
    """Coarse ordering buckets. Within a phase, declared `after` deps refine order."""
    REPORT      = 10   # html/text/python/sram — read-only analysis
    INTERCONNECT = 20  # ahb (produces RTL the rest reference)
    SUBSYSTEM   = 30
    REGISTERS   = 40   # discovery + build_info produce RegisterMaps; rdl runs after, consuming them
    PACKAGE     = 50   # soc_config_pkg
    TOPLEVEL    = 60   # toplevel / system / chip
    FIRMWARE    = 70
    DOCS        = 80
    LINT        = 90


@dataclass
class GenContext:
    """Everything a backend may read. Backends MUST treat `top`/`system` as read-only."""
    top: Module
    build_dir: Path
    rtl_dir: Path
    flist_dir: Path
    reports_dir: Path
    system: Optional[Module] = None
    messages: List[ValidationMessage] = field(default_factory=list)
    opts: Dict[str, Any] = field(default_factory=dict)   # CLI flags: arm_ip_library_path, config_overrides, slang_bin, ...
    artifacts: Dict[str, Any] = field(default_factory=dict)  # cross-backend handoff (e.g. RegisterMaps for rdl)

    def subdir(self, name: str) -> Path:
        p = self.build_dir / name
        p.mkdir(parents=True, exist_ok=True)
        return p


class Backend(ABC):
    name: str = ""                 # unique id, e.g. "ahb"
    phase: Phase = Phase.REPORT
    after: tuple = ()              # backend names that must run first (within/after phase)
    requires_jinja: bool = False   # base handles the skip-with-warning uniformly

    @abstractmethod
    def run(self, ctx: GenContext) -> "BackendResult":
        ...

    # ---- shared helpers (was duplicated in 6 backends) ----
    def emit_template(self, ctx, template_name, out_path, **kw) -> Optional[Path]:
        """Render a Jinja2 template through the shared env and write-if-changed."""
        ...

    def enabled(self, ctx: GenContext) -> bool:
        """Override to gate (e.g. system/chip only with --system-yaml)."""
        return True


@dataclass
class BackendResult:
    files: List[Path] = field(default_factory=list)
    skipped: bool = False
    reason: str = ""
```

`BackendResult` standardises the return shape (today it's `Path` / list-of-tuples / `(Path,Path)` /
`None`), which lets the CLI print a uniform summary and lets tests assert on `result.files`.

### 2. The registry

```python
# soc_model/backends/registry.py  (NEW)
_REGISTRY: list[type[Backend]] = []

def register_backend(cls=None):
    """Class decorator. Idempotent; rejects duplicate `name`."""
    def _add(c):
        assert c.name, f"{c.__name__} must set .name"
        assert all(x.name != c.name for x in _REGISTRY), f"duplicate backend name {c.name!r}"
        _REGISTRY.append(c)
        return c
    return _add(cls) if cls else _add

def all_backends() -> list[type[Backend]]:
    return list(_REGISTRY)

def ordered(selection: set[str] | None = None) -> list[type[Backend]]:
    """Topological sort by (phase, after-deps), filtered by `selection`."""
    chosen = [c for c in _REGISTRY if selection is None or c.name in selection]
    return _toposort(chosen)   # stable: phase first, then `after` edges

def run_pipeline(ctx: GenContext, selection=None) -> list[tuple[str, BackendResult]]:
    out = []
    for cls in ordered(selection):
        be = cls()
        if not be.enabled(ctx):
            out.append((cls.name, BackendResult(skipped=True, reason="disabled"))); continue
        if be.requires_jinja and not _have_jinja():
            out.append((cls.name, BackendResult(skipped=True, reason="no jinja2"))); continue
        out.append((cls.name, be.run(ctx)))
    return out
```

Discovery: backends are registered by importing the `backends` package. `backends/__init__.py`
imports each module (one line each) so the decorators fire. This keeps imports explicit and
greppable (no surprise plugin loading), while removing the second editing site in `main()`.

#### The `rdl` ↔ `discovery` ↔ `build_info` handoff contract (the one ordering-sensitive part)

`after=(...)` only encodes *ordering*; it does not move *data*. Today the data moves by hand in
`main()`: `discovery_backend.generate(build_dir)` returns `discovery_results`, a list of
`(ic_name, disc_rm, disc_yaml_path)`, and `main()` loops those and calls
`rdl_backend.generate_single(disc_rm, build_dir)` (`__main__.py:207,211,214`); separately,
`build_info_backend.generate(...)` returns `(bi_rm, bi_yaml_path)` and `main()` calls
`rdl_backend.generate_single(bi_rm, build_dir)` (`__main__.py:231,233`). `rdl` thus runs **twice more
after** discovery/build_info, each time fed a `RegisterMap` they produced. The registry must make this
explicit, not implicit in line order. Concrete contract on `GenContext.artifacts` (string keys,
fixed shape) so the pipeline is reviewable:

| Phase | Backend | reads `artifacts[...]` | writes `artifacts[...]` |
|---|---|---|---|
| `REGISTERS` | `discovery` | — | `"register_maps"` ← extend with each `(name, RegisterMap, path)` |
| `REGISTERS` | `build_info` | — | `"register_maps"` ← append `(name, RegisterMap, path)` |
| `REGISTERS` | `rdl` (`after=("discovery","build_info")`) | `"register_maps"` | — (emits SystemRDL/RTL per map) |

So `discovery` and `build_info` each **append** their produced `RegisterMap`s to the single
`ctx.artifacts["register_maps"]` list (a `list[tuple[str, RegisterMap, Path]]`, default `[]`), and
`rdl`'s `run(ctx)` consumes that list — replacing the two hand-threaded `generate_single` calls with
one loop. `rdl`'s own static-RDL emission (its pre-existing `generate_all`) still runs in its `run`;
the dynamic per-map emission is the `artifacts`-driven part. This makes the 3-way pipeline a declared
producer/consumer pair instead of `after`-edge hand-waving, and gives M6 a precise migration target.

`__main__.py` collapses from ~175 lines of dispatch to:
```python
ctx = GenContext(top=top_module, system=system_module, build_dir=build_dir,
                 rtl_dir=rtl_dir, flist_dir=flist_dir, reports_dir=reports_dir,
                 messages=messages, opts={
                     'arm_ip_library_path': args.arm_ip_library_path,
                     'config_overrides': config_overrides,
                     'slang_bin': args.slang_bin, 'lint': args.lint, ...})
import soc_model.backends            # fires @register_backend
selection = set(args.only.split(',')) if args.only else None
for name, res in run_pipeline(ctx, selection):
    print_summary(name, res)
```

### 3. The Protocol / adapter abstraction

Move the bus tables out of `protocol_utils.py` into per-protocol objects, all registered in one place.
A `Protocol` knows how to expand an `Interface` into `SignalPort`s for **either** boundary form, and
exposes `member_names` (kills the `bus_member_names` if-ladder) and `is_bus`. Backends call
`protocol_for(iface).expand(iface, role)` instead of branching on `iface.type`.

```python
# soc_model/adapters/base.py  (NEW)
@dataclass(frozen=True)
class SignalSpec:
    suffix: str
    direction: str          # 'in'/'out' from the role's perspective
    width: str              # 'SYS_ADDR_W' | '2' | 'WIDTH' ...

@dataclass(frozen=True)
class SignalPort:
    name: str               # fully-qualified, e.g. 'cpu_0_dbgahb_slvaddr'
    direction: str
    width: str

class Protocol(ABC):
    type: str = ""          # matches Interface.type, e.g. 'ahb'
    @abstractmethod
    def signals(self, role: str, iface) -> list[SignalSpec]: ...
    def member_names(self, iface) -> list[str]:
        roles = ("initiator", "target") if self.is_bus else ("",)
        names = set()
        for r in roles:
            names |= {f"{iface.name}_{s.suffix}" for s in self.signals(r, iface)}
        return sorted(names)
    def expand(self, iface, role: str) -> list[SignalPort]:
        out = []
        for s in self.signals(role, iface):
            out.append(SignalPort(f"{iface.name}_{s.suffix}",
                                  s.direction, self._resolve_width(s.width, iface)))
        return out
    is_bus: bool = True
```

Concrete AHB protocol carries the existing tables verbatim (so output is identical) **plus** the
boundary heuristic as a method — the one place it lives:
```python
# soc_model/adapters/ahb.py  (NEW)
@register_protocol
class AhbProtocol(Protocol):
    type = "ahb"
    INITIATOR = AHB_INITIATOR_SIGNALS   # moved here, unchanged
    TARGET    = AHB_TARGET_SIGNALS
    def signals(self, role, iface):
        excl = set((iface.params or {}).get('EXCLUDE', []) or [])
        table = self.INITIATOR if role == 'initiator' else self.TARGET
        return [SignalSpec(*t) for t in table if t[0] not in excl]
    def passthrough_uses_initiator_boundary(self, iface) -> bool:
        return 'hready' not in set((iface.params or {}).get('EXCLUDE', []) or [])
```

`protocol_utils.py` becomes a thin shim that re-exports `bus_member_names`/
`passthrough_initiator_uses_initiator_boundary` by delegating to the registry, so existing imports in
`validator.py:8`, `toplevel.py`, `subsystem.py` keep working through the whole migration.

### Why these decisions

- **Phase enum + `after` deps**, not a free-form DAG library: the real dependency set is tiny and
  mostly captured by coarse phases; an enum is greppable and needs no new dependency. The few true
  edges are: `ahb` before `toplevel` (`SoCTopLevelBackend` references the AHB-emitted RTL), and `rdl`
  after `discovery` **and** `build_info` (`rdl` declares `after=("discovery","build_info")` because it
  consumes the `RegisterMap`s they append to `ctx.artifacts["register_maps"]` — note `rdl` runs *after*
  them, the opposite of a naive "rdl first" reading). The data for that last edge moves through the
  `artifacts` contract documented above, not through `after` alone.
- **Empty constructors + `GenContext`**: removes the single biggest source of divergence and makes
  every backend trivially instantiable in a test.
- **Protocol objects over a YAML schema (for now)**: the `lib/interfaces/*.yaml` are dead and disagree
  with reality. Re-animating them is a *separate* decision (it belongs with the YAML-format doc). The
  cheap, safe win is to give each protocol one Python home; a later milestone can make `signals()`
  read a YAML if desired. Keeping the tables as Python first guarantees byte-identical output.
- **Shim, don't break**: keep every public function name working during migration so each PR is small.

---

## Implementation plan

Each milestone is independently shippable and must pass the **golden-output diff** (see Testing)
before merge — i.e. `build_soc/` is byte-identical to a baseline captured at the start, except where
the milestone explicitly changes behaviour.

### M1 — Golden-output harness + shared Jinja env helper *(no behaviour change)*
- **What:** Add `nanosoc_gen/tests/` with `test_golden.py` that runs the full generator on the
  superproject's top YAML (`sys_desc/nanosoc_multicore_soc.yaml` — **in the superproject root, not the
  arch_tech submodule**, see Status & scope) with the 8 `--lib-dir` flags built from
  `LIB_DIRS`/`LIB_DIR_FLAGS` (`sys_desc/Makefile:61-71`) into a temp dir, and diffs against a
  checked-in/committed baseline tarball (or a stored hash manifest) using the same timestamp/copyright
  stripping as `utils.write_if_changed`. Add a tiny `backends/_jinja.py` with `make_env(template_dir)`
  and `have_jinja()`; rewire **one** backend (`docs.py`, the smallest jinja user) to use it.
- **Prerequisites (make this runnable, not just describable):** the test must, before invoking
  `soc_model`, (a) require the superproject checkout with sibling submodules `eth-ss`, `ethmac-ahb`,
  `ahb-qspi` present — a generate spans all four; (b) source the superproject `set_env.sh` (or accept
  the `SOCLABS_*` vars from the environment) so the `--lib-dir` paths resolve; (c) `pytest.skip(...)`
  with a clear message if `SOCLABS_NANOSOC_ARCH_TECH_DIR`/`SOCLABS_ETH_SS_DIR`/`SOCLABS_ETHMAC_AHB_DIR`/
  `SOCLABS_AHB_QSPI_DIR` are unset or a sibling submodule is missing, so a reader with only
  `nanosoc_arch_tech` checked out gets a skip, not a confusing failure. The simplest robust
  implementation is to shell out to `make -C $SOCLABS_PROJECT_DIR/sys_desc soc_model BUILD_SOC_DIR=<tmp>`
  rather than re-deriving the flag list, so the flag set never drifts from the Makefile.
- **Why:** Nothing else is safe to refactor without this. It is the contract the rest of the plan
  leans on, and it gives `06-unit-testing-*.md` its first test.
- **Acceptance:** with the superproject env sourced, `pytest nanosoc_gen/tests/test_golden.py` passes;
  `make -C sys_desc` (superproject) output unchanged; with the env unset the test reports *skipped*,
  not failed; `docs.py` no longer has its own try/except jinja block.

### M2 — `Backend` base + `GenContext` + `BackendResult`, adopted by leaf backends
- **What:** Add `backends/base.py`. Convert the *read-only, single-method* backends with no
  cross-deps: `sram.py`, `text.py`, `python.py`, `html.py`. They subclass `Backend`, take no ctor
  args, read from `ctx`, return `BackendResult`. `__main__.py` still calls them directly (no registry
  yet) but through `GenContext`.
- **Why:** Proves the contract on the easy cases first; these four have the simplest shapes.
- **Acceptance:** golden diff clean; the four backends are instantiable as `SoCSramBackend()` and
  driven by `run(ctx)`; a unit test constructs a 1-region `Module`, runs `SoCSramBackend().run(ctx)`,
  asserts the report file content.

### M3 — `BackendRegistry` + `@register_backend`, CLI `--only` / `--list-backends`
- **What:** Add `backends/registry.py`; decorate the M2 backends; `backends/__init__.py` imports them;
  `__main__.py` runs the M2 set via `run_pipeline(ctx, {'sram','text','python','html'})` and the rest
  via the old code path (mixed mode is fine — registry only owns what's registered). Add `--only`
  and `--list-backends`.
- **Why:** Establishes the registry without a big-bang cutover; `--only` immediately helps the CI
  validity sweep (`07-ci-*.md`) run cheap subsets.
- **Acceptance:** `python -m soc_model X.yaml --list-backends` lists the 4; `--only sram` produces
  only the SRAM report; golden diff clean for a full run.

### M4 — Protocol/adapter layer behind a shim *(no behaviour change)*
- **What:** Add `soc_model/adapters/{base,ahb,apb,axis,swd,gpio,dbgahb,registry}.py`. Move the tables
  from `protocol_utils.py` into protocol classes (verbatim values). Rewrite
  `protocol_utils.bus_member_names` and `passthrough_initiator_uses_initiator_boundary` as shims that
  delegate to the registry. **No backend changes yet.**
- **Why:** Single source of truth for signals, with the boundary heuristic owned by `AhbProtocol`.
  Output cannot change because the tables are identical and the public functions are preserved.
- **Acceptance:** golden diff clean; unit test asserts
  `AhbProtocol().member_names(iface)` equals the legacy `bus_member_names(iface)` for a sample of
  ifaces; `validator.py` still imports `bus_member_names` and passes.

### M5 — Route `_expand_*` through the adapter; extract `WalkingBackend`
- **What:** In `toplevel.py`/`subsystem.py`/`system.py`, replace `_expand_ahb_port`/`_expand_axis_port`
  internals with calls to `protocol_for(iface).expand(iface, role)`. Add `backends/walk.py` with a
  `WalkingBackend` mixin: `walk_modules(yield_params=True)`, `fmt_size`, `write_regmap_yaml`. Convert
  `sram.py`, `discovery.py`, `build_info.py`, `text.py`, `docs.py` to use it. This collapses the
  copy-pasted hierarchy-walk + param-overlay logic (`sram.py:66` `_walk`, `subsystem.py:476` `_walk`,
  and the recursion in `discovery.py:126-148` `_generate_for_module`) onto one `walk_modules`, and the
  **3** verified copies of the size formatter `_fmt_size` (`sram.py:15`, `docs.py:28`, `text.py:9`)
  onto `WalkingBackend.fmt_size`. Note: `discovery.py` has no `_fmt_size` — it only shares the walk.
- **Why:** This is where `toplevel.py`/`ahb.py` LOC actually drops and the `subsystem.py`↔`toplevel.py`
  drift risk goes away (the boundary form is now one method on `AhbProtocol`).
- **Acceptance:** golden diff clean; `toplevel.py` loses its `_expand_*` signal-table loops; `sram.py`,
  `docs.py`, `text.py` each lose their module-level `_fmt_size` (replaced by `WalkingBackend.fmt_size`),
  confirmed by `grep -rn 'def _fmt_size' nanosoc_gen/soc_model/backends` returning nothing. Concrete
  pass/fail beyond the golden diff: `grep -rn 'def _walk\|_generate_for_module' backends` shows the
  walk consolidated to `WalkingBackend`; `wc -l toplevel.py` drops (estimate −150 LOC, *measured at M5,
  not asserted now* — see Open Questions on why the provenance/xref code may not move cleanly).

### M6 — Convert the structural + register backends to the contract; full registry cutover
- **What:** Convert `ahb.py`, `toplevel.py`, `subsystem.py`, `system.py`, `chip.py`, `rdl.py`,
  `discovery.py`, `build_info.py`, `soc_config_pkg.py`, `firmware.py`, `lint.py` to `Backend`
  subclasses with `phase`/`after` declared. Wire the **`rdl`/`discovery`/`build_info` handoff** exactly
  as specified in "The `rdl` ↔ `discovery` ↔ `build_info` handoff contract" above: `discovery` and
  `build_info` append their `(name, RegisterMap, path)` tuples to `ctx.artifacts["register_maps"]`;
  `rdl` declares `after=("discovery","build_info")` and consumes that list, replacing the two
  hand-threaded `generate_single` calls at `__main__.py:214,233`. Move the **pure** address-map helpers
  (`_build_initiator_data`, `_compute_effective_address_map`) out of `ahb.py` into `addrmap.py` as
  module-level functions (they take no `self`/`top` — see the Risks entry) so `firmware.py` stops doing
  `SoCAhbBackend.__new__(...)`. Delete the linear dispatch in `__main__.py`; everything runs through
  `run_pipeline(ctx)`.
- **Why:** Completes the cutover; the cross-backend reach-in is gone; ordering is declarative.
- **Acceptance:** golden diff clean on a full multicore + `--system-yaml` run (this is the only test
  that proves the `rdl`/`discovery`/`build_info` handoff is correct — the per-map RDL/RTL files must be
  byte-identical, which fails immediately if the `artifacts["register_maps"]` producer/consumer wiring
  drops or re-orders a map); `__main__.py` is <80 lines; `grep -rn 'SoCAhbBackend.__new__'` returns
  nothing; `grep -rn 'generate_single' __main__.py` returns nothing (the hand-threading is gone);
  `--list-backends` shows all in phase order with `rdl` listed after `discovery` and `build_info`.

### M7 — Cleanup & docs
- **What:** Delete dead `lib/interfaces/*.yaml` **or** wire `Protocol.signals()` to read them (decision
  deferred to the YAML-format doc; default = delete with a note). Remove the dead
  `parse_interface_definition`/`InterfaceDefinition` if unadopted. Add a `docs/CONTRIBUTING-backends.md`
  showing "add a backend in 20 lines" and "add a protocol in 15 lines".
- **Why:** Removes the misleading triple source of truth and documents the new contract.
- **Acceptance:** grep finds no dead interface loaders; new doc example, copy-pasted, produces a
  working trivial backend.

---

## File & module changes

### New files
| Path | Purpose |
|---|---|
| `nanosoc_gen/soc_model/backends/base.py` | `Backend` ABC, `Phase`, `GenContext`, `BackendResult` |
| `nanosoc_gen/soc_model/backends/registry.py` | `register_backend`, `ordered`, `run_pipeline` |
| `nanosoc_gen/soc_model/backends/_jinja.py` | `make_env(dir)`, `have_jinja()` (kills the 6× boilerplate) |
| `nanosoc_gen/soc_model/backends/walk.py` | `WalkingBackend` mixin: hierarchy walk + `fmt_size` + `write_regmap_yaml` |
| `nanosoc_gen/soc_model/backends/addrmap.py` | extracted `compute_effective_address_map` / `build_initiator_data` (was in `ahb.py`) |
| `nanosoc_gen/soc_model/adapters/base.py` | `Protocol`, `SignalSpec`, `SignalPort` |
| `nanosoc_gen/soc_model/adapters/{ahb,apb,axis,swd,gpio,dbgahb}.py` | one protocol each (tables moved from `protocol_utils.py`) |
| `nanosoc_gen/soc_model/adapters/registry.py` | `register_protocol`, `protocol_for(type)` |
| `nanosoc_gen/tests/test_golden.py` | full-generate + diff baseline (M1) |
| `nanosoc_gen/tests/test_backends.py` | per-backend unit tests (M2+) |
| `nanosoc_gen/tests/test_adapters.py` | protocol expansion vs legacy tables (M4) |
| `docs/CONTRIBUTING-backends.md` | author guide (M7) |

### Modified files
| Path | Change |
|---|---|
| `soc_model/__main__.py` | replace import block + 175-line dispatch with `GenContext` + `run_pipeline`; add `--only`, `--list-backends` |
| `soc_model/backends/__init__.py` | import each backend module so decorators register |
| `soc_model/backends/protocol_utils.py` | becomes a shim re-exporting from `adapters/` (preserve `bus_member_names`, `passthrough_initiator_uses_initiator_boundary`, `width_str`) |
| `soc_model/backends/{sram,text,python,html}.py` | M2: subclass `Backend`, take `ctx` |
| `soc_model/backends/{ahb,toplevel,subsystem,system,chip,rdl,discovery,build_info,soc_config_pkg,firmware,lint,docs}.py` | M5/M6: subclass `Backend`, use `_jinja`, `walk`, `adapters` |
| `soc_model/backends/firmware.py` | drop `SoCAhbBackend.__new__(...)`; import from `addrmap.py` |
| `nanosoc_gen/pyproject.toml` | add `[project.optional-dependencies] test = ["pytest"]`; add `tests*` exclusion note |

### Migration of an existing backend (concrete before/after — `sram.py`)

Before (`sram.py:29-36`):
```python
class SoCSramBackend:
    def __init__(self, top_module: Module):
        self.top = top_module
    def generate(self, output_path: str):
        ...
        self._walk(self.top, self.top.name, top_flat, entries)
```
After (M2 + M5):
```python
from .base import Backend, Phase, GenContext, BackendResult
from .walk import WalkingBackend
from .registry import register_backend

@register_backend
class SoCSramBackend(WalkingBackend, Backend):
    name = "sram"
    phase = Phase.REPORT
    def run(self, ctx: GenContext) -> BackendResult:
        entries = []
        for hier, module, eff in self.walk_modules(ctx.top):   # shared walk + param overlay
            for s in module.srams:
                entries.append((f"{hier}.{s.name}", self._resolve(s, eff)))
        out = ctx.reports_dir / f"{ctx.top.name}_sram_report.txt"
        write_if_changed(out, self._render(ctx.top, entries))   # _render unchanged
        return BackendResult(files=[out])
```
The render text is untouched, so the golden diff stays clean. Two distinct duplications collapse here,
verified separately (the doc keeps them separate because they live at different lines):
- the hierarchy-walk + param-overlay (`sram.py:66-97` `_walk`, `subsystem.py:476` `_walk`,
  `discovery.py:126-148` `_generate_for_module` recursion) → `WalkingBackend.walk_modules`;
- the 3 copies of the size formatter (`sram.py:15`, `docs.py:28`, `text.py:9`) → `WalkingBackend.fmt_size`.
`discovery.py` shares only the walk, not the formatter.

### CLI additions
```
--only NAMES        Comma-separated backend names to run (default: all). e.g. --only ahb,toplevel
--list-backends     Print registered backends in run order, then exit.
```

---

## Testing & validation

This refactor's safety net is **golden-output equivalence**; it is the primary contract for every
milestone and the seam the dedicated test/CI docs build on.

1. **Golden diff (M1, runs every milestone).** Generate the full multicore SoC into a temp dir;
   diff each file against a baseline, applying `utils.write_if_changed`'s timestamp/copyright
   stripping (`_TIMESTAMP_LINE_RE`, `utils.py:137`) so non-deterministic `datetime.now()` lines
   (e.g. `toplevel.py:97`, `docs.py:80`) don't cause false diffs. Failing diff = regression.
   **Prerequisite (see Status & scope and M1):** source the superproject `set_env.sh` first so the
   `SOCLABS_*` `--lib-dir` paths resolve, and have the sibling submodules (`eth-ss`, `ethmac-ahb`,
   `ahb-qspi`) checked out — the generate spans all four. The test `pytest.skip`s if they are absent.
   ```bash
   source set_env.sh            # superproject root: populates SOCLABS_* used by --lib-dir
   cd nanosoc_gen && python -m pytest tests/test_golden.py -q
   ```
   This is exactly the "compile (minutes)" gate described in `07-ci-*.md`; add it as a fast CI job
   *before* the existing `make -C sys_desc` step (which is the superproject `sys_desc/Makefile`).

2. **Per-backend unit tests (M2+).** Because backends now take no ctor args and read a `GenContext`,
   each is testable on a hand-built 1-region `Module`. `06-unit-testing-*.md` owns the fixtures; this
   doc guarantees the seam:
   ```python
   def test_sram_report(tmp_path, one_sram_module):
       ctx = GenContext(top=one_sram_module, build_dir=tmp_path, rtl_dir=tmp_path/'rtl',
                        flist_dir=tmp_path/'flist', reports_dir=tmp_path/'reports')
       res = SoCSramBackend().run(ctx)
       assert res.files and "1 SRAM" in res.files[0].read_text()
   ```

3. **Adapter equivalence (M4).** Assert the new `Protocol.member_names` / `expand` reproduce the
   legacy tables for every `iface.type` and for the `EXCLUDE: [hready]` boundary cases (the two
   golden cases the docstring at `protocol_utils.py:140-159` calls out: eth_ss vs cpu_ss).

4. **Registry tests (M3/M6).** `ordered()` is stable and respects `after` deps; duplicate `name`
   raises; `--only` runs the requested subset; `--list-backends` matches the legacy fixed sequence.

5. **Downstream sanity (M6).** Run the existing cocotb smoke (`make -C cocotb soc_multicore_smoke`)
   once at M6 to confirm the cutover's RTL still elaborates and boots — the golden diff already
   guarantees identical bytes, so this is a belt-and-braces check, not a per-milestone gate.

---

## Risks, tradeoffs, alternatives considered

- **Golden baseline drift.** The baseline must be regenerated whenever a *legitimate* output change
  lands. Mitigation: store a hash manifest in-repo and a `make regen-golden` target; PRs that change
  output must update it in the same commit, making the change reviewable in the diff.
- **`subsystem.py`/`toplevel.py` coupling is genuinely subtle.** M5 touches the load-bearing AHB
  boundary heuristic. Risk: a boundary-form regression that the golden diff *does* catch but is hard to
  root-cause. Mitigation: M4 lands the adapter behind a shim with no behaviour change and an
  equivalence test first; M5 only swaps the call site.
- **Mixed-mode period (M3–M6).** While some backends are registry-driven and others are not, ordering
  lives in two places. Mitigation: keep the non-registered backends in their existing fixed order in
  `__main__.py`; the registry only owns what it owns. Window is bounded to a few PRs.
- **`ahb.py`'s `firmware.py` reach-in.** Extracting the address-map helpers (M6) could subtly change
  results if the borrowed methods relied on `self` state. Verified against the code (do not take on
  faith — re-check before extracting): the two methods that `firmware.py` reaches in for are pure
  functions of their **arguments**, with *zero* `self.` references in their own bodies:
  - `_build_initiator_data(ic)` (`ahb.py:329-396`) reads only `ic`; it does **not** call any other
    `SoCAhbBackend` method and does **not** read `self.top`.
  - `_compute_effective_address_map(init_data, remap_config)` (`ahb.py:513-570`) reads only its two
    args; no `self.` references at all.

  So the `dummy.top = self.top` assignment at both reach-in sites (`firmware.py:199` and `:448`) is
  already dead — the borrowed methods never read it. Extraction is therefore *cleaner* than "a free
  function taking `top`": they become module-level functions `build_initiator_data(ic)` and
  `compute_effective_address_map(init_data, remap_config)` in `addrmap.py`, taking **no** `top` at all.
  Caveat (the genuine entanglement, kept honest): these two methods are *callees*; the **callers** that
  also live in `ahb.py` — `_generate_xml` (`:401`) and the remap driver (`:593-594`) — do chain
  `_build_initiator_data` → `_build_xml_initiator_block` (`:469`) → `_generate_remap_configurations`
  (`:572`) on `self`. Those callers stay inside `SoCAhbBackend` and simply import the two pure helpers
  from `addrmap.py`; only the two leaf helpers move. The review claim that *the extracted methods*
  call other `self` methods is a misread of those callers — verified false for the two leaves.
- **Alternative: setuptools entry-points plugin system.** Rejected for now — it adds install-time
  machinery and hides the backend set; the in-repo decorator + explicit `__init__.py` imports keep
  the set greppable, which the team values (the research notes the explicit import block as
  intentional). Entry-points can be layered on later without changing the `Backend` contract.
- **Alternative: full DAG scheduler.** Rejected — the dependency graph is ~3 real edges; an enum +
  `after` is simpler and needs no dependency.
- **Alternative: re-animate `lib/interfaces/*.yaml` as the protocol source now.** Deferred to the
  YAML-format doc — doing it here risks output drift and conflates two concerns. The one *clean*
  divergence is role naming: the YAMLs say `role: master`/`role: slave` while the model's `Interface`
  carries `direction: initiator`/`target`. The width-param spelling is *not* a divergence — the model
  already accepts both spellings: `Interface.addr_width` (`model.py:80`) reads
  `params.get('ADDR_WIDTH') or params.get('ADDR_W')` and `data_width` (`model.py:86`) reads
  `DATA_WIDTH or DATA_W`, so the YAML `ADDR_W` would resolve fine. Re-animation still needs a
  role-name mapping and a registered `!include` loader, which is why it belongs with the YAML doc.

---

## Dependencies & sequencing

- **Builds on:** the gen-core and backends research (this digest). No other roadmap doc is a hard
  prerequisite — M1–M3 can start immediately.
- **Unblocks:**
  - A Vivado/BD backend, a TB-generation backend, and a pad/tech backend — each becomes a single
    `@register_backend` file once M3/M6 land. See the FPGA/BD and pad-tech roadmap docs.
  - `06-unit-testing-*.md` — its fixtures hang off `GenContext` and the no-arg constructors this doc
    introduces; M1's golden harness is its first test.
  - `07-ci-*.md` — `--only` and `--list-backends` make per-config sweeps cheap (run validate + one
    backend instead of the whole batch).
  - The YAML-format doc (`01-*`) can decide whether `Protocol.signals()` reads YAML; M4 leaves a
    clean seam.
- **Effort:** M1 **S**; M2 **S**; M3 **S/M**; M4 **M**; M5 **L** (the `toplevel.py`/`subsystem.py`
  surgery is the real cost); M6 **L**; M7 **S**. Total ~**L** spread across 7 reviewable PRs; the
  high-value, low-risk first cut is M1–M4 (registry + adapter source-of-truth) which is ~**M**.

---

## Open questions (could not resolve from the code)

- **Exact LOC reduction for `toplevel.py`/`ahb.py`** is an estimate; the `_expand_*` and `_build_*`
  methods are interwoven with provenance-comment generation and the xref-wire rewrite map
  (`toplevel.py:86-107`), so some logic will not move cleanly to the adapter. Re-measure after M5.
- **Whether `firmware.py`'s two `SoCAhbBackend.__new__` call sites are truly stateless** — **resolved
  by reading the code** (was open in the digest). The two borrowed leaf methods
  (`_build_initiator_data`, `ahb.py:329-396`; `_compute_effective_address_map`, `ahb.py:513-570`) have
  no `self.` references and don't read `self.top`, so the `dummy.top = self.top` lines at
  `firmware.py:199`/`:448` are dead. M6 extracts them to module-level functions taking only their args.
  Remaining (small) open item: confirm no *other* file reaches into `SoCAhbBackend` for a method that
  *is* stateful before deleting the `__new__` trick — `grep -rn 'SoCAhbBackend.__new__'` currently
  returns only those two `firmware.py` sites.
- **APB protocol shape.** APB targets are handled inside `ahb.py` as an inline `cmsdk_ahb_to_apb`
  bridge + `cmsdk_apb_slave_mux` (`ahb.py:110` region), not via a `protocol_utils` table. Whether APB
  becomes a first-class `Protocol` or stays AHB-backend-internal is undecided; M4 can ship without it
  and revisit in M6.
- **Single-interconnect assumption** in `toplevel.py:_build_interconnect` (uses
  `self.top.interconnects[0]`). This refactor does not fix it; flag for a separate doc if multi-IC at
  the *top* level is ever needed (subsystem ICs already work via the AHB backend's hierarchy walk).
