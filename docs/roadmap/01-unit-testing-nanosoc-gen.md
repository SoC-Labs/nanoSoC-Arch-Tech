# Unit + Golden/Snapshot Test Suite for `nanosoc_gen`

> Stand up a pytest-based unit and golden-file test suite for the `nanosoc_gen` SoC generator (parser → builder → validator → backends), with fast in-memory tiers, deterministic snapshot fixtures of generated RTL/flists/headers, and a CI gate — starting from zero tests today.

## 1. Status & scope

**Status:** Greenfield. There are **no tests** anywhere under `nanosoc_arch_tech/nanosoc_gen/` — confirmed by `find … -name "test_*.py" -o -name "conftest.py"` (empty) and the absence of any `pytest.ini`/`tox.ini`/`setup.cfg`. The only pytest suite in the superproject lives at `python/tests/` and tests the **demo-GUI / device-model**, not the generator (`python/tests/conftest.py` just prepends `python/` to `sys.path`; `python/tests/test_device_model.py` imports `nanosoc_multicore.device_model`).

**In scope:**
- Unit tests for `parser.py`, `builder.py`, `utils.py`, `model.py`, `validator.py` (pure-Python, no EDA tools, sub-second).
- Per-backend artifact tests: parse a small fixture YAML → run one backend → assert on the emitted string / file.
- Golden/snapshot tests for backends whose output is large and stable (toplevel SV, flists, firmware headers/linker, config pkg, discovery YAML, text reports).
- Fixtures: a family of **minimal, self-contained** SoC YAMLs that exercise one feature each, plus a way to point tests at the real `nanosoc_multicore_soc.yaml` as a slow-tier smoke.
- Fast (`unit`) vs slow (`golden`, `tooling`) test tiers, marker-driven.
- Local run instructions + a CI job design that plugs into the existing GitLab pipeline (`.gitlab-ci.yml`).

**Out of scope (explicitly):**
- Refactoring the generator (no backend ABC, no registry) — that is [02-clean-architecture-adapters-backends.md](02-clean-architecture-adapters-backends.md). This suite is written **against the code as it is today**, including the per-backend ad-hoc constructor/method signatures.
- RTL functional verification (cocotb/UVM) — that is the `cocotb/`+`uvm/` world and the testbench-generation roadmap [04-testbench-generation-default-tests.md](04-testbench-generation-default-tests.md).
- Validating that generated RTL elaborates in a simulator (that is the lint/compile tier owned by the verification-CI roadmap [03-ci-system-validity-matrix.md](03-ci-system-validity-matrix.md)); we only assert on emitted *text* here. A future `elaborate` tier can be bolted on (see M7).

## 2. Motivation

The generator is the single source of truth for the SoC's RTL, address map, linker scripts, firmware headers, and discovery tables. It is ~437 KB of Python (`soc_model/` source, `__pycache__` excluded) across the 5 core modules (`parser`/`builder`/`model`/`utils`/`validator`) plus `backends/` (17 `.py` files = 16 backends + the shared `protocol_utils.py` helper, alongside the `interfaces/` data subdir), with **zero automated regression coverage**. Today the only safety nets are:
- `python -m soc_model … --validate-only` (semantic checks, but only on the one real 117 KB `nanosoc_multicore_soc.yaml`), and
- whatever a developer notices after a full `make -C sys_desc` + cocotb run.

Concrete failure modes this suite prevents:
- A refactor silently changes a port name, a flist path, or a linker `MEMORY` base. Today nothing catches it until a downstream sim/synth job (minutes-to-hours later, on a different runner) fails with a cryptic elaboration error.
- The well-documented historical bugs in project memory (passthrough HTRANS gating, `cmsdk_ahb_to_apb` `REGISTER_WDATA`, the `_REQUIRED_RTL_PORTS` floating-APB pitfall, the firmware `address_select` `alias`→`0x80000000` boot break) are all things a *golden snapshot of the generated artifact* would have flagged at the point of change.
- The generator has known foot-guns (silent `print("Warning…")` on a missing module/register map returning `{}`/`None`; `last-writer-wins` module-name cache collisions; `eval`-based param expressions). Unit tests pin the current behaviour so a fix is deliberate, not accidental.

**What good looks like:** `pytest -m unit` runs in <5 s with no EDA tools, no network, no submodules; `pytest` (full) runs the golden tier in well under a minute; a one-line CI job (`soc_gen_unit`) gates every MR before the expensive lint/sim/synth stages; and `pytest --snapshot-update` regenerates goldens deterministically so an intended RTL change produces a reviewable diff in the same MR.

## 3. Current state (grounded)

