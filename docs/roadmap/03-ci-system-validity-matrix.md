# 03 — CI System-Validity Tests Across a Parameter Range

> Build a CI matrix that sweeps SoC configurations (bus widths, memory sizes, optional subsystems, technology/pin-count targets) and asserts each is *valid* through a cheapest-first ladder: **parse → validate → generate → RTL elaborate/lint → (optional) smoke sim** — reusing the generator's existing `--config-override` plumbing, the existing GitLab pipeline, and the existing per-module lint/cocotb makefiles.

---

## 1. Title & summary

This document specifies a parameter-sweep validity matrix for the `nanosoc_gen` SoC generator. The deliverable is a **config-matrix driver** (`ci/matrix.py`) plus a small set of generator fixes so that overriding a parameter actually changes the generated SoC, plus a new GitLab stage (`gen_matrix`) that fans out one cheap job per configuration and asserts validity at the lowest tier that the runner can afford.

The core insight from grounding the design in the code (see §4) is that **the sweep mechanism is mostly broken today**: `--config-override` only reaches one backend (`SoCConfigPkgBackend`), and even there only for a hard-coded whitelist (`_DESIGN_PARAMS`), so most "swept" parameters have *no effect* on the generated RTL/memmap. The first milestone is therefore a correctness fix, not new infrastructure.

> **Path convention (read first).** This doc lives in the **`nanosoc_arch_tech` submodule** (`nanosoc_arch_tech/docs/roadmap/`), but the generator (`nanosoc_gen/`) is the *only* CI-relevant tree inside that submodule. **Every other path cited here is relative to the *superproject* root** (`/home/dam1n19/SoCLabs/temp/nanosoc-multicore-system/`), where the build/CI lives: `sys_desc/Makefile`, `sys_desc/nanosoc_multicore_soc.yaml`, `.gitlab-ci.yml`, `ci/`, `lint/Makefile`, `cocotb/Makefile`, `scripts/`. The submodule-internal trees are written with the explicit `nanosoc_arch_tech/` prefix: `nanosoc_arch_tech/nanosoc_gen/...` (the Python generator: `soc_model/__main__.py`, `validator.py`, `builder.py`, `backends/*`) and `nanosoc_arch_tech/sys_desc/{regions,subsystems,register_maps}/` (the included YAML libraries — note there is **no** `Makefile`, `ci/`, `lint/`, or top-level `nanosoc_multicore_soc.yaml` *inside* the submodule). All new files this doc proposes (`ci/matrix.py`, `ci/matrix.yaml`, `ci/test_matrix_smoke.py`) land in the **superproject `ci/`**. Run all commands from the superproject root unless prefixed otherwise.

---

## 2. Status & scope

**Status:** Greenfield driver + targeted generator fixes. Extends the existing GitLab CI (`.gitlab-ci.yml`) rather than replacing it.

**In scope:**

- A reusable **validity-tier ladder** runnable per-config: parse, validate, generate, elaborate/lint, optional smoke sim.
- A **config-matrix mechanism**: a YAML/JSON matrix file + a Python driver that loops it, regenerates `build_soc/` per config (into isolated build dirs), runs the appropriate tier, and produces a JUnit + dashboard summary.
- **Fixing `--config-override` so it reaches the model** (currently it only reaches the config package — see §4.2). Without this fix, a width/size sweep is a no-op and the matrix asserts nothing meaningful.
- A new GitLab `gen_matrix` stage that runs Tier-0/1/2 on every config in the matrix on every push, with Tier-3 (elaborate/lint) and Tier-4 (smoke sim) gated to a smaller subset.
- Reuse of the existing per-`MODULE` lint flow (`lint/Makefile lint-each`), the per-env cocotb flow (`cocotb/Makefile regression`), and the existing `ci/` helpers.

**Out of scope:**

- A scalar "num_cores=N" knob. Cores are explicit instances in `sys_desc/nanosoc_multicore_soc.yaml` federated by an interconnect; there is no `num_cores` parameter (verified — §4.3). Adding/removing a core is a YAML-structure edit. The matrix sweeps what the model *can* parameterise today plus what `condition:` already gates; a topology-knob is a separate roadmap item (see `02-clean-architecture-adapters-backends.md`).
- Tech-specific pad/UPF generation. The generator does not emit tech pad files today (see `04-*` if it exists / wrappers research). "Technology" in this matrix means *parameter sets + flist macro selection*, not auto-generated pad rings.
- Formal verification. None exists in the repo; validity here = parse/validate/elaborate/lint/sim.
- Replacing the hand-written per-env cocotb TBs (covered by a TB-generation roadmap doc, not here).

---

## 3. Motivation

### The concrete problem

The generator exposes ~40 parameters in `sys_desc/nanosoc_multicore_soc.yaml` (params block `:118`–`:179`: bus widths `SYS_ADDR_W/SYS_DATA_W/APB_*`, per-region memory widths `ETH_IMEM_RAM_ADDR_W`, `CC_IMEM_RAM_ADDR_W`, `QSPI_FLASH_ADDR_W`, DMA channel counts, the full Cortex-M0 param set, identity numbers). The README and `sys_desc/Makefile` advertise that these are tunable (`soc_model_fpga` passes `--config-override CC_IMEM_RAM_ADDR_W=14 ...`, `sys_desc/Makefile:172`). **But there is no test that any non-default configuration is still valid.** CI today builds exactly one configuration (the YAML defaults) once per pipeline (`soc_gen` job, `.gitlab-ci.yml:97`).

This bites in practice: the existing master YAML carries a cautionary comment that an address comment was "wrong by 4x" (`sys_desc/nanosoc_multicore_soc.yaml`, the `phys_size = 2 ** $N` / `4 * (2 ** $N)` notes). Address arithmetic is hand-computed across two *separate* fields per target: a **literal `size:`** (the fixed decode window) and an optional **`phys_size:`** param-expression (the real backing-store length).

There is an important subtlety the matrix must respect, because it bounds what Tier-1 can catch:

- **What the overlap validator actually checks.** `SoCValidator._validate_address_overlaps` (`nanosoc_arch_tech/nanosoc_gen/soc_model/validator.py:304-323`) computes overlap from the **literal `t.size`** field only — `t1_end = t1.base + t1.size` at `validator.py:312`. It never reads `phys_size`; `grep -c phys_size validator.py` → 0. Top-level interconnect targets carry generous *fixed* windows (e.g. `imem_0 size: 0x08000000`, `qspi_flash_xip size: 0x04000000` — `sys_desc/nanosoc_multicore_soc.yaml:1641-1656` and `nanosoc_arch_tech/sys_desc/subsystems/cpu/nanosoc_ss_cpu_plus.yaml:225-227`). A *width/size override* (e.g. `QSPI_FLASH_ADDR_W`, `CC_IMEM_RAM_ADDR_W`) changes only the `phys_size` *expression* — resolved lazily in the firmware/discovery backends (`backends/firmware.py:237-243`, `backends/discovery.py:239-244`), never during `validate_all()`. So **a pure width sweep will NOT, by itself, trip a Tier-1 overlap error**: it shrinks/grows the backing store inside an unchanged decode window.
- **What a width sweep *does* catch at Tier-1.** Two things still fire for free: (a) a sweep whose `phys_size` **exceeds its decode window** (`phys_size > size`) — a real but currently *un-validated* condition (Tier-1 gap M1.5 below adds this check); and (b) any override that changes a **literal `base:`/`size:`** — which is what a *base/window relayout* sweep (or an axis that overrides those fields) does, and *that* is exactly what `_validate_address_overlaps` catches today. The matrix should therefore drive overlap testing through base/window-relayout configs (Tier-1, free) and treat raw width sweeps as primarily a Tier-2/3 concern (does the resized backing store render and elaborate) plus the new `phys_size > size` Tier-1 guard.

