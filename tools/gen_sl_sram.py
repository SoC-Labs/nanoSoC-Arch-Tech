#!/usr/bin/env python3
"""Generate sl_sram.v ASIC SRAM wrapper from precompiled macro .spec files.

Scans a directory of precompiled SRAM macros, reads their .spec files to
extract configuration (word count, data width, instance name), and generates
an sl_sram.v wrapper module with:
  - generate blocks for each exact-match macro (by byte address width)
  - multi-bank composition for sizes larger than the largest available macro
  - compile-time error for unsupported address widths

Usage:
    python gen_sl_sram.py --macro-dir /research/precompiled_mems/TSMC65 \
                          --output sl_sram.v

    python gen_sl_sram.py --macro-dir /research/precompiled_mems/TSMC65 \
                          --output sl_sram.v --dry-run
"""

import argparse
import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List


@dataclass
class SramMacro:
    """Represents a precompiled SRAM macro parsed from a .spec file."""
    name: str        # Module name (e.g., rf_01k)
    words: int       # Number of words
    bits: int        # Data width in bits
    word_aw: int     # Word address width (log2(words))
    byte_aw: int     # Byte address width (log2(words * bits/8))
    has_write_mask: bool
    has_ema: bool
    has_retention: bool
    has_verilog: bool  # Whether a .v file exists
    spec_path: str