### 3.1 Package layout and entry points
- Package root: `nanosoc_arch_tech/nanosoc_gen/`. `pyproject.toml` declares package name `nanosoc-gen`, `requires-python = ">=3.6"`, deps `jinja2, pyyaml, systemrdl-compiler>=1.29, peakrdl-regblock>=1.2`, console script `soc-model = "soc_model.__main__:main"`, and `[tool.setuptools.packages.find] include = ["soc_model*"]`. There is **no `[tool.pytest.ini_options]`** and **no test/dev dependency group** today.
- The package is `soc_model/` (note: the *distribution* is `nanosoc-gen`, the *import* is `soc_model`). `.gitignore` ignores `__pycache__/`, `*.pyc`, `*.egg-info/`, `dist/`, `build/`, `.eggs/`.

### 3.2 The pipeline (what a test must drive)
`soc_model/__main__.py:main()` is a flat procedural script — there is no pipeline object. The reusable seam for tests is **upstream of the backends**:

```python
# soc_model/__main__.py:82-86
parser  = SoCParser(str(base_dir), [str(d) for d in lib_dirs] if lib_dirs else None)
builder = SoCBuilder(parser)
top_module = builder.build_system(yaml_path.name)   # -> Module
```

- `SoCParser.__init__(self, base_dir, lib_dir=None)` (`parser.py:33`). `parse_top_level(filename)` (`parser.py:50`) is `return self._load_yaml(base_dir/filename)` (`parser.py:53`) — **it does not raise** on a missing/malformed top YAML; `_load_yaml` swallows `FileNotFoundError`/`YAMLError` and returns `{}` (`parser.py:170-181`). This matters for M2's "no `module:`" test: a missing file yields `{}`, and `build_system` then raises `ValueError` because `'module' not in {}` — so to exercise the *no-`module:`-key* path specifically (rather than the missing-file path), the test must point at a real fixture file that has no `module:` key. `parse_module(name)` (`parser.py:55`) lazily scans `lib_dirs` and caches every YAML with a `module:` key **by both `module.name` and filename stem** (`parser.py:101-107`) — last-writer-wins, silent. Missing register map → `print("Warning…")` + `return None` (`parser.py:138`). Missing file → `print("Warning…")` + `return {}` (`parser.py:177`). `_load_yaml` wraps plain `yaml.safe_load`, **no `!include`**, and normalises an empty/None document to `{}` (`parser.py:170-181`).
- `SoCBuilder.build_system(filename)` (`builder.py:23`) raises `ValueError` if no `module:` key, builds the top `Module`, then `_resolve_instances` attaches `inst.resolved_module`. `_built_modules` cache (`builder.py:21,40`) means the same `Module` instance is shared across parents.
- `Module` and friends are plain `@dataclass`es in `model.py` (`Param` `:14`, `Interface` `:59` with `@property width/addr_width/data_width/is_input/is_output`, `Connection` `:104`, …). All construction logic lives in `builder.py` (`.get()`-with-default everywhere → nothing is strictly required to parse).
- `utils.py` has the pure helpers worth unit-testing directly: `resolve_param_ref` (`:8`, handles `"$X"` and arithmetic expr via `_safe_eval` which uses `eval` under a regex whitelist `:41-46`), `parse_bit_slice` (`:62`), `parse_conn_ref` (`:91`), `flatten_params` (`:122`), and the snapshot-critical `write_if_changed` (`:156`) which strips timestamp/copyright lines via `_TIMESTAMP_LINE_RE` (`:137`) before comparing.

### 3.3 Validator (rule-by-rule testable)
`SoCValidator(top_module).validate_all()` (`validator.py:32`) runs six checks in fixed order: `_validate_connections`, `_validate_interconnects`, `_validate_address_overlaps` (`:304`), `_validate_instance_references`, `_validate_known_rtl_modules` (`:461`, driven by the magic dict `_REQUIRED_RTL_PORTS` `:457`), `_validate_driver_coverage` (`:336`). Output is `List[ValidationMessage]` (`:11`, fields `level/category/instance/port/message`); `errors`/`warnings` are filtered `@property` (`:43-49`). This is a clean target: build a tiny `Module`, run one check, assert on the message list.

### 3.4 Backends (heterogeneous — each test must know its own signature)
There is **no base class and no uniform contract** (the one exception is `SoCSubsystemBackend(SoCTopLevelBackend)`). Confirmed signatures a test harness must encode:

| Backend | Construct | Entry call | Returns |
|---|---|---|---|
| `SoCTopLevelBackend` | `(top_module)` | `.generate(rtl_dir, flist_dir=None)` `toplevel.py:48` | `Optional[Path]` |
| `SoCSubsystemBackend` | `(subsystem_module)` `subsystem.py:34` (extends `SoCTopLevelBackend`) | **classmethod entry** `SoCSubsystemBackend.generate_all(top_module, build_dir)` `subsystem.py:466` (constructs per-subsystem instances internally) | `List[Tuple[str,str]]` |
| `SoCFirmwareBackend` | `(top_module)` | `.generate(output_dir)` `firmware.py:41` | (writes files) |
| `SoCDiscoveryBackend` | `(top_module)` | `.generate(build_dir)` `discovery.py:114` | `List[Tuple[str,RegisterMap,Path]]` |
| `SoCAhbBackend` | `(top_module, arm_ip_library_path=…)` `ahb.py:160` | `.generate_all(build_dir, hierarchy_prefix='')` `ahb.py:164` | `List[Tuple[str,str]]` |
| `SoCConfigPkgBackend` | `(top_module)` | `.generate(rtl_dir, flist_dir=None, config_overrides=None)` `soc_config_pkg.py:100-101` (test glue must pass `flist_dir`) | `Optional[Path]` |
| `SoCTextBackend` | `(top_module)` | `.generate_memory_map(path)`, `.generate_hierarchy(path)` | (writes files) |
| others (`html/python/sram/docs/rdl/build_info/system/chip/lint`) | `(top_module)` mostly | vary | vary |

Two hard external-tool dependencies a test must isolate:
- **AHB backend shells out to perl** (`ahb.py:284 'perl', str(build_script)`, `subprocess.run(... timeout=120)` `:297-303`) using `BuildBusMatrix.pl` from `ARM_IP_LIBRARY_PATH`; it **warns and skips** when the env var is unset (`ahb.py:269`) — so its *non-perl* artifacts (XML, the `.sv`/`.flist` Jinja outputs, config pkg) are still produced and testable, but the bus-matrix RTL is not.
- **RDL backend** (`rdl.py`) calls `systemrdl-compiler` + `peakrdl-regblock` for RTL emission, but emits the `.rdl` text itself directly; the `.rdl` is testable without the RTL toolchain.
- Several backends silently no-op if `jinja2` is missing (`if Environment is None: return None`), and `docs.py` injects `datetime.now()` (non-reproducible). `write_if_changed` already neutralises timestamp lines for the deterministic ones.

### 3.5 How generation is invoked in the build today
`sys_desc/Makefile` (project root, **not** the legacy `nanosoc_arch_tech/makefile`) drives it: `LIB_DIR_FLAGS := $(foreach d,$(LIB_DIRS),--lib-dir $(d))` (`:71`), runs `python -m soc_model nanosoc_multicore_soc.yaml $(LIB_DIR_FLAGS) $(PARAM_OVERRIDES) --build-dir …` then pipes generated files through `scripts/patch_ahb_to_apb.py` (`:114`). The `soc_model_fpga` target passes `PARAM_OVERRIDES="--config-override CC_IMEM_RAM_ADDR_W=14 …"` (`:172`). **Note for tests:** the post-`patch_ahb_to_apb.py` step is *outside* the generator; our golden snapshots capture the generator's **raw** output (pre-patch), which is what `nanosoc_gen` is actually responsible for.

## 4. Proposed design

### 4.1 Principle: test at the model seam, snapshot at the artifact seam
The generator's natural API is `SoCParser → SoCBuilder → Module`, then a backend. Tests should:
- **Unit tier:** build a `Module` (in-memory or from a tiny fixture YAML) and assert on Python state (model fields, validator messages, util return values). No file I/O for the pure ones; `tmp_path` for the rest.
- **Golden tier:** run one backend on one fixture, capture the emitted text, compare against a committed golden file (timestamp/copyright-stripped). A `--snapshot-update` flag rewrites goldens.

```
                 fast (-m unit, <5s, no tools)        slow (-m golden, <60s)        opt (-m tooling)
                ┌──────────────────────────┐   ┌────────────────────────────┐   ┌──────────────────┐
 fixtures/*.yaml│ parser → builder → Module │   │ Module → backend → text     │   │ Module → AHB(perl)│
   + in-memory  │   ↳ assert model fields   │──▶│   ↳ assert == golden/*.sv   │   │ → BuildBusMatrix  │
   Module factory│  validator → messages    │   │   (write_if_changed-style   │   │ RDL → regblock RTL│
                │   ↳ assert errors/warns   │   │    timestamp stripping)     │   │ (skip if missing) │
                └──────────────────────────┘   └────────────────────────────┘   └──────────────────┘
```

### 4.2 Test framework: pytest
pytest, matching the existing `python/tests/` suite (same runner, same style header `# Copyright 2026, SoC Labs`). Rationale: zero boilerplate fixtures, parametrization for the per-backend matrix, markers for tiers, and `tmp_path` for filesystem-emitting backends. No new framework to learn — but note CI does **not** currently install or run pytest: `.gitlab-ci.yml` has no `pytest` reference anywhere, no global `default:`/`before_script:` block, and the existing `python/tests/` suite is **not run by any job**. CI today only `pip install`s the `python/` package (line 174) and `cocotb cocotbext-ahb systemrdl-compiler` (line 176) inside per-job `before_script:` blocks. So the M6 CI job below must add `pytest` (via the `[test]` extra) itself; the framework choice is justified by parity with `python/tests/`, not by any pre-existing pytest install.