Worse (§4.2): even the one swept config that *is* exercised (`soc_model_fpga`) doesn't change the generated memory map at all, because `--config-override` never reaches the builder/model **and** none of its `CC_*` keys are in `_DESIGN_PARAMS`. So the headline "FPGA-sized variant" silently generates the ASIC-sized memmap (empirically confirmed: with vs. without the `CC_*` override set the firmware output is byte-identical once timestamps are stripped).

### Why now

- The SoC is actively re-parameterised (DMA-250 swap, multicore reset controller, M0→M0+, eth-ss IMEM resized 16KB→64KB). Each of these is a config change made by hand-editing the YAML, with the only safety net being "does the default still elaborate."
- The generator is pure Python and the cheapest tier (parse+validate) runs in seconds with no EDA license. A matrix at Tier-0/1 is essentially free and would have caught several of the historically-recorded address/sizing bugs at edit time.

### What good looks like

```
$ python3 ci/matrix.py --matrix ci/matrix.yaml --tier validate
[  1/12] default                  parse OK  validate OK              (1.8s)
[  2/12] fpga_small               parse OK  validate OK              (1.9s)
[  3/12] relayout_tight_phc       parse OK  validate FAIL (expected) (1.8s)
          [ERROR] (address) <ic>: Address overlap: 'phc_0'
          (0x22000000-0x22FFFFFF) overlaps with 'ipc_mailbox_0' (0x22800000-...)
[  4/12] qspi_phys_overflow       parse OK  validate FAIL (expected) (1.7s)  # phys_size > size (M1.5)
          [ERROR] (address) qspi_flash_xip: phys_size 0x08000000 exceeds decode window size 0x04000000
[  5/12] no_dma                   parse OK  validate OK              (1.7s)
...
12 configs: 12 green (10 pass, 2 expected-fail)   -> ci/matrix_results.xml
```

Both red lines are **`expect_fail` configs** (§5.2): the driver treats them as green *because* they failed exactly as declared — they are the matrix's self-test that the two address checks are live. An MR that *unexpectedly* turns a positive config red shows the same validator message but flips the run to non-zero. Note the two *distinct* address failures the matrix exercises: a **base/window relayout** (`relayout_tight_phc`, a `yaml:` fixture since base/size aren't override-able — §5.2) producing a literal-`size` overlap (`_validate_address_overlaps`, today), and a **width sweep** (`qspi_phys_overflow`) whose `phys_size` overflows its fixed decode window (the new `phys_size > size` Tier-1 guard from M1.5). A raw width sweep that stays *inside* its window is — correctly — not an address error, and is exercised at Tier-2/3 instead (does the resized store render and elaborate).

---

## 4. Current state (grounded)

### 4.1 The validity ladder already exists in pieces

| Tier | What | Mechanism today | Cost |
|---|---|---|---|
| T0 parse | YAML → object model | `SoCBuilder.build_system()` (`builder.py:23`); `__main__.py:85-89` exits 1 on exception | seconds, no license |
| T1 validate | semantic checks | `SoCValidator.validate_all()` (`nanosoc_arch_tech/nanosoc_gen/soc_model/validator.py:32`, dispatch at `:37`): connections, interconnects, **address overlaps** (literal `size:` windows only — `_validate_address_overlaps`, `validator.py:304-323`; does **not** check `phys_size`), instance refs, known-RTL-pitfall ports, driver coverage. `make -C sys_desc validate` → `python -m soc_model … --validate-only` (`sys_desc/Makefile:179`, exits 1 on errors via `__main__.py:116`) | seconds, no license |
| T2 generate | emit RTL/flist/memmap + post-patch | `make -C sys_desc` (`sys_desc/Makefile:102`) runs all backends, then `scripts/patch_ahb_to_apb.py`, then writes linker/memmap wrappers (`:110-157`). **Generated RTL is NOT usable without the patch step.** | seconds–minute, no license |
| T3 elaborate/lint | structural elaboration | `make -C lint lint-each` (`lint/Makefile:133`, Cadence HAL over `STANDALONE_MODULES + CMSDK_MODULES`, per-`MODULE`); `--lint` slang pass (`__main__.py:49`, `backends/lint.py`); `make -C cdc cdc` (SpyGlass) | minutes, **needs xcelium/spyglass license** |
| T4 smoke sim | one boot-to-marker run | `make -C cocotb <env>` (`cocotb/Makefile`, e.g. `soc_smoke`); pass = no `<failure>` in `results.xml` | 10s of minutes, **needs VCS license** |

The ladder maps cleanly onto the existing flow. The matrix driver's job is to run these tiers **per config**, into **isolated build dirs**, and aggregate.

### 4.2 `--config-override` is broken for the model (must fix first)

The CLI parses overrides into a dict (`nanosoc_arch_tech/nanosoc_gen/soc_model/__main__.py:64-71`) but threads them to **exactly one** call site:

```python
# __main__.py:241-244
config_pkg_backend = SoCConfigPkgBackend(top_module)
config_pkg_path = config_pkg_backend.generate(
    rtl_dir, flist_dir, config_overrides=config_overrides,
)
```

And inside that backend the override only applies to a **hard-coded whitelist** `_DESIGN_PARAMS` (`backends/soc_config_pkg.py:30-76`), in the loop at `:125-128`:

```python
for pname in _DESIGN_PARAMS:          # soc_config_pkg.py:125
    if pname in self.top.params:
        value = overrides.get(pname, p.default)   # override applied HERE only (:128)
```

Verified consequences:

- `SoCBuilder.build_system(filename)` takes **no overrides** (`builder.py:23`) — the object model is built purely from YAML defaults. Every other backend (`firmware`, `toplevel`, `ahb` interconnect, `discovery`, `subsystem`) reads `top_module.params` defaults. So even a *whitelisted* override only patches the generated config *package* (`nanosoc_soc_config.svh`); it does **not** change the memory map, interconnect, or any RTL emitted by the other backends.
- `_DESIGN_PARAMS` (`soc_config_pkg.py:30-76`) **does** include several matrix-relevant keys — `SYS_ADDR_W`, `SYS_DATA_W`, `NUMIRQ`, `WICLINES`, `DMAC_0_TYPE` (`grep -n 'SYS_DATA_W\|NUMIRQ\|DMAC_0_TYPE' soc_config_pkg.py`). For these, an override *does* reach the config package today — but still nothing else (see previous bullet), so memmap/RTL are unaffected.
- The `soc_model_fpga` override set is `CC_IMEM_RAM_ADDR_W / CC_DMEM_RAM_ADDR_W / CC_BOOTROM_ADDR_W` (`sys_desc/Makefile:172`). **None of the `CC_`-prefixed top-level knobs appear in `_DESIGN_PARAMS`** (`grep -c 'CC_' soc_config_pkg.py` → 0; only the *bare* per-subsystem `IMEM_RAM_ADDR_W` etc. are whitelisted, and those are not what `soc_model_fpga` passes). So this override set is a **complete no-op**: it changes neither the config package *nor* the memory map. The "FPGA-sized variant" generates the ASIC memmap. **Empirically confirmed**: running the generator with vs. without `--config-override CC_IMEM_RAM_ADDR_W=14 CC_DMEM_RAM_ADDR_W=12 CC_BOOTROM_ADDR_W=11` produces byte-identical firmware output once timestamps are stripped.

This is the load-bearing fix. A width/size matrix is meaningless until overrides reach the model. (M1 below.)

### 4.3 No topology knob; subsystem on/off is `condition:`

Cores are explicit instances (`u_eth_ss_0`, `u_cpu_ss_1`) in the master YAML; there is no `num_cores`. The only data-driven enable/disable today is `condition:` on instances, evaluated against params — and it is used in exactly two places, both DMA-subsystem-internal:

```
nanosoc_arch_tech/sys_desc/subsystems/dma/nanosoc_ss_dma.yaml:85:  condition: "$DMAC_0_TYPE > 0"
nanosoc_arch_tech/sys_desc/subsystems/dma/nanosoc_ss_dma.yaml:93:  condition: "$DMAC_1_TYPE > 0 && $DMAC_0_TYPE != 2"
```

**Critical: `condition:` does NOT drop the instance in Python — it emits a SystemVerilog `generate if`.** The toplevel template wraps a conditioned instance in `generate if ({{ inst.condition }}) begin … end endgenerate` (`nanosoc_arch_tech/nanosoc_gen/soc_model/backends/templates/soc_toplevel.sv.j2:126-127,142-143`), and `inst.condition` is passed through **raw** (`backends/toplevel.py:652`), so the emitted `.sv` literally contains both the `generate if (...)` line and the full instance body even when the condition is false. The instance is pruned only at **RTL elaboration (Tier-3)** — never at generate (Tier-2). Consequence for the matrix: a "subsystem off" config does **not** make the instance text disappear from `build_soc/rtl/*.sv`; a text grep for the instance is the wrong check (see M1 acceptance, corrected below).

Two further caveats verified against the current tree: (a) the `condition:` clauses live inside the *DMA subsystem* YAML, so they gate the DMA's *internal* instances, not the top-level `u_dma_230_0` — which in `sys_desc/nanosoc_multicore_soc.yaml` carries **no** `condition:` at all and is therefore always emitted regardless of `DMAC_0_TYPE`; and (b) `DMAC_0_TYPE` *is* in `_DESIGN_PARAMS`, so an override reaches the config package today, but per §4.2 nothing else, so before M1 it cannot even influence the generate-if expression value.

So "subsystems on/off" in the matrix means **toggling `condition:`-gated params** (where they exist) — which only takes effect once overrides reach the model (M1) **and** is observable only at Tier-3 elaboration, not by inspecting the generated text. The matrix should sweep what's gateable today and flag the topology-knob gap for `02-clean-architecture-adapters-backends.md`.

### 4.4 No generator unit-test suite exists

`nanosoc_arch_tech/nanosoc_gen/tests/` **does not exist** (verified). The "7 generator pytest" mentioned in project memory is not present in this tree. The superproject's `python/tests/test_*.py` are demo-GUI/HAL/device-model tests, not generator-model tests (`python/tests/conftest.py` just puts `python/` on `sys.path`). The matrix therefore **cannot** "reuse a generator unit-test suite" — there isn't one. The cheapest matrix tiers (parse/validate) ARE the de-facto unit tests until a real suite lands (cross-link: the unit-testing roadmap doc). The matrix driver should be structured so its per-config tier functions are importable and could be wrapped by `pytest` later (M5).

### 4.5 Existing CI to extend

`.gitlab-ci.yml` already has the right shape: a `soc_gen` job (`:97`) that regenerates `build_soc/` once and publishes it as an artifact every downstream stage consumes. The matrix slots in **before** lint as a parallel fan-out. Existing reusable helpers: `ci/check_preflight.sh` (tool gate), `ci/generate_dashboard.py`, `scripts/check_firmware_clock.sh`, `scripts/expand_flist.sh`, `scripts/patch_ahb_to_apb.py`. The lint flow is already per-`MODULE` (`lint/Makefile:29`), and `TOP_nanosoc_multicore = nanosoc_multicore_soc` mapping (`:44`) is reusable per config.

---

## 5. Proposed design

### 5.1 Two pieces

```
                       ci/matrix.yaml  (the config grid)
                              │
                              ▼
   ci/matrix.py  ── for each config ──┐
       │                              │
       │  isolated build dir:  build_soc/_mtx/<config_name>/
       │                              │
       ▼                              ▼
   Tier ladder (cheapest first, stop at requested tier or first failure):
     T0 parse      python -m soc_model <yaml> <libdirs> <overrides> --validate-only   (catches parse exception)
     T1 validate   (same call; exit 1 on validator errors)
     T2 generate   python -m soc_model … --build-dir build_soc/_mtx/<name>  + patch_ahb_to_apb.py
     T3 elaborate  make -C lint lint MODULE=nanosoc_multicore  NANOSOC_MULTICORE_HOME=… BUILD=…
                   (or `--lint` slang pass — license-free)
     T4 smoke      make -C cocotb soc_smoke   (gated subset only)
                              │
                              ▼
            ci/matrix_results.xml  (JUnit: one <testcase> per config×tier)
            + console summary  + feeds ci/generate_dashboard.py
```

The driver is a thin orchestrator. It does **not** reimplement the tiers — it shells out to the exact same `python -m soc_model` and `make` invocations CI already uses, with per-config `--config-override` flags and a per-config `--build-dir`. This keeps one source of truth for "how the SoC is built."

### 5.2 The matrix file format

`ci/matrix.yaml` — explicit named configs, each a set of overrides + a target tier + a flist-macro/board hint:

