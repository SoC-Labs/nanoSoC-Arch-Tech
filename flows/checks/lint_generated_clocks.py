#!/usr/bin/env python3
# Copyright 2026, SoC Labs (www.soclabs.org)
"""STATIC lint: every emitted create_generated_clock must have a resolvable
master clock in the SAME emitted XDC/SDC.

Catches EXACTLY the failure the fix/qspi-constraints-regression branch *claims*:
a `create_generated_clock ... -source <X>` whose source neither

  (a) names a base clock declared by a sibling `create_clock -name <...>`, nor
  (b) chains to another `create_generated_clock -name <...>` that does, nor
  (c) is a hierarchical *pin* glob ("*.../inst/clk_out1" or ".../reg/Q") that
      Vivado/DC will resolve from the netlist (a BD clk_wiz output, an MMCM, a
      flop pin) — these are LEGITIMATE and must NOT be flagged.

It is purely textual (no Vivado, no netlist) so it runs in `make soc`,
trace-check and CI. It does NOT prove the pin EXISTS in the netlist (only the
FPGA tool can) — for that, pair it with check_no_timing_38_285.py against the
impl log. What this guarantees: nanosoc_gen never emits a generated clock whose
source is a *named clock that was never created* (the classic "does not have a
valid master clock" generator bug).

Exit 0 = clean, exit 1 = at least one dangling generated clock.

Usage:
    lint_generated_clocks.py build_soc/constraints/*.xdc build_soc/constraints/*.sdc
    lint_generated_clocks.py            # defaults to build_soc/constraints/*.{xdc,sdc}
"""
import glob
import re
import sys

# A -source token is a "real netlist pin" (tool-resolvable, never a named
# master) when it is a hierarchical path: it contains '/' (pin hierarchy) or a
# wildcard glob. Bare identifiers MUST match a create_clock / create_generated
# -name in the same file.
_PIN_GLOB = re.compile(r"[/*?\[]")

_C_CLOCK = re.compile(r"^\s*create_clock\b.*?-name\s+(\S+)")
_G_CLOCK_NAME = re.compile(r"^\s*create_generated_clock\b.*?-name\s+(\S+)")
# -source token: either `-source [get_ports foo]`, `-source [get_pins ... NAME =~ "glob"]`,
# or `-source bare_name`.
_SRC_GETX = re.compile(r"-source\s+\[get_\w+\b(.*?)\]", re.S)
_SRC_NAME_IN_GETCLOCKS = re.compile(r"get_clocks\s+\{?\s*([\w/*?\[\].]+)")
_SRC_GLOB_IN_FILTER = re.compile(r'NAME\s*=~\s*"([^"]+)"')
_SRC_PORT = re.compile(r"get_ports\s+\{?\s*([\w/*?\[\].]+)")
_SRC_BARE = re.compile(r"-source\s+([^\[\s]\S*)")


def _strip(tok: str) -> str:
    return tok.strip().strip("{}").strip()


def _source_token(line: str):
    """Return (token, kind) for the -source of a create_generated_clock line.

    kind: 'pin'  -> tool-resolvable netlist pin/port (never needs a named master)
          'name' -> a bare clock name that MUST have a sibling create_clock/-gen

    Only the bracketed expression that immediately follows '-source' is parsed,
    so a hierarchical glob in the *target* (the trailing get_pins) is never
    mistaken for the source.
    """
    m = _SRC_GETX.search(line)
    if m:
        inner = m.group(1)               # contents of the [...] right after -source
        gm = _SRC_GLOB_IN_FILTER.search(inner)
        if gm:
            return gm.group(1), "pin"          # -source [get_pins ... NAME =~ "glob"]
        pm = _SRC_PORT.search(inner)
        if pm:
            tok = _strip(pm.group(1))
            return tok, ("pin" if _PIN_GLOB.search(tok) else "name")
        cm = _SRC_NAME_IN_GETCLOCKS.search(inner)
        if cm:
            tok = _strip(cm.group(1))
            return tok, ("pin" if _PIN_GLOB.search(tok) else "name")
        return _strip(inner), "name"
    bm = _SRC_BARE.search(line)
    if bm:
        tok = _strip(bm.group(1))
        return tok, ("pin" if _PIN_GLOB.search(tok) else "name")
    return None, None


def lint_file(path: str):
    """Return list of (lineno, message) violations for one constraints file."""
    with open(path) as fh:
        raw = fh.readlines()
    # Join continuation lines (Tcl '\' line-continuation) so multi-line
    # create_generated_clock statements parse as one logical line.
    logical = []
    buf, start = "", 0
    for i, ln in enumerate(raw, 1):
        s = ln.rstrip("\n")
        if not buf:
            start = i
        if s.endswith("\\"):
            buf += s[:-1] + " "
            continue
        logical.append((start, buf + s))
        buf = ""
    if buf:
        logical.append((start, buf))

    base_clocks, gen_clocks = set(), set()
    for _, line in logical:
        m = _C_CLOCK.search(line)
        if m:
            base_clocks.add(m.group(1))
        m = _G_CLOCK_NAME.search(line)
        if m:
            gen_clocks.add(m.group(1))
    masters = base_clocks | gen_clocks

    viol = []
    for lineno, line in logical:
        if "create_generated_clock" not in line:
            continue
        tok, kind = _source_token(line)
        if tok is None:
            viol.append((lineno, "create_generated_clock with no parseable -source"))
            continue
        if kind == "name" and tok not in masters:
            viol.append((
                lineno,
                f'-source names clock "{tok}" but no create_clock/'
                f'create_generated_clock -name {tok} exists in this file '
                f'(would be a "does not have a valid master clock" error)'))
    return viol


def main(argv):
    files = argv[1:] or (
        glob.glob("build_soc/constraints/*.xdc")
        + glob.glob("build_soc/constraints/*.sdc"))
    expanded = []
    for f in files:
        expanded += glob.glob(f) if _PIN_GLOB.search(f) else [f]
    if not expanded:
        print("lint_generated_clocks: no constraints files found", file=sys.stderr)
        return 1
    total = 0
    for f in expanded:
        for lineno, msg in lint_file(f):
            print(f"{f}:{lineno}: ERROR generated-clock master: {msg}",
                  file=sys.stderr)
            total += 1
    if total:
        print(f"lint_generated_clocks: {total} dangling generated clock(s)",
              file=sys.stderr)
        return 1
    print(f"lint_generated_clocks: OK ({len(expanded)} file(s), all generated "
          f"clocks have a resolvable master)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