### 4.3 Layout under `nanosoc_gen`
```
nanosoc_gen/
  pyproject.toml                 # + [tool.pytest.ini_options], + [project.optional-dependencies] test
  tests/
    conftest.py                  # sys.path shim, shared fixtures, --snapshot-update flag, markers
    helpers.py                   # build_module_from_yaml(), build_module_inline(), strip_generated()
    fixtures/
      minimal_soc.yaml           # 1 region behind 1 gen:True interconnect — smallest valid SoC
      two_region_soc.yaml        # exercises address map + 2 targets + 1 initiator visibility
      apb_bridge_soc.yaml        # exercises AHB→APB target (protocol: apb, apb_config)
      passthrough_soc.yaml       # exercises EXCLUDE:[hready] initiator-boundary heuristic
      firmware_soc.yaml          # firmware: linker_profiles + build_info
      regions/                   # tiny self-contained region modules referenced by the above
        tiny_region.yaml
        tiny_apb_periph.yaml
      register_maps/
        tiny_regs.yaml
    unit/
      test_utils.py              # resolve_param_ref, parse_bit_slice, parse_conn_ref, write_if_changed
      test_parser.py             # discovery, name/stem caching collision, missing-file warnings
      test_builder.py            # Module construction, instance resolution, param passthrough
      test_validator.py          # one test class per rule
    golden/
      test_toplevel_sv.py
      test_flists.py
      test_firmware.py
      test_config_pkg.py
      test_discovery_yaml.py
      test_text_reports.py
      __snapshots__/             # committed golden artifacts, one subdir per fixture
        minimal_soc/
          minimal_soc.sv
          minimal_soc_toplevel.flist
          ...
    tooling/
      test_ahb_perl.py           # @pytest.mark.tooling: only runs if ARM_IP_LIBRARY_PATH + perl present
      test_rdl_regblock.py       # @pytest.mark.tooling: only if peakrdl-regblock importable
    slow/
      test_real_soc_smoke.py     # @pytest.mark.slow: drive the real nanosoc_multicore_soc.yaml end-to-end
```

### 4.4 The snapshot mechanism (build it, don't add a plugin dependency)
Rather than pull in `syrupy`/`pytest-snapshot`, implement a ~30-line `assert_matches_snapshot()` in `helpers.py` that reuses the generator's own timestamp-stripping logic. This keeps the dependency surface minimal (CI already has pyyaml/jinja2) and makes golden comparison *identical* to the `write_if_changed` semantics the generator uses, so a golden that passes here is byte-stable in a real build.

```python
# tests/helpers.py
from soc_model.utils import _strip_timestamps   # reuse the generator's own normalisation

def assert_matches_snapshot(actual: str, snap_path, request):
    """Compare `actual` to the committed golden at snap_path, timestamps stripped.
    With --snapshot-update, (re)write the golden and pass."""
    snap_path = Path(snap_path)
    if request.config.getoption("--snapshot-update"):
        snap_path.parent.mkdir(parents=True, exist_ok=True)
        snap_path.write_text(actual)
        return
    assert snap_path.exists(), f"missing golden {snap_path}; run pytest --snapshot-update"
    assert _strip_timestamps(actual) == _strip_timestamps(snap_path.read_text()), \
        f"output drift vs {snap_path}; review diff or run --snapshot-update"
```

### 4.5 Fixtures: minimal, hermetic SoCs
The real `nanosoc_multicore_soc.yaml` needs 8 cross-repo `--lib-dir` paths and all submodules — unusable as a fast fixture. Instead, each fixture is a **single directory** containing the top YAML plus its own `regions/`/`register_maps/`, so `SoCParser(base_dir=fixtures, lib_dir=[fixtures])` resolves everything with no external deps. The minimal valid SoC is one `gen:False` region behind one `gen:True` interconnect — enough to make toplevel/AHB/discovery emit. A `build_module_from_yaml(name)` helper centralises construction; a `build_module_inline(...)` helper constructs a `Module` directly from dataclasses for validator unit tests that need a precise malformed shape.

## 5. Implementation plan

Each milestone is independently shippable (own PR, own green CI) and additive — no generator source changes except the `pyproject.toml` test config in M1.

