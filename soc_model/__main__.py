"""CLI entry point for the SoC Model tool.

Usage:
    python -m soc_model nanosoc_m0_soc.yaml --lib-dir ../nanosoc_arch_tech/rtl/sys_desc
    python -m soc_model nanosoc_m0_soc.yaml --lib-dir ../nanosoc_arch_tech/rtl/sys_desc --build-dir build_soc
    python -m soc_model nanosoc_m0_soc.yaml --validate-only
"""

import argparse
import os
import sys
from pathlib import Path

from .parser import SoCParser
from .builder import SoCBuilder
from .validator import SoCValidator
from .backends.html import SoCVisualizer
from .backends.text import SoCTextBackend
from .backends.python import SoCPythonBackend
from .backends.ahb import SoCAhbBackend
from .backends.firmware import SoCFirmwareBackend
from .backends.rdl import SoCRdlBackend
from .backends.discovery import SoCDiscoveryBackend
from .backends.toplevel import SoCTopLevelBackend
from .backends.lint import SoCLintBackend


def main():
    argp = argparse.ArgumentParser(
        description='SoC Model — parse, validate, and visualize YAML system descriptions',
    )
    argp.add_argument('yaml_file', help='Top-level YAML system description file')
    argp.add_argument('--build-dir', '-b', default=None, help='Build output directory (default: build_soc/)')
    argp.add_argument('--validate-only', action='store_true', help='Only validate, do not generate outputs')
    argp.add_argument('--no-validate', action='store_true', help='Skip validation')
    argp.add_argument('--lib-dir', '-l', default=None,
                      help='Library directory for component YAMLs (modules, interfaces, register_maps)')
    argp.add_argument('--arm-ip-library-path', default=None,
                      help='Path to ARM IP library (overrides ARM_IP_LIBRARY_PATH env var)')
    argp.add_argument('--lint', action='store_true', default=False,
                      help='Run slang linter on all design RTL files')
    argp.add_argument('--lint-flist', default=None,
                      help='Filelist (.flist) for design RTL sources to lint '
                           '(default: nanosoc_arch_tech/rtl/flist/nanosoc.flist)')
    argp.add_argument('--slang-bin', default=None,
                      help='Path to slang binary (default: auto-detect from PATH)')
    argp.add_argument('--slang-args', default=None,
                      help='Extra arguments to pass to slang (space-separated)')
    args = argp.parse_args()

    yaml_path = Path(args.yaml_file).resolve()
    base_dir = yaml_path.parent
    lib_dir = Path(args.lib_dir).resolve() if args.lib_dir else None

    # --- Parse ---
    print(f"Parsing {yaml_path.name}...")
    if lib_dir:
        print(f"  Library: {lib_dir}")
    parser = SoCParser(str(base_dir), str(lib_dir) if lib_dir else None)
    builder = SoCBuilder(parser)

    try:
        top_module = builder.build_system(yaml_path.name)
    except Exception as e:
        print(f"Error building model: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"  Module: {top_module.name}")
    print(f"  Params: {len(top_module.params)}")
    print(f"  Interfaces: {len(top_module.interfaces)}")
    print(f"  Instances: {len(top_module.instances)}")
    print(f"  Assigns: {len(top_module.assigns)}")
    print(f"  Glue logic: {len(top_module.glue_logic)}")
    print(f"  Internal wires: {len(top_module.internal_wires)}")
    print(f"  Interconnects: {len(top_module.interconnects)}")

    resolved = sum(1 for i in top_module.instances if i.resolved_module)
    print(f"  Resolved modules: {resolved}/{len(top_module.instances)}")

    # --- Validate ---
    messages = []
    if not args.no_validate:
        print("\nValidating...")
        validator = SoCValidator(top_module)
        messages = validator.validate_all()

        for msg in messages:
            print(f"  {msg}")

        print(f"\n  {len(validator.errors)} error(s), {len(validator.warnings)} warning(s)")

        if args.validate_only:
            sys.exit(1 if validator.errors else 0)

    # --- Build directory structure ---
    # New layout:
    #   build_soc/soc/                    — SoC-level outputs (address maps, model, HTML)
    #   build_soc/<hier.name>/            — Per-component generated outputs
    build_dir = Path(args.build_dir) if args.build_dir else base_dir / 'build_soc'
    soc_dir = build_dir / 'soc'

    soc_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nBuild directory: {build_dir}")

    # --- SoC-level outputs (all in soc/) ---
    print("\n--- SoC-level outputs ---")

    # HTML visualization
    html_path = soc_dir / f"{top_module.name}_connectivity.html"
    print(f"  HTML: {html_path}")
    visualizer = SoCVisualizer(top_module)
    visualizer.generate_html(str(html_path), messages)

    # Text address maps and hierarchy
    memmap_path = soc_dir / f"{top_module.name}_memory_map.txt"
    hierarchy_path = soc_dir / f"{top_module.name}_hierarchy.txt"
    print(f"  Text memory map: {memmap_path}")
    print(f"  Text hierarchy:  {hierarchy_path}")
    text = SoCTextBackend(top_module)
    text.generate_memory_map(str(memmap_path))
    text.generate_hierarchy(str(hierarchy_path))

    # Python model
    py_path = soc_dir / f"{top_module.name}_model.py"
    print(f"  Python model: {py_path}")
    pybackend = SoCPythonBackend(top_module)
    pybackend.generate(str(py_path))

    # --- AHB interconnect generation (per-component directories) ---
    print("\n--- AHB Interconnect Generation ---")
    ahb_backend = SoCAhbBackend(top_module, arm_ip_library_path=args.arm_ip_library_path)
    generated = ahb_backend.generate_all(build_dir)

    if generated:
        print(f"\n  Generated {len(generated)} interconnect(s):")
        for ic_name, ic_dir in generated:
            print(f"    {ic_name}: {ic_dir}")
    else:
        print("  No interconnects with gen: True found")

    # --- RDL register description generation ---
    print("\n--- RDL Register Description Generation ---")
    rdl_backend = SoCRdlBackend(top_module)
    rdl_generated = rdl_backend.generate_all(build_dir)

    if rdl_generated:
        print(f"\n  Generated {len(rdl_generated)} register map(s):")
        for rm_name, rdl_path, rtl_gen in rdl_generated:
            status = " (RTL generated)" if rtl_gen else ""
            print(f"    {rm_name}: {rdl_path}{status}")
    else:
        print("  No register maps found in the design hierarchy")

    # --- Device Discovery Table ---
    print("\n--- Device Discovery Table ---")
    discovery_backend = SoCDiscoveryBackend(top_module)
    discovery_results = discovery_backend.generate(build_dir)

    if discovery_results:
        print(f"\n  Generated {len(discovery_results)} discovery table(s):")
        for ic_name, disc_rm, disc_yaml_path in discovery_results:
            print(f"    {ic_name}: {disc_yaml_path}")
            # Generate RDL (and optional RTL) for the discovery register map
            rdl_path, rtl_gen = rdl_backend.generate_single(disc_rm, build_dir)
            status = " (RTL generated)" if rtl_gen else ""
            print(f"    RDL: {rdl_path}{status}")
    else:
        print("  No interconnects with gen: True found")

    # --- Top-level module generation ---
    print("\n--- Top-Level Module Generation ---")
    toplevel_backend = SoCTopLevelBackend(top_module)
    toplevel_dir = soc_dir / 'rtl'
    toplevel_path = toplevel_backend.generate(toplevel_dir)
    if toplevel_path:
        print(f"  Generated: {toplevel_path}")
        flist_path = soc_dir / 'flist' / f'{top_module.name}_toplevel.flist'
        if flist_path.exists():
            print(f"  Generated: {flist_path}")
    else:
        print("  Skipped (jinja2 not available)")

    # --- Firmware configuration ---
    print("\n--- Firmware Configuration ---")
    fw_backend = SoCFirmwareBackend(top_module)
    fw_dir = soc_dir / 'firmware_config'
    fw_backend.generate(fw_dir)

    # --- Lint generated RTL ---
    if args.lint:
        print("\n--- RTL Lint (slang) ---")
        lint_backend = SoCLintBackend(slang_bin=args.slang_bin)
        extra_args = args.slang_args.split() if args.slang_args else None

        # Derive directories: base_dir is the yaml dir (sys_desc/),
        # soc_root is nanosoc_m0_soc/, project_dir is its parent
        soc_root = base_dir.parent
        project_dir = str(soc_root.parent)

        # Default flist: nanosoc.flist (the top-level design filelist)
        flist = args.lint_flist
        if not flist:
            default_flist = soc_root / 'nanosoc_arch_tech' / 'rtl' / 'flist' / 'nanosoc.flist'
            if default_flist.exists():
                flist = str(default_flist)

        lint_passed = lint_backend.lint_and_report(
            build_dir,
            project_dir=project_dir,
            flist_path=flist,
            extra_args=extra_args,
        )
        if not lint_passed:
            print("\n  Lint did not pass — see above for details.")

    print("\nDone.")


if __name__ == '__main__':
    main()