```yaml
# ci/matrix.yaml — SoC configuration validity matrix.
# Each entry generates one isolated build and runs up to `tier`.
# `overrides` map 1:1 onto `--config-override KEY=VALUE` (declared top-level params only).
# `yaml:` (alternative to overrides) points at an edited top-level YAML fixture, used for
#   variations that aren't param-expressible — e.g. base/size relayout (overlap tests).
# `expect_fail: <tier>` marks a negative config; the driver inverts the verdict.
defaults:
  tier: validate            # cheapest tier every config must clear on every push
  libdirs_from: sys_desc    # reuse the LIB_DIRS computed by sys_desc/Makefile

configs:
  - name: default
    desc: "Golden — YAML defaults (matches today's soc_gen job)"
    overrides: {}
    tier: generate          # the default config also elaborates in the gated set

  - name: fpga_small
    desc: "Pynq-Z2 memory budget"
    overrides:
      CC_IMEM_RAM_ADDR_W: 14
      CC_DMEM_RAM_ADDR_W: 12
      CC_BOOTROM_ADDR_W: 11
      ETH_IMEM_RAM_ADDR_W: 14

  - name: wide_data_64b
    desc: "64-bit system data bus"
    overrides: { SYS_DATA_W: 64 }

  - name: relayout_tight_phc
    desc: "Base/window collision (phc_0 into ipc_mailbox_0) — must FAIL Tier-1 overlap"
    # NOTE: interconnect target base/size are LITERAL hex in the YAML, not params
    # (verified: there are no *_BASE/*_SIZE top-level params). A --config-override
    # therefore CANNOT relayout addresses today. This negative config is driven by an
    # edited copy of the top-level YAML, selected via `yaml:` instead of `overrides:`.
    yaml: ci/fixtures/relayout_tight_phc.yaml   # copy of master with phc_0/ipc_mailbox_0 bases collided
    expect_fail: validate

  - name: qspi_phys_fits
    desc: "QSPI phys_size = 64MB exactly fills its decode window (Tier-1 phys_size guard, pass)"
    overrides: { QSPI_FLASH_ADDR_W: 26 }    # 2**26 = 0x04000000 == window size

  - name: qspi_phys_overflow
    desc: "QSPI phys_size 128MB > 64MB window — must FAIL Tier-1 (M1.5 guard)"
    overrides: { QSPI_FLASH_ADDR_W: 27 }    # 2**27 = 0x08000000 > 0x04000000 window
    expect_fail: validate                   # negative config; driver asserts it goes red

  - name: minimal_irq
    desc: "Reduced NVIC lines (NUMIRQ/WICLINES are in _DESIGN_PARAMS)"
    overrides: { NUMIRQ: 16, WICLINES: 18 }

  - name: no_dma
    desc: "DMA condition: gated off — emits generate-if(0); instance pruned at elaborate (Tier-3), NOT removed from .sv text"
    overrides: { DMAC_0_TYPE: 0, DMAC_1_TYPE: 0 }
    tier: elaborate                         # the only tier where 'off' is observable

# Optional axis-expansion sugar: cartesian product of axes -> generated configs.
# Kept separate so the explicit list above stays readable.
axes:
  - name: addr_width_sweep
    base: default
    grid:
      SYS_ADDR_W: [28, 32, 36]
    tier: validate
```

Decisions:

- **Explicit named configs + optional `axes` product.** Pure cartesian explosion is unreadable and produces meaningless combos; a curated list plus a couple of small swept axes is what an engineer actually wants to review in an MR.
- **`tier` per config.** Most configs only need `validate` (free). A handful (the default, the FPGA config) go to `generate`; an even smaller gated set goes to `elaborate`/`smoke`. This is the cost-control lever. Note a `condition:`-gated "off" config (e.g. `no_dma`) is meaningful only at `tier: elaborate` — at Tier-2 the instance is still emitted inside a `generate if (0)` block (§4.3), so a generate-tier run cannot observe the subsystem being absent.
- **`expect_fail: <tier>` for negative configs.** A config may declare the tier at which it is *expected* to fail (e.g. `qspi_phys_overflow` → `expect_fail: validate`). The driver inverts the verdict: such a config is green only if it fails at exactly that tier with an error, and red if it unexpectedly passes (catches regressions that silently disable a check). This keeps the negative tests (overlap, phys_size overflow, bad width) inside the same reviewable matrix file.
- **`overrides:` vs `yaml:` — two ways to vary a config.** `overrides:` map 1:1 onto `--config-override KEY=VALUE` and can only touch **declared top-level params** (bus widths, `*_ADDR_W`, `NUMIRQ`, `DMAC_*_TYPE`, …). Interconnect target **`base:`/`size:` are literal hex in the YAML, not params** (verified — there are no `*_BASE`/`*_SIZE` knobs), so a *base/window relayout* (the only thing that trips `_validate_address_overlaps` today) **cannot** be expressed as an override; such a config points `yaml:` at an edited copy of the top-level description (a small fixture under `ci/fixtures/`). The driver passes whichever is present: `yaml:` → use that file as the top-level; `overrides:` → use the master YAML + `--config-override`. (A future top-level `*_BASE` param knob — a `02-*` dependency — would let these collapse back to `overrides:`.)
- **`libdirs_from: sys_desc`** — the driver fetches the 8 `--lib-dir` paths (`sys_desc/Makefile:61-69`) from one place rather than duplicating them. **Use the dedicated `make -C sys_desc print-libdirs` target (added in M2, §7), not `make -p` parsing.** `LIB_DIRS` is a multi-line recursive-make assignment (`LIB_DIRS := \` with `\` continuations, `sys_desc/Makefile:61-69`); scraping it out of `make -p` database dump is fragile (line-wrapping, `:=` vs `=`, `$(CURDIR)`/`$(SOCLABS_*_DIR)` expansion). The `print-libdirs` target emits one fully-expanded absolute path per line and is the canonical, stable interface.

### 5.3 Isolated build dirs

Each config generates into `build_soc/_mtx/<name>/` (passed as `--build-dir`). This is the key to parallelism and to not clobbering the real `build_soc/` that the main `soc_gen` job + downstream stages depend on. `write_if_changed` (`utils.py:156`) already dedups, but separate dirs are cleaner and let jobs run concurrently.

For T3 (lint), the lint flow keys off `flist/<MODULE>.flist` and `NANOSOC_MULTICORE_HOME` (`lint/Makefile:52,25`). The per-config build dir means the matrix must either (a) point the flist's `build_soc` references at the per-config dir, or (b) for the elaborate tier, copy the per-config `build_soc/_mtx/<name>/` over the canonical `build_soc/` in a throwaway workspace. Option (b) is simpler and is what M3 implements (one lint job per *elaborated* config, each in its own GitLab job workspace).

### 5.4 Failure triage

The driver classifies each failure by **tier** and emits a structured record:

| Tier failed | Likely cause | Where to look |
|---|---|---|
| T0 parse | YAML syntax / missing module / bad `!include` | stderr from `build_system` exception (`__main__.py:88`) |
| T1 validate | width mismatch / **literal-`size` address overlap** / **`phys_size` overflows window** (M1.5) / non-int `phys_size` / undriven output / missing RTL port | the `ValidationMessage` lines (category in the message) |
| T2 generate | jinja2 render error / `patch_ahb_to_apb.py` crash / linker-wrap failure / a `phys_size` expr that throws *before* M1.5 covers it (e.g. nested-subsystem target) | backend traceback or patch-script exit |
| T3 elaborate | RTL doesn't elaborate at this config (port-width drift, X-prop) | HAL `*E` lines (the `report` target greps these, `lint/Makefile:152`) |
| T4 smoke | boot-to-marker timeout / functional regression | cocotb `results.xml` `<failure>` + `run.log` |

The validator already tags `category` (`width|direction|reference|address|connection`, `validator.py:15`), so the JUnit `<failure type=...>` can carry it directly for dashboard grouping.

---

## 6. Implementation plan

### M1 — Make `--config-override` reach the model (CORRECTNESS FIX, blocks all real sweeps)

**What:** Thread `config_overrides` into `SoCBuilder` so overridden params mutate `top_module.params[...].default` before any backend runs. Smallest viable change: apply overrides right after `build_system()` in `__main__.py`, in one place, so *every* backend sees them.

```python
# __main__.py — insert after the build_system() try/except (top_module built at :86,
# the except ends at :89), i.e. right after line 89 and before validation/backends:
for k, v in config_overrides.items():
    if k in top_module.params:
        top_module.params[k].default = v
    else:
        # Param not declared at top level — record, don't silently drop.
        print(f"  WARNING: --config-override {k}={v} not a top-level param; ignored")
```

Then `SoCConfigPkgBackend` keeps its existing `overrides.get(pname, p.default)` (it'll now agree with the model). Optionally drop the redundant override plumbing from the config-pkg call once the model is the source of truth — but keep it for now to avoid a behavioural break (low risk: same value).

**Why:** Without this, width/size/condition sweeps are no-ops (§4.2). This is the precondition for the entire matrix to assert anything.

**What M1 fixes vs. what it does NOT.** Be precise about scope, because the two address concepts are independent (§3, §4.1):

- **M1 fixes:** the param-derived **`phys_size`** chain. With overrides reaching the model, `CC_IMEM_RAM_ADDR_W` → `IMEM_RAM_ADDR_W` (`sys_desc/nanosoc_multicore_soc.yaml:462` → `nanosoc_arch_tech/sys_desc/subsystems/cpu/nanosoc_ss_cpu_plus.yaml:226` `phys_size: "4 * (2 ** $IMEM_RAM_ADDR_W)"`), resolved in `backends/firmware.py:237-243`. So the **linker `MEMORY` `LENGTH`** in the per-profile `firmware/nanosoc_multicore_soc_cc_stage1_imem_memory.ld` and the matching `NanoSoC_REGION_IMEM_0_SIZE` in `firmware/nanosoc_memmap.cmake` (and the other C/CMake memmap headers) genuinely change. (Empirically: today, *without* M1, the firmware output is byte-identical with vs. without the `CC_*` override set; after M1 the `LENGTH` should differ.)
- **M1 does NOT fix:** the **literal `size:` decode window** (`imem_0 size: 0x08000000`), the `memory_map.txt` *window* report, or the **overlap validator** — all of which read the literal `size`, not `phys_size` (`validator.py:312`). A width sweep alone therefore still produces the same decode windows and the same (non-)overlap verdict. Catching a window/overlap problem from a width sweep needs the separate `phys_size > size` guard (M1.5).

**Acceptance check (corrected):** `python3 -m soc_model nanosoc_multicore_soc.yaml … --config-override CC_IMEM_RAM_ADDR_W=14 --build-dir /tmp/a` then `python3 -m soc_model … --build-dir /tmp/b` (no override): the CC IMEM `LENGTH` must differ between builds. The generator does **not** emit a single `nanosoc_memmap.ld`; the per-profile linker file carrying the CC IMEM region is `firmware/nanosoc_multicore_soc_cc_stage1_imem_memory.ld` (line of the form `IMEM_0 (rwx) : ORIGIN = 0x10000000, LENGTH = 0x10000`), and the same size is mirrored in `firmware/nanosoc_memmap.cmake` as `NanoSoC_REGION_IMEM_0_SIZE`. Assert either of those changes between `/tmp/a` and `/tmp/b` (this is the load-bearing check that overrides now reach the model). With `CC_IMEM_RAM_ADDR_W=14`, expect `LENGTH = 0x10000` (4·2¹⁴ = 64K) vs. the default `CC_IMEM_RAM_ADDR_W=15` → `0x20000` (128K). For the `condition:` path, **do NOT** grep the generated `.sv` for instance absence — `DMAC_0_TYPE=0` leaves the instance text inside a `generate if (0)` block (§4.3, `soc_toplevel.sv.j2:126`), so `grep -L u_dma` would *fail to find it absent* even when working correctly. Instead assert the **generate-if expression value flips**: confirm the emitted toplevel contains `generate if (` with the substituted condition resolving false (e.g. the config package now sets `DMAC_0_TYPE = 0`, and the elaborated netlist — Tier-3 — drops the instance). The text-vs-elaboration distinction is settled (no longer an open question; see §4.3). **This milestone is shippable alone** as a generator bug fix independent of any CI work.

### M1.5 — Tier-1 `phys_size` validation (small, makes width sweeps catchable for free)

**What:** Add a validator method `_validate_phys_size_fits(module)` to `SoCValidator` that, for every interconnect target with a `phys_size:` expression, resolves it under the (now override-aware, post-M1) params via `resolve_param_ref` (`nanosoc_arch_tech/nanosoc_gen/soc_model/utils.py:8`) and emits a `category='address'` error if it is **not a positive int** or if it **exceeds the literal decode `size`** (`phys_size > size`). Today no validator method touches `phys_size` at all (`grep -c phys_size validator.py` → 0); the resolution currently lives only in the firmware/discovery backends (`firmware.py:237-243`, `discovery.py:239-244`), which run at Tier-2. M1.5 lifts *just the resolve-and-bounds-check* into `validate_all()` so a bad width is caught at Tier-1 instead of throwing deep in a backend at Tier-2.

```python
# validator.py — new check, called from validate_all()
# Reuses the SAME helpers the firmware backend uses (resolve_param_ref + flat_params),
# so the resolution semantics are identical to Tier-2 — just run earlier.
def _validate_phys_size_fits(self, module):
    params = module.flat_params              # {name: p.default}; same as firmware.py:170
    for ic in module.interconnects:
        for t in ic.targets:
            if not isinstance(t.phys_size, str):   # only param-expression targets
                continue
            try:
                ps = resolve_param_ref(t.phys_size, params)   # utils.py:8 -> _safe_eval
            except Exception as e:
                self.messages.append(ValidationMessage('error', 'address', ic.name,
                    f"phys_size '{t.phys_size}' for '{t.name}' failed to evaluate: {e}"))
                continue
            if not isinstance(ps, (int, float)) or int(ps) <= 0:
                self.messages.append(ValidationMessage('error', 'address', t.name,
                    f"phys_size resolved to {ps!r}, not a positive int"))
            elif int(ps) > t.size:
                self.messages.append(ValidationMessage('error', 'address', t.name,
                    f"phys_size 0x{int(ps):X} exceeds decode window size 0x{t.size:X}"))
```

**Scope caveat (grounded).** `flat_params` is the *top-level* param map (`model.py:401`). The firmware backend resolves nested-subsystem `phys_size` hierarchically through `_stitch_module` (`firmware.py:174,185-194`), substituting each subsystem's instance-param bindings (e.g. top `CC_IMEM_RAM_ADDR_W` → subsystem `IMEM_RAM_ADDR_W`). M1.5's first cut validates the **top-level interconnect targets** (where `qspi_flash_xip`'s `phys_size: "2 ** $QSPI_FLASH_ADDR_W"` already resolves under `flat_params`); validating nested-subsystem targets requires the same flatten chain and is a fast-follow (it can call into the existing `flatten_params`, `utils.py`, used by the firmware backend) — call it out rather than silently miss it.

**Why:** This is what makes a *width* sweep assert something meaningful at the free tier (it is the `qspi_phys_overflow` example in §3). It also pre-empts the `eval`-throws-at-Tier-2 risk (§9) by moving the same resolution forward — without duplicating the *firmware emission*, only the resolve+bounds check. Note this reuses the existing `_safe_eval` (`utils.py:45`, `eval(expr, {"__builtins__": {}})`); M1.5 does not change that, it just calls it earlier.

**Acceptance check:** a config that sets `QSPI_FLASH_ADDR_W: 26` (phys_size 64 MB) against the 64 MB `qspi_flash_xip` window passes; `QSPI_FLASH_ADDR_W: 27` (128 MB) fails Tier-1 with the `phys_size … exceeds decode window` message; a config that drives a `phys_size` to a non-int fails with the resolve message.

### M2 — Standalone matrix driver (Tier 0–2, license-free)

**What:** New `ci/matrix.py` + `ci/matrix.yaml`. The driver:
- loads `ci/matrix.yaml`, expands `axes`,
- resolves LIB_DIRS once via the new `make -C sys_desc print-libdirs` target (§7) — one absolute path per line; avoids fragile `make -p` scraping (§5.2),
- for each config runs T0–T2 (parse/validate via `--validate-only`; generate via `--build-dir build_soc/_mtx/<name>` + `patch_ahb_to_apb.py`),
- writes `ci/matrix_results.xml` (JUnit) and a console table.

**Why:** Delivers the headline value (per-config validity) with zero EDA licenses; runnable on a laptop.

**Acceptance check:** `python3 ci/matrix.py --matrix ci/matrix.yaml --tier validate` returns 0, with the positive configs passing and the **`expect_fail` configs** (`qspi_phys_overflow`, `relayout_tight_phc`) each reported as an *expected* Tier-1 failure (green because they failed as declared). Then flip one negative config's `expect_fail` off (or inject `SYS_ADDR_W: 8`) and confirm the driver now exits non-zero with the validator error surfaced. `ci/matrix_results.xml` parses as valid JUnit.

### M3 — GitLab `gen_matrix` stage

**What:** Add a `gen_matrix` stage to `.gitlab-ci.yml` after `soc_gen`. Two jobs:
- `matrix_validate` (no tags / generic runner): runs `python3 ci/matrix.py --tier validate` over the full matrix. Fast, runs on every push, blocks the pipeline on failure. Emits JUnit.
- `matrix_elaborate` (tag `xcelium`, `allow_failure: true` initially): runs `--tier elaborate` over the gated subset (`tier: elaborate` configs only). One HAL `lint MODULE=nanosoc_multicore` per elaborated config.

```yaml
# .gitlab-ci.yml — new stage between soc_gen and lint
stages: [setup, soc_gen, gen_matrix, lint, ...]

matrix_validate:
  stage: gen_matrix
  needs: [clone, preflight]            # parse/validate needs only the source tree
  script:
    - cd "$WORK_DIR" && source set_env.sh
    - python3 ci/matrix.py --matrix ci/matrix.yaml --tier validate --junit matrix_results.xml
  artifacts:
    when: always
    reports: { junit: matrix_results.xml }
    paths: [matrix_results.xml]
    expire_in: 30 days

matrix_elaborate:
  stage: gen_matrix
  needs: [clone, preflight, soc_gen]
  tags: [xcelium]
  allow_failure: true
  before_script:
    - export PATH="$XCELIUM_HOME/tools/bin:$PATH"
    - export NANOSOC_MULTICORE_HOME="$WORK_DIR"
  script:
    - cd "$WORK_DIR" && source set_env.sh
    - python3 ci/matrix.py --matrix ci/matrix.yaml --tier elaborate --select tier=elaborate
  artifacts:
    when: always
    paths: [build_soc/_mtx/*/matrix_lint_*.log]
    expire_in: 30 days
```

**Why:** Makes the matrix a gate, reusing the existing artifact/JUnit/runner-tag conventions exactly.

**Acceptance check:** A pipeline run shows `matrix_validate` green with N testcases in the JUnit tab; an MR that introduces an overlapping address in a swept config turns `matrix_validate` red with the validator message visible in the GitLab test report.

### M4 — Optional smoke-sim tier (gated, expensive)

**What:** `--tier smoke` runs `make -C cocotb soc_smoke` against the generated per-config RTL for the tiny gated subset (`default`, `fpga_small`). Requires firmware built at the right clock — reuse `scripts/check_firmware_clock.sh` (already called by `cocotb/Makefile regression`). The cocotb env consumes `build_soc/`; the smoke tier copies `build_soc/_mtx/<name>/` → `build_soc/` in the job workspace first.

**Why:** Catches config changes that elaborate but don't *function* (e.g. a memory map that boots to the wrong vector). Cost is high (VCS license, 10s of minutes), so it's the smallest possible subset.

**Acceptance check:** `python3 ci/matrix.py --tier smoke --select name=default` runs `cocotb/soc_smoke` and passes by observing the UART string **`"hello"`** — the actual marker the existing test asserts (`cocotb/soc_smoke/test_soc_smoke.py:6,63,66`: the IMEM-preloaded `hello_uart` app prints `hello` on the CMSDK debug UART and the test asserts `b"hello" in output`). The matrix smoke tier must key off this real marker; do **not** invent a boot string. The `fpga_small` config (after M1 actually resizes the memmap) must also reach `hello`.

### M5 — Promote tier functions to importable + pytest shim

**What:** Refactor `ci/matrix.py` so each tier is a function returning a structured result (`TierResult(name, tier, passed, message, duration)`), and add `ci/test_matrix_smoke.py` (pytest) that runs T0/T1 over the matrix as unit tests. This is the seam where the (currently nonexistent) generator unit-test suite plugs in.

**Why:** Makes parse/validate of every config a `pytest` target, so the matrix doubles as the generator's regression suite until a dedicated `nanosoc_arch_tech/nanosoc_gen/tests/` lands (§4.4). Cross-links the unit-testing roadmap doc.

**Acceptance check:** `pytest ci/test_matrix_smoke.py -v` collects one test per config and passes; a broken config fails the corresponding test with the validator message in the assertion.

### M6 — Caching & incremental skip

**What:** Hash each config's `(yaml mtime set, libdir mtime set, overrides)` into a cache key; skip configs whose inputs are unchanged since the last green run (store a small `ci/.matrix_cache.json`). Wire the GitLab `cache:` block to persist it per ref.

**Why:** Parse/validate is cheap but the elaborate/smoke tiers are not; skip unchanged configs to keep MR turnaround fast.

**Acceptance check:** Re-running `ci/matrix.py` with no source changes reports all configs `CACHED (skipped)` in <1s; touching `nanosoc_multicore_soc.yaml` invalidates all.

---

## 7. File & module changes

### New files

**`ci/matrix.yaml`** — the config grid (format in §5.2).

**`ci/matrix.py`** — the driver. Sketch of the public shape:

```python
#!/usr/bin/env python3
"""Sweep SoC configurations and assert validity tier-by-tier."""
import argparse, dataclasses, json, subprocess, sys, time, xml.etree.ElementTree as ET
from pathlib import Path
import yaml

TIERS = ["parse", "validate", "generate", "elaborate", "smoke"]

@dataclasses.dataclass
class TierResult:
    config: str
    tier: str
    passed: bool
    message: str = ""
    duration: float = 0.0

def _soc_model_cmd(yaml_path, libdirs, overrides, build_dir=None, validate_only=False):
    cmd = ["python3", "-m", "soc_model", str(yaml_path)]
    for d in libdirs:
        cmd += ["--lib-dir", d]
    for k, v in overrides.items():
        cmd += ["--config-override", f"{k}={v}"]
    if validate_only:
        cmd.append("--validate-only")
    if build_dir:
        cmd += ["--build-dir", str(build_dir)]
    return cmd

def run_validate(cfg, ctx) -> TierResult:
    # T0 parse + T1 validate share one --validate-only invocation
    t0 = time.time()
    cmd = _soc_model_cmd(ctx.yaml, ctx.libdirs, cfg["overrides"], validate_only=True)
    p = subprocess.run(cmd, cwd=ctx.gen_dir, capture_output=True, text=True)
    ok = (p.returncode == 0)
    # Extract validator ERROR lines for the failure message / triage category
    errs = [l for l in p.stdout.splitlines() if "[ERROR]" in l]
    return TierResult(cfg["name"], "validate", ok,
                      "\n".join(errs) or p.stderr[-400:], time.time() - t0)

def run_generate(cfg, ctx) -> TierResult: ...      # --build-dir + patch_ahb_to_apb.py
def run_elaborate(cfg, ctx) -> TierResult: ...     # make -C lint lint MODULE=...
def run_smoke(cfg, ctx) -> TierResult: ...         # make -C cocotb soc_smoke

def write_junit(results, path): ...                # one <testcase> per config

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", default="ci/matrix.yaml")
    ap.add_argument("--tier", choices=TIERS, default="validate")
    ap.add_argument("--select", default=None, help="filter e.g. name=default or tier=elaborate")
    ap.add_argument("--junit", default="ci/matrix_results.xml")
    ...
```

The tier functions are the importable seam for M5's pytest.

**`ci/test_matrix_smoke.py`** (M5) — `pytest.mark.parametrize` over the matrix configs, calling `run_validate`.

### Modified files

**`nanosoc_arch_tech/nanosoc_gen/soc_model/__main__.py`** — M1: apply `config_overrides` to `top_module.params[*].default` after `build_system()` (snippet in M1). Add a `WARNING` for unknown override keys (today they're silently dropped unless they happen to be in `_DESIGN_PARAMS`).

**`nanosoc_arch_tech/nanosoc_gen/soc_model/validator.py`** — M1.5: add `_validate_phys_size_fits(module)` (snippet in M1.5) and call it from `validate_all()` (`validator.py:32`); it reuses `resolve_param_ref` (`utils.py:8`) and `module.flat_params` (`model.py:401`) so its resolution matches the firmware backend exactly. Emits `category='address'` errors so the existing JUnit/dashboard grouping (§5.4) picks them up unchanged.

**`sys_desc/Makefile`** — add a `print-libdirs` target so the driver can fetch the canonical LIB_DIRS without duplicating the list:

```makefile
.PHONY: print-libdirs
print-libdirs:
	@$(foreach d,$(LIB_DIRS),echo $(d);)
```

Also fix the misleading `soc_model_fpga` comment (`sys_desc/Makefile:165-167`), which today claims "`--config-override` tunes the generated memory map / linker scripts" — that is **false until M1** (the `CC_*` keys reach nothing; §4.2). Either correct the comment to say the override is a no-op pending M1, or land M1 first and make the comment true.

**`.gitlab-ci.yml`** — M3: add `gen_matrix` stage + the two jobs (snippet in M3). M6: extend the `cache:` block to persist `ci/.matrix_cache.json`.

**`ci/generate_dashboard.py`** — M3/M5: add a matrix panel that reads `matrix_results.xml` (it already aggregates other result dirs; add one more source).

### Interfaces introduced

- `ci/matrix.py`: `run_validate/run_generate/run_elaborate/run_smoke(cfg: dict, ctx: MatrixCtx) -> TierResult`; `write_junit(results, path)`; `expand_axes(matrix) -> list[config]`.
- `sys_desc/Makefile print-libdirs` — newline-separated absolute paths.

---

## 8. Testing & validation

- **M1:** the diff-based acceptance check (§M1) — two builds, one overridden, diff the *specific* CC IMEM linker file (`firmware/nanosoc_multicore_soc_cc_stage1_imem_memory.ld`, the `IMEM_0 … LENGTH` line) or the `NanoSoC_REGION_IMEM_0_SIZE` line in `firmware/nanosoc_memmap.cmake`. Diff a specific file, not the whole `firmware/` tree, since outputs carry generation timestamps (the empirical no-op check stripped timestamps before comparing; a naive `diff -r` would show spurious differences). This is also the first real test that overrides do anything; add it as a tiny `pytest` in M5 (`test_override_changes_memmap`).
- **M1.5:** `QSPI_FLASH_ADDR_W: 27` must produce a Tier-1 `phys_size … exceeds decode window` error; `QSPI_FLASH_ADDR_W: 26` must pass; a `phys_size` driven non-int must produce the resolve error. These are the `qspi_phys_overflow`/`qspi_phys_fits` matrix configs run under `--tier validate`.
- **M2:** run the driver on the curated matrix; deliberately inject `SYS_ADDR_W: 8` (a width-validation error) and use the `relayout_tight_phc` fixture (a literal base/size overlap), confirm both surface as Tier-1 validator errors. The driver's own JUnit output is the artifact.
- **M3:** observe `matrix_validate` in the GitLab test-report tab; an MR with a bad swept config must go red there before lint/sim ever run.
- **M4/M5:** smoke tier boots `default` and `fpga_small` to the real `hello` UART marker (§M4); `pytest ci/test_matrix_smoke.py` collects N parametrized cases.

**Interaction with other CI docs:** This doc's Tier-0/1 functions ARE the generator's de-facto unit tests (§4.4) until a dedicated `nanosoc_arch_tech/nanosoc_gen/tests/` exists — the unit-testing roadmap doc should import `ci/matrix.py`'s tier functions rather than duplicate them. The TB-generation roadmap doc, if it lands a default-TB backend, feeds Tier-4: each generated config could get a generated smoke TB instead of the hand-written `soc_smoke` env, making T4 actually per-config rather than default-only.

---

## 9. Risks, tradeoffs, alternatives considered

- **M1 changes generator behaviour for everyone.** Making `--config-override` real means `soc_model_fpga` will *finally* resize the memmap (the linker `length`/`phys_size`, not the literal decode windows — §M1). This could surface latent sizing bugs in the FPGA config that were masked while the override was a no-op — most plausibly a `phys_size > window` overflow (caught at Tier-1 by M1.5) rather than a literal-`size` overlap (which a width sweep does not change; §4.1). That's the point, but it may turn the FPGA build red on first run. Mitigation: M1's acceptance diff + the M1.5 Tier-1 guard + run the matrix on `fpga_small` before merging M1.
- **`eval`-based param expressions.** `phys_size: "2 ** $N"` strings go through `_safe_eval` (`nanosoc_arch_tech/nanosoc_gen/soc_model/utils.py:45`, `eval(expr, {"__builtins__": {}})`, reached via `resolve_param_ref`, `utils.py:8`). **Today these are resolved *only* at backend time** (`backends/firmware.py:237-243`, `backends/discovery.py:239-244`) — `validate_all()` never touches `phys_size` (`grep -c phys_size validator.py` → 0). So a swept width that yields a non-integer/huge value throws deep in a Tier-2 backend, not at validate. Mitigation is **M1.5** (not a vague "add a check"): it lifts the *same* `resolve_param_ref` + bounds logic the firmware backend already uses into a new `_validate_phys_size_fits` validator method, so the resolution runs once at Tier-1. This deliberately duplicates only the resolve+bounds step (a handful of lines), **not** the firmware emission; the nested-subsystem flatten chain is the documented fast-follow (§M1.5 scope caveat). `_safe_eval` itself is left unchanged.
- **Cartesian explosion.** `axes` products can blow up runner time. Mitigation: `axes` are gated to Tier-1 (free) by default; the curated explicit list carries the expensive tiers.
- **License contention.** Tier-3/4 per-config multiplies xcelium/VCS license usage. Mitigation: `allow_failure: true` initially, gated subset only, and M6 caching to skip unchanged configs.
- **Isolated build dirs vs flist assumptions.** The lint/cocotb flists reference `build_soc/` paths; the matrix copies the per-config dir over `build_soc/` in a throwaway job workspace rather than re-pointing every flist (simpler, fewer moving parts). Tradeoff: can't run two elaborate-tier configs concurrently in *one* workspace — but GitLab gives each job its own workspace, so this is fine in CI and a documented limitation locally.
- **Alternative considered — GitLab `parallel:matrix`.** GitLab natively supports `parallel: matrix:` with env-var fan-out. Rejected as the *primary* mechanism because (a) it can't express the per-config `tier` cost gating cleanly, (b) it duplicates config definitions into YAML CI syntax instead of a reviewable `ci/matrix.yaml`, and (c) it can't run locally. We can still layer `parallel:matrix` on top of `ci/matrix.py --select name=<x>` later for runner-level parallelism without changing the source of truth.
- **Alternative considered — a `num_cores` knob.** Out of scope (§2); it requires a generator topology refactor (`02-*`). The matrix sweeps parameters, not topology.

---

## 10. Dependencies & sequencing

**Builds on / unblocked by:**
- **`02-clean-architecture-adapters-backends.md`** — the topology-knob (num_cores, subsystem-set) gap (§4.3) is solvable cleanly only after the backend/model refactor there; until then the matrix sweeps params + `condition:` only. Two `02` items would strengthen this matrix: (a) a top-level `*_BASE`/`*_SIZE` param knob so base/window-relayout overlap tests can be `overrides:` instead of `yaml:` fixtures (§5.2); and (b) lifting the full nested-subsystem `phys_size` flatten chain into the validator so M1.5's Tier-1 guard covers nested targets, not just top-level ones (§M1.5 scope caveat). M1.5 already gives Tier-1 size-arithmetic validation for top-level targets without waiting on `02`.
- The (proposed) **unit-testing roadmap doc** — shares `ci/matrix.py`'s tier functions as the generator's de-facto test suite (§4.4); that doc should not duplicate parse/validate harnessing.

**Unblocks:**
- The **TB-generation roadmap doc** — once Tier-4 can run a *generated* smoke TB per config, the matrix's smoke tier becomes per-config instead of default-only.
- Confident parameterised tape-outs (the FPGA-vs-ASIC sizing splits the project already does by hand).

**Sequencing:** M1 (correctness fix) must land first — everything downstream is meaningless without it. M1.5 (Tier-1 `phys_size` guard) lands with or just after M1, since it depends on overrides reaching the model and is what makes width sweeps assert anything at the free tier. M2 (driver) and M3 (CI stage) are the MVP. M4–M6 are independent improvements.

**Effort estimate:**
- M1: **S** (one-file generator fix + acceptance diff).
- M1.5: **S** (one validator method reusing `resolve_param_ref` + `flat_params`; top-level targets first, nested fast-follow).
- M2: **M** (new driver + matrix file + JUnit).
- M3: **S** (CI YAML, mirrors existing job shape).
- M4: **M** (smoke tier needs the build-dir copy + firmware-clock interaction).
- M5: **S** (refactor for importability + pytest shim).
- M6: **S–M** (cache keying + GitLab cache wiring).

Overall: **M** to reach the MVP (M1+M1.5–M3); **L** for the full ladder including gated smoke and caching.

---

### Open questions

**Resolved from the code (recorded here so they are not re-opened):**

- **Does `condition:` removal drop the instance from the generated toplevel? — NO (settled).** `condition:` is rendered as a SystemVerilog `generate if ({{ inst.condition }}) …` (`nanosoc_arch_tech/nanosoc_gen/soc_model/backends/templates/soc_toplevel.sv.j2:126-127,142-143`), with `inst.condition` passed through raw (`backends/toplevel.py:652`). The instance body therefore **stays in the generated `.sv` text** even when the condition is false; it is pruned only at RTL elaboration (Tier-3). The `no_dma` matrix config is consequently a **Tier-3** check (§5.2), and the M1 acceptance check must NOT grep the `.sv` for instance absence (§M1). (Additionally, the top-level `u_dma_230_0` carries no `condition:` at all — the gating lives inside the DMA subsystem YAML — §4.3.)

**Still open (could not resolve from the code):**

1. **Which params are safe to sweep widely?** `SYS_DATA_W: 64` may not be supported by downstream CMSDK/Cortex-M0 RTL even if it parses/validates; the matrix should start with conservative, known-good ranges and widen as Tier-3 (elaborate) confirms each. The set of "supported" widths is not documented anywhere I could find.
2. **Generator unit-test suite location.** Project memory references "7 generator pytest" but `nanosoc_arch_tech/nanosoc_gen/tests/` does not exist in this tree (verified). If that suite lives elsewhere (another worktree/branch), M5 should integrate with it rather than create a parallel one. Verify before implementing M5.