### M1 — Test harness + utils unit tests (the foundation)
- **Changes:** Add `tests/` tree skeleton, `tests/conftest.py` (sys.path shim like `python/tests/conftest.py`, register `unit`/`golden`/`tooling`/`slow` markers, add `--snapshot-update` option), `tests/helpers.py` (`assert_matches_snapshot`, `build_module_inline`). Add `[tool.pytest.ini_options]` and a `test` optional-dependency group to `pyproject.toml`. Write `tests/unit/test_utils.py`.
- **Why first:** establishes the runnable seam and CI hook with zero dependency on fixtures or backends; `utils.py` is pure and high-value (the `eval`-based `_safe_eval` and `write_if_changed` normalisation both deserve pinning).
- **Acceptance:** `cd nanosoc_gen && pytest -m unit tests/unit/test_utils.py` passes; covers `resolve_param_ref` (`"$X"`, arithmetic `"2 ** $N"`, unresolved-`$` passthrough), `parse_bit_slice`/`parse_conn_ref` (the docstring examples become assertions), `flatten_params`, `write_if_changed` (no-rewrite when only timestamp lines differ).

### M2 — Fixtures + parser/builder unit tests
- **Changes:** Add `tests/fixtures/minimal_soc.yaml` + `two_region_soc.yaml` + their `regions/`/`register_maps/`; `build_module_from_yaml` helper; `tests/unit/test_parser.py` and `tests/unit/test_builder.py`.
- **Why:** locks the parse/build seam every backend depends on; pins the silent foot-guns (name-vs-stem caching, last-writer-wins collision, missing-module→`None`, missing-register-map→`None`+warning).
- **Acceptance:** `pytest -m unit tests/unit/test_parser.py tests/unit/test_builder.py` passes. Asserts: `build_system` raises `ValueError` on no-`module:`; `parse_module` returns the cached dict by both name and stem; a duplicate `module.name` across two fixture files resolves last-writer-wins (documents current behaviour); instance `resolved_module` is attached; `$PARAM` passthrough into a child instance resolves; `Interface.width/addr_width/data_width` properties return expected values for the fixture's ports.

### M3 — Validator unit tests (one class per rule)
- **Changes:** `tests/unit/test_validator.py`, using `build_module_inline` to construct targeted malformed models.
- **Why:** the validator is the cheapest real safety net and the easiest to regress when rules are added (each rule is hand-wired into `validate_all`); these tests are the contract for [02-clean-architecture-adapters-backends.md](02-clean-architecture-adapters-backends.md) if/when checks get a registry.
- **Acceptance:** `pytest -m unit tests/unit/test_validator.py` passes with one test per check: width mismatch → error; direction conflict → error/warn; interconnect→undefined-target → error; address overlap (`_validate_address_overlaps`) → error on two overlapping targets, no error when adjacent; unresolved instance ref → warning; `_REQUIRED_RTL_PORTS` (`cmsdk_ahb_to_apb` missing `PCLKEN/PREADY/PSLVERR`) → error; driver coverage C1 (undriven top output) → error and C2 (dangling wire) → warning.

### M4 — Golden snapshots: toplevel SV + flists
- **Changes:** `tests/golden/test_toplevel_sv.py`, `tests/golden/test_flists.py`, committed `tests/golden/__snapshots__/<fixture>/` artifacts (generated via `--snapshot-update`, then **hand-reviewed before commit**).
- **Why:** the toplevel SV + flist are the largest, most-coupled, most-regression-prone artifacts (single-interconnect `[0]` assumption, passthrough boundary heuristic, HTRANS tie-offs). A golden diff is the fastest way to catch an unintended structural change.
- **Acceptance:** `pytest -m golden tests/golden/test_toplevel_sv.py tests/golden/test_flists.py` passes against committed goldens; a deliberate edit to `minimal_soc.yaml` (e.g. add a port) produces a failing test whose diff is the new port, and `--snapshot-update` makes it pass.