def parse_spec_file(spec_path: str) -> SramMacro:
    """Parse a .spec file and extract SRAM macro configuration."""
    config = {}
    with open(spec_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, _, value = line.partition('=')
                config[key.strip()] = value.strip()

    name = config.get('instname', '')
    words = int(config.get('words', 0))
    bits = int(config.get('bits', 0))

    if words <= 0 or bits <= 0:
        raise ValueError(f"Invalid words={words} or bits={bits} in {spec_path}")

    word_aw = int(math.log2(words))
    byte_aw = int(math.log2(words * bits // 8))

    # Check for Verilog model alongside spec
    spec_dir = os.path.dirname(spec_path)
    has_verilog = os.path.exists(os.path.join(spec_dir, f"{name}.v"))

    return SramMacro(
        name=name,
        words=words,
        bits=bits,
        word_aw=word_aw,
        byte_aw=byte_aw,
        has_write_mask=config.get('write_mask', 'off') == 'on',
        has_ema=config.get('ema', 'off') == 'on',
        has_retention=config.get('retention', 'off') == 'on',
        has_verilog=has_verilog,
        spec_path=spec_path,
    )


def parse_verilog_header(verilog_path: str) -> SramMacro:
    """Parse a Verilog model header to extract SRAM macro configuration.

    Falls back to this when no .spec file is available. Extracts WORDS, BITS,
    and module name from the Verilog parameter declarations.
    """
    import re

    name = Path(verilog_path).stem
    words = None
    bits = None
    has_wen = False
    has_ema = False
    has_ret = False

    with open(verilog_path) as f:
        # Read first 200 lines (header area)
        for i, line in enumerate(f):
            if i > 200:
                break
            # Match parameter declarations like: parameter WORDS = 4096;
            m = re.match(r'\s*parameter\s+WORDS\s*=\s*(\d+)', line)
            if m:
                words = int(m.group(1))
            m = re.match(r'\s*parameter\s+BITS\s*=\s*(\d+)', line)
            if m:
                bits = int(m.group(1))
            # Check for port presence
            if re.search(r'\bWEN\b', line) and 'input' in line:
                has_wen = True
            if re.search(r'\bEMA\b', line) and 'input' in line:
                has_ema = True
            if re.search(r'\bRET1N\b', line) and 'input' in line:
                has_ret = True

    if words is None or bits is None:
        raise ValueError(f"Could not extract WORDS/BITS from {verilog_path}")

    word_aw = int(math.log2(words))
    byte_aw = int(math.log2(words * bits // 8))

    return SramMacro(
        name=name,
        words=words,
        bits=bits,
        word_aw=word_aw,
        byte_aw=byte_aw,
        has_write_mask=has_wen,
        has_ema=has_ema,
        has_retention=has_ret,
        has_verilog=True,
        spec_path=verilog_path,
    )


def scan_macro_dir(macro_dir: str) -> List[SramMacro]:
    """Scan a directory for SRAM macro .spec and .v files.

    Prefers .spec files when available. Falls back to parsing Verilog headers
    for macros that only have .v files (no .spec).
    """
    macros = {}  # keyed by macro name to deduplicate
    macro_path = Path(macro_dir)

    # First pass: .spec files (preferred source)
    for spec_file in sorted(macro_path.glob('*/*.spec')):
        try:
            macro = parse_spec_file(str(spec_file))
            macros[macro.name] = macro
        except (ValueError, KeyError) as e:
            print(f"WARNING: Skipping {spec_file}: {e}", file=sys.stderr)

    # Second pass: .v files for macros not already found via .spec
    for verilog_file in sorted(macro_path.glob('*/*.v')):
        name = verilog_file.stem
        if name not in macros:
            try:
                macro = parse_verilog_header(str(verilog_file))
                macros[macro.name] = macro
            except (ValueError, KeyError) as e:
                print(f"WARNING: Skipping {verilog_file}: {e}", file=sys.stderr)

    # Sort by byte address width (ascending)
    result = sorted(macros.values(), key=lambda m: m.byte_aw)
    return result


def generate_macro_instance(macro: SramMacro, indent: str = "    ") -> str:
    """Generate Verilog for a single macro instantiation."""
    lines = []
    lines.append(f"{indent}// {macro.name}: {macro.words} words x {macro.bits}-bit ({macro.words * macro.bits // 8 // 1024} KB)")
    lines.append(f"{indent}{macro.name} u_rf_sp_hdf (")
    lines.append(f"{indent}  `ifdef POWER_PINS")
    lines.append(f"{indent}  .VDD   (VDD),")
    lines.append(f"{indent}  .VSS   (VSS),")
    lines.append(f"{indent}  `endif")
    lines.append(f"{indent}  .Q     (RDATA32),")
    lines.append(f"{indent}  .CLK   (CLK),")
    lines.append(f"{indent}  .CEN   (CEN),")
    if macro.has_write_mask:
        lines.append(f"{indent}  .WEN   (WEN32),")
    lines.append(f"{indent}  .A     (ADDR12),")
    lines.append(f"{indent}  .D     (WDATA32),")
    if macro.has_ema:
        lines.append(f"{indent}  .EMA   (TIE_EMA),")
        lines.append(f"{indent}  .EMAW  (TIE_EMAW),")
    lines.append(f"{indent}  .GWEN  (GWEN),")
    if macro.has_retention:
        lines.append(f"{indent}  .RET1N (TIE_RET1N)")
    else:
        # Remove trailing comma from GWEN line
        lines[-1] = lines[-1].rstrip(',')
    lines.append(f"{indent});")
    return '\n'.join(lines)


def generate_banked_instance(largest: SramMacro, indent: str = "    ") -> str:
    """Generate Verilog for multi-bank composition using the largest macro."""
    wd_aw = largest.byte_aw - 2  # word address width for the base macro
    lines = []
    lines.append(f"")
    lines.append(f"{indent}localparam BASE_AW    = {largest.byte_aw};")
    lines.append(f"{indent}localparam BASE_WD_AW = BASE_AW - 2;  // {largest.name} word address width ({wd_aw})")
    lines.append(f"{indent}localparam N          = 2 ** (AW - BASE_AW); // number of banks")
    lines.append(f"")
    lines.append(f"{indent}wire [BASE_WD_AW-1:0] addr_lo  = ADDR12[BASE_WD_AW-1:0];")
    lines.append(f"{indent}wire [$clog2(N)-1:0]  bank_sel = ADDR12[AW-3:BASE_WD_AW];")
    lines.append(f"")
    lines.append(f"{indent}wire [N-1:0]    bank_cen;")
    lines.append(f"{indent}wire [31:0]     bank_rdata [0:N-1];")
    lines.append(f"")
    lines.append(f"{indent}genvar b;")
    lines.append(f"{indent}for (b = 0; b < N; b = b + 1) begin : gen_bank")
    lines.append(f"{indent}  // Per-bank chip enable: active when CS asserted and bank selected")
    lines.append(f"{indent}  assign bank_cen[b] = (bank_sel == b) ? !CS : 1'b1;")
    lines.append(f"")
    lines.append(f"{indent}  {largest.name} u_rf_sp_hdf (")
    lines.append(f"{indent}    `ifdef POWER_PINS")
    lines.append(f"{indent}    .VDD   (VDD),")
    lines.append(f"{indent}    .VSS   (VSS),")
    lines.append(f"{indent}    `endif")
    lines.append(f"{indent}    .Q     (bank_rdata[b]),")
    lines.append(f"{indent}    .CLK   (CLK),")
    lines.append(f"{indent}    .CEN   (bank_cen[b]),")
    if largest.has_write_mask:
        lines.append(f"{indent}    .WEN   (WEN32),")
    lines.append(f"{indent}    .A     (addr_lo),")
    lines.append(f"{indent}    .D     (WDATA32),")
    if largest.has_ema:
        lines.append(f"{indent}    .EMA   (TIE_EMA),")
        lines.append(f"{indent}    .EMAW  (TIE_EMAW),")
    lines.append(f"{indent}    .GWEN  (GWEN),")
    if largest.has_retention:
        lines.append(f"{indent}    .RET1N (TIE_RET1N)")
    else:
        lines[-1] = lines[-1].rstrip(',')
    lines.append(f"{indent}  );")
    lines.append(f"{indent}end")
    lines.append(f"")
    lines.append(f"{indent}// Read data mux: select from active bank")
    lines.append(f"{indent}assign RDATA32 = bank_rdata[bank_sel];")
    return '\n'.join(lines)


def generate_sl_sram(macros: List[SramMacro], technology: str = "TSMC65") -> str:
    """Generate the complete sl_sram.v file content."""
    # Filter to 32-bit macros only
    macros_32 = [m for m in macros if m.bits == 32]

    if not macros_32:
        print("ERROR: No 32-bit macros found", file=sys.stderr)
        sys.exit(1)

    # Warn about macros without Verilog models
    for m in macros_32:
        if not m.has_verilog:
            print(f"WARNING: {m.name} has no Verilog model (.v file) — "
                  f"including in wrapper but simulation will fail without it",
                  file=sys.stderr)

    largest = macros_32[-1]  # sorted by byte_aw
    supported_aws = ', '.join(str(m.byte_aw) for m in macros_32)

    lines = []

    # Header
    lines.append(f"//-----------------------------------------------------------------------------")
    lines.append(f"// SoCLabs ASIC RAM Wrapper ({technology})")
    lines.append(f"// - Auto-generated by gen_sl_sram.py from precompiled macro .spec files")
    lines.append(f"// - Parameterisable SRAM wrapper that selects precompiled macros by address width")
    lines.append(f"// - For AW matching an available macro, a single instance is used")
    lines.append(f"// - For AW > largest macro, multiple banks are composed with address decode")
    lines.append(f"// - Substituted using the same name from the FPGA tech library via filelist")
    lines.append(f"// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.")
    lines.append(f"//")
    lines.append(f"// Available macros (scanned from .spec files):")
    for m in macros_32:
        verilog_note = "" if m.has_verilog else " [WARNING: no .v model]"
        lines.append(f"//   {m.name}: {m.words} words x {m.bits}-bit, AW={m.byte_aw}{verilog_note}")
    lines.append(f"//")
    lines.append(f"// Contributors")
    lines.append(f"//")
    lines.append(f"// David Flynn (d.flynn@soton.ac.uk)")
    lines.append(f"// David Mapstone (d.a.mapstone@soton.ac.uk)")
    lines.append(f"//")
    lines.append(f"// Copyright 2021-6, SoC Labs (www.soclabs.org)")
    lines.append(f"//-----------------------------------------------------------------------------")
    lines.append(f"")

    # Module declaration
    lines.append(f"module sl_sram #(")
    lines.append(f"// --------------------------------------------------------------------------")
    lines.append(f"// Parameter Declarations")
    lines.append(f"// --------------------------------------------------------------------------")
    lines.append(f"  parameter AW = 16")
    lines.append(f" )")
    lines.append(f" (")
    lines.append(f"  `ifdef POWER_PINS")
    lines.append(f"  inout  wire          VDD,")
    lines.append(f"  inout  wire          VSS,")
    lines.append(f"  `endif")
    lines.append(f"  // Inputs")
    lines.append(f"  input  wire          CLK,")
    lines.append(f"  input  wire [AW-1:2] ADDR,")
    lines.append(f"  input  wire [31:0]   WDATA,")
    lines.append(f"  input  wire [3:0]    WREN,")
    lines.append(f"  input  wire          CS,")
    lines.append(f"")
    lines.append(f"  // Outputs")
    lines.append(f"  output wire [31:0]   RDATA")
    lines.append(f"  );")
    lines.append(f"")

    # Common signals
    lines.append(f"// Common signal assignments")
    # Check if any macro has EMA/retention
    any_ema = any(m.has_ema for m in macros_32)
    any_ret = any(m.has_retention for m in macros_32)
    if any_ema:
        lines.append(f"localparam  TIE_EMA   = 3'b010;")
        lines.append(f"localparam  TIE_EMAW  = 2'b00;")
    if any_ret:
        lines.append(f"localparam  TIE_RET1N = 1'b1;")
    lines.append(f"")
    lines.append(f"wire [AW-3:0] ADDR12  = ADDR;")
    lines.append(f"wire [31:0]   WDATA32 = WDATA;")
    lines.append(f"wire [31:0]   RDATA32;")
    lines.append(f"assign        RDATA   = RDATA32;")
    lines.append(f"wire          CEN     = !CS;")
    lines.append(f"wire          GWEN    = &(~WREN);")
    if any(m.has_write_mask for m in macros_32):
        lines.append(f"wire [31:0]   WEN32   = {{ {{8{{!WREN[3]}}}},{{8{{!WREN[2]}}}},{{8{{!WREN[1]}}}},{{8{{!WREN[0]}}}} }};")
    lines.append(f"")

    # Generate blocks
    lines.append(f"generate")

    first = True
    for macro in macros_32:
        prefix = "  if" if first else "  else if"
        first = False
        lines.append(f"")
        lines.append(f"  {prefix} (AW == {macro.byte_aw}) begin : gen_{macro.name}")
        lines.append(generate_macro_instance(macro, indent="    "))
        lines.append(f"  end")

    # Banked composition
    lines.append(f"")
    lines.append(f"  // Multi-bank composition for AW > {largest.byte_aw}")
    lines.append(f"  // Uses N copies of {largest.name} (largest macro) with address-decode banking")
    lines.append(f"  else if (AW > {largest.byte_aw}) begin : gen_banked")
    lines.append(generate_banked_instance(largest, indent="    "))
    lines.append(f"  end")

    # Error clause
    lines.append(f"")
    lines.append(f"  else begin : gen_unsupported")
    lines.append(f'    // No macro available for this AW value')
    lines.append(f'    initial $error("sl_sram: unsupported AW=%0d for {technology}. Supported: {supported_aws}, or >{largest.byte_aw} (banked)", AW);')
    lines.append(f"  end")
    lines.append(f"")
    lines.append(f"endgenerate")
    lines.append(f"")
    lines.append(f"endmodule")

    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(
        description='Generate sl_sram.v ASIC SRAM wrapper from precompiled macro .spec files'
    )
    parser.add_argument(
        '--macro-dir', required=True,
        help='Path to directory containing precompiled macro subdirectories (e.g., /research/precompiled_mems/TSMC65)'
    )
    parser.add_argument(
        '--output', required=True,
        help='Output path for generated sl_sram.v'
    )
    parser.add_argument(
        '--technology', default=None,
        help='Technology name for header comment (default: derived from macro-dir basename)'
    )
    parser.add_argument(
        '--dry-run', action='store_true',
        help='Print generated output to stdout instead of writing to file'
    )
    args = parser.parse_args()

    technology = args.technology or os.path.basename(args.macro_dir.rstrip('/'))

    print(f"Scanning {args.macro_dir} for SRAM macro .spec files...", file=sys.stderr)
    macros = scan_macro_dir(args.macro_dir)

    if not macros:
        print(f"ERROR: No .spec files found in {args.macro_dir}/*/", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(macros)} macro(s):", file=sys.stderr)
    for m in macros:
        verilog = "yes" if m.has_verilog else "NO"
        print(f"  {m.name}: {m.words}x{m.bits}, AW={m.byte_aw}, verilog={verilog}",
              file=sys.stderr)

    output = generate_sl_sram(macros, technology)

    if args.dry_run:
        print(output)
    else:
        os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"Generated {args.output}", file=sys.stderr)


if __name__ == '__main__':
    main()