### M5 — Golden snapshots: firmware + config pkg + discovery + text
- **Changes:** `tests/golden/test_firmware.py` (linker `*_memory.ld` MEMORY blocks, `*_memmap.h`, `*_memmap.mk/.cmake`, `*_adp.{vh,py}` from `firmware_soc.yaml`), `test_config_pkg.py`, `test_discovery_yaml.py` (the discovery `.yaml` is the contract the demo-GUI `device_model.py` consumes), `test_text_reports.py` (memory_map.txt / hierarchy.txt).
- **Why:** these artifacts feed firmware builds (linker bases, the `<TOP_NAME_UPPER>_SYS_CLK_FREQ_HZ` config macro — the prefix is `self.top.name.upper()`, `firmware.py:564-575`, so for fixture `minimal_soc.yaml` the macro is `MINIMAL_SOC_SYS_CLK_FREQ_HZ`, **not** a hard-coded `NANOSOC_` prefix; the golden-test author must derive the prefix from the fixture's top name) and the GUI; a silent change here is a downstream boot/build break (cf. the `alias→0x80000000` boot bug in project memory).
- **Acceptance:** `pytest -m golden` (full golden tier) passes; firmware test asserts the linker `MEMORY` base/length for the fixture's regions matches the golden exactly.

### M6 — CI integration
- **Changes:** add a `soc_gen_unit` job to `.gitlab-ci.yml` in the existing **lint** stage (runs after `soc_gen`, before sim/synth), no special runner tag (pure Python). Add a `make test`/`make test-fast` convenience target under `nanosoc_gen` (or `sys_desc/Makefile`).
- **Why:** make the suite a gate, not an afterthought; fail fast (seconds) before the minutes/hours EDA stages. Because no pipeline currently installs pytest (see §4.2), this job is self-contained: it `pip install`s the `[test]` extra in its own `before_script`/`script` rather than relying on any global setup.
- **Acceptance:** the job runs `pip install -e nanosoc_arch_tech/nanosoc_gen[test] && pytest -m "unit or golden" nanosoc_arch_tech/nanosoc_gen/tests` and goes red on an introduced regression; JUnit XML is emitted and surfaced in the MR.

### M7 — Optional tooling + slow tiers (deferred, opt-in)
- **Changes:** `tests/tooling/test_ahb_perl.py` (skip unless `ARM_IP_LIBRARY_PATH` set and `perl`/`BuildBusMatrix.pl` resolvable), `tests/tooling/test_rdl_regblock.py` (skip unless `peakrdl_regblock` importable), `tests/slow/test_real_soc_smoke.py` (drive the real `nanosoc_multicore_soc.yaml` if submodules present, `--validate-only` parity + artifact-existence assertions).
- **Why:** covers the perl/regblock paths and a real-config smoke without making the fast tier depend on EDA tooling.
- **Acceptance:** `pytest -m tooling` passes on an EDA host and **skips cleanly** (not fails) on a laptop; `pytest -m slow` passes when submodules are initialised, skips otherwise.

## 6. File & module changes

### New: `nanosoc_gen/tests/conftest.py`
```python
# Copyright 2026, SoC Labs (www.soclabs.org)
import sys
from pathlib import Path
import pytest

# Import `soc_model` without an install (nanosoc_gen/ on sys.path), mirroring
# python/tests/conftest.py.
_PKG_ROOT = Path(__file__).resolve().parents[1]   # nanosoc_gen/
sys.path.insert(0, str(_PKG_ROOT))

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SNAPSHOTS = Path(__file__).resolve().parent / "golden" / "__snapshots__"


def pytest_addoption(parser):
    parser.addoption("--snapshot-update", action="store_true", default=False,
                     help="Rewrite golden snapshot files instead of asserting.")


def pytest_configure(config):
    for m in ("unit", "golden", "tooling", "slow"):
        config.addinivalue_line("markers", f"{m}: {m}-tier test")


@pytest.fixture
def fixtures_dir():
    return FIXTURES
```

### New: `nanosoc_gen/tests/helpers.py`
```python
from pathlib import Path
from soc_model.parser import SoCParser
from soc_model.builder import SoCBuilder
from soc_model.utils import _strip_timestamps  # reuse generator normalisation

def build_module_from_yaml(base_dir, top_yaml, lib_dirs=None):
    parser = SoCParser(str(base_dir), [str(d) for d in (lib_dirs or [base_dir])])
    return SoCBuilder(parser).build_system(top_yaml)

def assert_matches_snapshot(actual: str, snap_path, request):
    ...  # as in §4.4
```

### New: `nanosoc_gen/tests/golden/test_toplevel_sv.py` (illustrative)
```python
import pytest
from soc_model.backends.toplevel import SoCTopLevelBackend
from .conftest import SNAPSHOTS                # or import via helpers
from ..helpers import build_module_from_yaml, assert_matches_snapshot

pytestmark = pytest.mark.golden

@pytest.mark.parametrize("fixture", ["minimal_soc", "two_region_soc", "passthrough_soc"])
def test_toplevel_sv(fixture, fixtures_dir, tmp_path, request):
    top = build_module_from_yaml(fixtures_dir, f"{fixture}.yaml")
    out = SoCTopLevelBackend(top).generate(tmp_path, tmp_path)   # writes <top.name>.sv
    sv = (tmp_path / f"{top.name}.sv").read_text()
    assert_matches_snapshot(sv, SNAPSHOTS / fixture / f"{top.name}.sv", request)
```

### New: `nanosoc_gen/tests/unit/test_validator.py` (illustrative)
```python
import pytest
from soc_model.model import Module, Interconnect, InterconnectTarget
from soc_model.validator import SoCValidator
pytestmark = pytest.mark.unit

def test_address_overlap_flagged():
    top = Module(name="t")
    ic = Interconnect(name="t_interconnect", gen=True)
    ic.targets = [InterconnectTarget(name="a", base=0x0, size=0x1000),
                  InterconnectTarget(name="b", base=0x800, size=0x1000)]
    top.interconnects = [ic]
    msgs = SoCValidator(top).validate_all()
    assert any(m.category == "address" and m.level == "error" for m in msgs)
```
*The ctor kwargs used here are verified against `model.py`: `Interconnect(name, gen=True, …)` (`model.py:193`) and `InterconnectTarget(name, instance=None, base=0, size=0, …)` (`model.py:154-170`); the assertion's `category == "address"` / `level == "error"` match `_validate_address_overlaps` exactly (`validator.py:304-323`). The isolation this test relies on is real: every other list field on `Module` defaults to empty (`model.py:370-382` — `instances`, `interfaces`, `connections`, `srams`, …), so with only `interconnects` populated the other five checks (`_validate_connections`/`_validate_interconnects`/`_validate_instance_references`/`_validate_known_rtl_modules`/`_validate_driver_coverage`) all iterate over empty lists and emit nothing — the address-overlap assertion is therefore the only signal. The remaining empirical confirmation needed at implementation time is for the **richer malformed shapes** in §3.3's other rules (e.g. a width-mismatch `Connection` or an `Instance` whose `resolved_module` is unset), not for this minimal address-overlap case.*

### Modified: `nanosoc_gen/pyproject.toml`
```toml
[project.optional-dependencies]
test = ["pytest>=7"]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = [
  "unit: fast pure-Python tests (no EDA tools)",
  "golden: snapshot tests of generated artifacts",
  "tooling: tests requiring perl/BuildBusMatrix or peakrdl-regblock",
  "slow: tests driving the real multicore SoC YAML / submodules",
]
addopts = "-m 'not tooling and not slow'"   # default run = unit + golden
```

### Modified: `.gitlab-ci.yml` (new job, lint stage)
```yaml
soc_gen_unit:
  stage: lint
  needs: ["soc_gen"]
  script:
    - source set_env.sh
    - pip install -e nanosoc_arch_tech/nanosoc_gen[test]
    - cd nanosoc_arch_tech/nanosoc_gen
    - pytest -m "unit or golden" --junitxml=report.xml
  artifacts:
    when: always
    reports: { junit: nanosoc_arch_tech/nanosoc_gen/report.xml }
```

### Optional: `nanosoc_gen/Makefile` (or a target in `sys_desc/Makefile`)
```make
test-fast:   ; pytest -m unit
test:        ; pytest -m "unit or golden"
test-update: ; pytest -m golden --snapshot-update
```

## 7. Testing & validation

- **M1–M3 (unit):** self-validating — the tests *are* the deliverable. `pytest -m unit` must be green and run in <5 s with `jinja2`/`pyyaml`/`peakrdl` *uninstalled* for the pure-`utils`/`parser`/`builder`/`validator` subset (they import only `soc_model.{utils,parser,builder,model,validator}`; note `validator.py` imports `backends.protocol_utils` `:8`, which is pure-Python with no jinja2 — safe).
- **M4–M5 (golden):** prove the mechanism by mutating a fixture and confirming (a) the test fails with a readable diff, (b) `--snapshot-update` makes it pass, (c) reverting the fixture + golden returns to green. Goldens are reviewed in the PR like any other source.
- **M6 (CI):** demonstrate the gate by pushing a branch with a deliberate generator regression (e.g. rename a port in `toplevel.py`) and showing `soc_gen_unit` red **before** the lint/sim/synth stages run.
- **M7 (tooling/slow):** on an EDA host, `pytest -m tooling` exercises perl/regblock; on a laptop it must `SKIP`, not `FAIL` (assert skip reasons in the job log).

**Interaction with other CI:** this suite is the cheapest tier of the verification-CI "validity gradient" — it sits *below* the existing `--validate-only` semantic gate and the lint/compile/sim tiers. The slow tier's `--validate-only` parity check overlaps with `make -C sys_desc validate`; keep them complementary (unit suite tests the *rules*; the Makefile target tests the *real config*). See [03-ci-system-validity-matrix.md](03-ci-system-validity-matrix.md) for the full gradient and the config-matrix sweep that would call `pytest -m unit` per swept config.

## 8. Risks, tradeoffs, alternatives considered

- **Golden brittleness / churn.** Snapshots fail on *any* output change, including intended ones. Mitigated by: timestamp/copyright stripping (reusing `_strip_timestamps`), keeping fixtures minimal (small diffs), and `--snapshot-update` making intended updates a one-command, reviewable diff. Tradeoff accepted: a noisy-but-visible diff beats a silent downstream break.
- **Coupling to current heterogeneous backend signatures.** Each golden test hard-codes a backend's ctor/method shape; the planned refactor ([02-clean-architecture-adapters-backends.md](02-clean-architecture-adapters-backends.md)) will change those. This is *intended* — the suite is the safety net that makes that refactor safe; only the thin test glue changes, the goldens stay. Don't over-abstract the test harness ahead of the refactor.
- **`html.py` / `docs.py` non-determinism.** `docs.py` uses `datetime.now()`; `html.py` is a 110 KB f-string. Decision: **do not** golden the HTML (too large, low signal) and either skip docs goldens or strip the date line. The high-value goldens are SV/flist/firmware/discovery/config-pkg.
- **AHB perl dependency.** The full bus-matrix RTL needs `BuildBusMatrix.pl` + `ARM_IP_LIBRARY_PATH` (read-only IP tree — must never be written by tests). Kept in the opt-in `tooling` tier with skip-if-absent; the AHB backend's Jinja/XML outputs are still golden-able in the default tier because the backend warns-and-continues when perl is missing (`ahb.py:269`).
- **Fixture drift from reality.** Minimal fixtures may not exercise a real-SoC corner (e.g. multi-interconnect, which `toplevel._build_interconnect` assumes is `[0]`). Mitigated by the M7 slow tier driving the real YAML. Honest limitation: the slow tier needs initialised submodules, so it won't run everywhere.
- **Alternatives considered:** (a) a snapshot plugin (`syrupy`/`pytest-snapshot`) — rejected to avoid a new CI dependency and to reuse the generator's exact normalisation; (b) testing only via the `--validate-only` CLI — rejected as too coarse (no per-backend artifact coverage); (c) golden-testing the *patched* output (post `patch_ahb_to_apb.py`) — rejected because that patch is outside `nanosoc_gen`'s responsibility and would couple the suite to a project-side script.

## 9. Dependencies & sequencing

- **Builds on:** nothing — this is the foundation roadmap doc and the natural first thing to land, because it de-risks every other generator change.
- **Unblocks / is depended on by:** [02-clean-architecture-adapters-backends.md](02-clean-architecture-adapters-backends.md) (the backend-ABC/registry refactor is far safer with goldens in place); any YAML-format simplification work ([05-simplified-yaml-format.md](05-simplified-yaml-format.md) — a `uses:`/auto-base pre-pass must keep goldens stable); the testbench-generation [04-testbench-generation-default-tests.md](04-testbench-generation-default-tests.md) and FPGA/BD-backend roadmaps [07-toplevel-wrapper-generation-fpga-asic.md](07-toplevel-wrapper-generation-fpga-asic.md) / [08-vivado-block-diagram-generation.md](08-vivado-block-diagram-generation.md) (new backends drop straight into the per-backend test+golden pattern); and the verification-CI config-matrix sweep [03-ci-system-validity-matrix.md](03-ci-system-validity-matrix.md) (reuses `pytest -m unit` as the cheap per-config gate).
- **Effort estimate:** **M** overall. M1 (S), M2 (S–M, fixtures take care), M3 (M, one test per rule), M4 (M, first goldens + review), M5 (S–M), M6 (S), M7 (S, opt-in). A focused engineer lands M1–M3 in ~1–2 days, M4–M6 in ~2–3 days.

---

### Open questions (could not fully resolve from code)
- **Exact ctor kwargs for `InterconnectTarget`/`Interconnect`/`Interface` in `build_module_inline`** — `model.py:154,193,59` use dataclass defaults, but the precise field set for a *valid* minimal model (what the validator/backends require to not crash) must be confirmed empirically while writing M2/M3. The fixture-YAML path (M2) sidesteps this by going through `SoCBuilder`, which is the safer default for golden tests.
- **Python version for the suite.** The two declared floors are: `nanosoc_gen/pyproject.toml` `requires-python = ">=3.6"`, and `sys_desc/Makefile:53` comments `>=3.7` (dataclasses). The demo-GUI package also declares only `>=3.6` (`python/setup.py:12`) — there is **no `>=3.9` requirement anywhere** in `python/`, and **no cocotb Makefile pins `python3.8`** (the cocotb env invokes `python3` generically — `grep -rn python3.8 cocotb/` is empty), so the actual CI-runner interpreter is **not pinned in-repo and must be read off the runner** before pinning `pytest>=7` (which itself needs ≥3.7). Practically: target whatever `python3` the CI `before_script` blocks already use to `pip install` cocotb/systemrdl-compiler, and assert `pytest>=7` is installable there.
- **Whether `peakrdl-regblock` is reliably importable on the CI runner without the full EDA env** — if yes, the RDL `.rdl` golden could move from `tooling` into the default `golden` tier (the `.rdl` text itself needs no RTL toolchain; only the *RTL emission* needs regblock). Confirm at M5/M7.
- **Should goldens be committed under `tests/golden/__snapshots__/` or generated in CI?** Recommended: commit them (reviewable diffs, offline runs). Confirm this is acceptable repo-size-wise for the minimal fixtures (expected to be small — a few KB of SV/flist each).
