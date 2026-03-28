"""Firmware configuration backend — generates linker scripts, C headers, Makefiles, and ADP files.

Produces the same output files as the standalone gen_firmware_config.py, but driven
directly from the soc_model data structures and the firmware: section of the YAML.

Generated files:
  - Linker script MEMORY{} fragments (.ld) per profile
  - C header with memory base address defines (.h)
  - Makefile include with address variables (.mk)
  - Verilog header with ADP upload address (.vh)
  - Python module with ADP address constants (.py)
"""

import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ..model import (
    Firmware, Interconnect, InterconnectInitiator, InterconnectInitiatorTarget,
    InterconnectTarget, LinkerProfile, LinkerRegion, Module,
)
from ..utils import resolve_param_ref, flatten_params

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    Environment = None
    FileSystemLoader = None

_BACKEND_DIR = Path(__file__).resolve().parent
_TEMPLATE_DIR = _BACKEND_DIR / 'templates'


class SoCFirmwareBackend:
    """Generates firmware configuration files from the SoC model."""

    def __init__(self, top_module: Module):
        self.top = top_module
        self._stitched_map = None  # Lazily built

    def generate(self, output_dir: Path):
        """Generate all firmware config files into output_dir."""
        fw = self._find_firmware()
        if fw is None:
            print("  No firmware: section found, skipping firmware config generation")
            return

        output_dir.mkdir(parents=True, exist_ok=True)

        # Build the stitched address map (all interconnects merged hierarchically)
        stitched = self._build_stitched_map()

        # Build initiator address data for the CPU initiator
        cpu_init = fw.cpu_initiator or 'cpu_0'
        init_data = self._build_cpu_initiator_data(stitched, cpu_init)

        # Derive memory regions from targets
        memory_regions = self._derive_memory_regions(stitched)

        # Build target base lookup from stitched targets
        target_bases = {t['name']: t['base'] for t in stitched['targets']}

        # Build all contexts
        linker_ctx = self._build_linker_context(fw, init_data, memory_regions, target_bases)
        memmap_ctx = self._build_memmap_context(fw, init_data, memory_regions, target_bases)
        make_ctx = self._build_makefile_context(fw, init_data, memory_regions, linker_ctx, target_bases)
        adp_ctx = self._build_adp_context(fw, init_data, target_bases)

        if Environment is None:
            print("  WARNING: Jinja2 not available, skipping firmware config generation")
            return

        env = Environment(
            loader=FileSystemLoader(str(_TEMPLATE_DIR)),
            keep_trailing_newline=True,
            trim_blocks=True,
            lstrip_blocks=True,
        )

        now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        source = f'soc_model ({self.top.name})'

        # Linker scripts
        template = env.get_template('firmware_memory.ld.j2')
        for profile_name, regions in linker_ctx.items():
            path = output_dir / f"{self.top.name}_{profile_name}_memory.ld"
            content = template.render(
                profile_name=profile_name, regions=regions,
                source_yaml=source, generated_date=now)
            path.write_text(content)
            print(f"  Generated: {path}")

        # C header
        template = env.get_template('firmware_memmap.h.j2')
        path = output_dir / f"{self.top.name}_memmap.h"
        content = template.render(**memmap_ctx, source_yaml=source, generated_date=now)
        path.write_text(content)
        print(f"  Generated: {path}")

        # Makefile
        template = env.get_template('firmware_memmap.mk.j2')
        path = output_dir / f"{self.top.name}_memmap.mk"
        content = template.render(**make_ctx, source_yaml=source, generated_date=now)
        path.write_text(content)
        print(f"  Generated: {path}")

        # ADP Verilog header
        template = env.get_template('firmware_adp.vh.j2')
        path = output_dir / f"{self.top.name}_adp.vh"
        content = template.render(**adp_ctx, source_yaml=source, generated_date=now)
        path.write_text(content)
        print(f"  Generated: {path}")

        # ADP Python module
        template = env.get_template('firmware_adp.py.j2')
        path = output_dir / f"{self.top.name}_adp.py"
        content = template.render(**adp_ctx, source_yaml=source, generated_date=now)
        path.write_text(content)
        print(f"  Generated: {path}")

    # -----------------------------------------------------------------------
    # Firmware section lookup
    # -----------------------------------------------------------------------

    def _find_firmware(self) -> Optional[Firmware]:
        """Find the firmware config, searching top module then children."""
        if self.top.firmware:
            return self.top.firmware
        for inst in self.top.instances:
            if inst.resolved_module and inst.resolved_module.firmware:
                return inst.resolved_module.firmware
        return None

    # -----------------------------------------------------------------------
    # Stitched address map
    # -----------------------------------------------------------------------

    def _build_stitched_map(self) -> dict:
        """Build a stitched address map combining all interconnect hierarchies.

        Returns a dict with:
          targets: list of {name, base, size, phys_size, sw_access, region_type, ...}
                   where base is the absolute address from the CPU's perspective
          initiator_data: per-initiator {connections, address_regions, remap_regions}
        """
        params = self.top.flat_params
        all_targets = {}  # name -> {base, size, ...}
        all_init_data = {}  # init_name -> {connections, address_regions, remap_regions}

        self._stitch_module(self.top, 0, params, all_targets, all_init_data)

        return {
            'targets': list(all_targets.values()),
            'initiator_data': all_init_data,
        }

    def _stitch_module(self, module: Module, base_offset: int,
                       parent_params: Dict[str, Any],
                       all_targets: dict, all_init_data: dict):
        """Recursively stitch interconnects from module hierarchy."""
        params = dict(parent_params)
        for pname, p in module.params.items():
            if p.default is not None:
                resolved = resolve_param_ref(p.default, params)
                params[pname] = resolved if resolved != p.default else p.default

        for ic in module.interconnects:
            ic_params = {}
            for k, v in ic.params.items():
                ic_params[k] = resolve_param_ref(v, params)

            # Build per-initiator data for this interconnect
            from .ahb import SoCAhbBackend
            dummy = SoCAhbBackend.__new__(SoCAhbBackend)
            dummy.top = self.top
            ic_init_data = dummy._build_initiator_data(ic)

            # Apply base offset to address regions and remap regions
            for init_name, idata in ic_init_data.items():
                offset_idata = {
                    'name': idata['name'],
                    'connections': idata['connections'],
                    'address_regions': [],
                    'remap_regions': [],
                }
                for r in idata['address_regions']:
                    offset_idata['address_regions'].append({
                        'interface': r['interface'],
                        'mem_lo': f"{int(r['mem_lo'], 16) + base_offset:08x}",
                        'mem_hi': f"{int(r['mem_hi'], 16) + base_offset:08x}",
                        'remapping': r['remapping'],
                    })
                for r in idata['remap_regions']:
                    offset_idata['remap_regions'].append({
                        'interface': r['interface'],
                        'mem_lo': f"{int(r['mem_lo'], 16) + base_offset:08x}",
                        'mem_hi': f"{int(r['mem_hi'], 16) + base_offset:08x}",
                        'bit': r['bit'],
                    })

                # Merge into all_init_data (combine if same initiator name)
                if init_name in all_init_data:
                    existing = all_init_data[init_name]
                    existing['connections'].extend(offset_idata['connections'])
                    existing['address_regions'].extend(offset_idata['address_regions'])
                    existing['remap_regions'].extend(offset_idata['remap_regions'])
                else:
                    all_init_data[init_name] = offset_idata

            # Add targets with absolute addresses
            for t in ic.targets:
                abs_base = t.base + base_offset
                phys_size = t.phys_size
                if isinstance(phys_size, str):
                    phys_size = resolve_param_ref(phys_size, params)
                    if isinstance(phys_size, (int, float)):
                        phys_size = int(phys_size)
                    else:
                        phys_size = None

                if t.name not in all_targets:
                    all_targets[t.name] = {
                        'name': t.name,
                        'base': abs_base,
                        'size': t.size,
                        'phys_size': phys_size,
                        'sw_access': t.sw_access,
                        'region_type': t.region_type,
                        'role': t.role,
                        'linker_name': t.name.upper(),
                    }

                # Recurse into child instances for this target
                if t.instance:
                    inst = module.get_instance(t.instance)
                    if inst and inst.resolved_module and inst.resolved_module.interconnects:
                        self._stitch_module(
                            inst.resolved_module, abs_base, params,
                            all_targets, all_init_data
                        )

    # -----------------------------------------------------------------------
    # CPU initiator data
    # -----------------------------------------------------------------------

    def _build_cpu_initiator_data(self, stitched: dict, cpu_init: str) -> dict:
        """Get the stitched initiator data for the CPU."""
        init_data = stitched['initiator_data'].get(cpu_init)
        if init_data is None:
            available = list(stitched['initiator_data'].keys())
            raise ValueError(
                f"CPU initiator '{cpu_init}' not found in stitched address map. "
                f"Available: {available}"
            )
        return init_data

    # -----------------------------------------------------------------------
    # Memory region helpers
    # -----------------------------------------------------------------------

    def _derive_memory_regions(self, stitched: dict) -> List[dict]:
        """Extract memory region metadata from stitched targets."""
        regions = []
        for t in stitched['targets']:
            rt = t.get('region_type')
            if rt not in ('memory', 'periph', 'peripheral'):
                continue
            # Normalize region_type
            if rt == 'periph':
                rt = 'peripheral'
            regions.append({
                'target': t['name'],
                'region_type': rt,
                'linker_name': t.get('linker_name', t['name'].upper()),
                'software_access': t.get('sw_access', 'rwx'),
                'phys_size': t.get('phys_size'),
                'role': t.get('role'),
            })
        return regions

    def _find_memory_region(self, regions: List[dict], target_name: str) -> Optional[dict]:
        """Find a memory region by target name."""
        for mr in regions:
            if mr['target'] == target_name:
                return mr
        return None

    # -----------------------------------------------------------------------
    # Address resolution
    # -----------------------------------------------------------------------

    def _resolve_address(self, target_name: str, address_select: str,
                         init_data: dict,
                         target_bases: Optional[Dict[str, int]] = None) -> int:
        """Resolve a target's base address given an address selection policy.

        For 'default', uses the canonical base from the interconnect target definition
        (via target_bases lookup). For 'alias' and 'remapped', uses the initiator's
        address map to find alternative address windows.
        """
        if address_select == 'default' and target_bases and target_name in target_bases:
            return target_bases[target_name]

        if address_select == 'remapped':
            regions = self._compute_effective_map(init_data, {0: True})
            for r in regions:
                if r['interface'] == target_name and r['source'] == 'remap_region':
                    return int(r['mem_lo'], 16)
            # Fallback: remap overlay at 0x00000000 (common for instruction memory)
            for r in regions:
                if r['interface'] == target_name:
                    return int(r['mem_lo'], 16)
            raise ValueError(f"Cannot resolve remapped address for target '{target_name}'")

        # For alias, use no-remap map
        regions = self._compute_effective_map(init_data, {})
        target_regions = [r for r in regions if r['interface'] == target_name]

        if not target_regions:
            raise ValueError(f"Target '{target_name}' not found in address map")

        if address_select == 'alias':
            # Try region explicitly marked as alias
            for r in target_regions:
                if r.get('remapping') == 'alias':
                    return int(r['mem_lo'], 16)
            # Try the second address window
            if len(target_regions) >= 2:
                return int(target_regions[1]['mem_lo'], 16)
            raise ValueError(f"Cannot resolve alias address for target '{target_name}'")

        # Fallback for default without target_bases: lowest canonical entry
        for r in target_regions:
            if (r['source'] == 'address_region'
                    and r.get('remapping') != 'alias'):
                return int(r['mem_lo'], 16)

        return int(target_regions[0]['mem_lo'], 16)

    def _compute_effective_map(self, init_data: dict,
                               remap_config: Dict[int, bool]) -> List[dict]:
        """Compute effective address map (reuse AHB backend logic)."""
        from .ahb import SoCAhbBackend
        dummy = SoCAhbBackend.__new__(SoCAhbBackend)
        dummy.top = self.top
        return dummy._compute_effective_address_map(init_data, remap_config)

    # -----------------------------------------------------------------------
    # Context builders
    # -----------------------------------------------------------------------

    def _build_linker_context(self, fw: Firmware, init_data: dict,
                              memory_regions: List[dict],
                              target_bases: Dict[str, int]) -> Dict[str, list]:
        """Build linker MEMORY block context for each linker_profile."""
        profiles = {}
        for profile in fw.linker_profiles:
            regions = []
            for lr in profile.regions:
                mr = self._find_memory_region(memory_regions, lr.target)
                if mr is None:
                    print(f"  WARNING: target '{lr.target}' has no region_type, skipping")
                    continue

                origin = self._resolve_address(lr.target, lr.address_select, init_data, target_bases)

                phys_size = lr.phys_size
                if phys_size is None:
                    phys_size = mr.get('phys_size')
                if phys_size is None:
                    print(f"  WARNING: no phys_size for target '{lr.target}' in "
                          f"profile '{profile.name}', skipping")
                    continue
                if isinstance(phys_size, str):
                    phys_size = int(phys_size, 0)

                size_adjust = lr.size_adjust or 0
                length = phys_size + size_adjust

                linker_name = lr.linker_name or mr.get('linker_name', lr.target.upper())
                attrs = lr.software_access or mr.get('software_access', 'rwx')

                size_kb = length // 1024
                if size_kb >= 1024:
                    comment = f"{size_kb // 1024}MB"
                elif size_kb > 0:
                    comment = f"{size_kb}K"
                else:
                    comment = f"{length} bytes"

                regions.append({
                    'name': linker_name,
                    'attrs': attrs,
                    'origin': f"0x{origin:08X}",
                    'length': f"0x{length:X}",
                    'comment': comment,
                })
            profiles[profile.name] = regions
        return profiles

    def _build_memmap_context(self, fw: Firmware, init_data: dict,
                              memory_regions: List[dict],
                              target_bases: Dict[str, int]) -> dict:
        """Build C header context with base address defines."""
        memory_defines = []
        for mr in memory_regions:
            target = mr['target']
            role = mr.get('role') or mr['region_type']
            linker_name = mr['linker_name']
            rt = mr['region_type']

            try:
                default_addr = self._resolve_address(target, 'default', init_data, target_bases)
            except ValueError:
                continue

            prefix = self.top.name.upper()
            memory_defines.append({
                'define_name': f"{prefix}_{linker_name}_BASE",
                'base': f"0x{default_addr:08X}",
                'comment': f"{linker_name} ({role})",
            })

            if rt == 'memory':
                phys_size = mr.get('phys_size')
                if phys_size is not None:
                    memory_defines.append({
                        'define_name': f"{prefix}_{linker_name}_SIZE",
                        'base': f"0x{phys_size:08X}",
                        'comment': f"{linker_name} physical size",
                    })

                try:
                    alias_addr = self._resolve_address(target, 'alias', init_data, target_bases)
                    if alias_addr != default_addr:
                        memory_defines.append({
                            'define_name': f"{prefix}_{linker_name}_ALIAS",
                            'base': f"0x{alias_addr:08X}",
                            'comment': f"{linker_name} alias",
                        })
                except ValueError:
                    pass

                try:
                    remap_addr = self._resolve_address(target, 'remapped', init_data, target_bases)
                    if remap_addr != default_addr:
                        memory_defines.append({
                            'define_name': f"{prefix}_{linker_name}_REMAP",
                            'base': f"0x{remap_addr:08X}",
                            'comment': f"{linker_name} remapped",
                        })
                except ValueError:
                    pass

        return {
            'guard_name': f"{self.top.name.upper()}_MEMMAP_GENERATED_H",
            'memory_regions': memory_defines,
            'config_params': [],
        }

    def _build_makefile_context(self, fw: Firmware, init_data: dict,
                                memory_regions: List[dict],
                                linker_ctx: Dict[str, list],
                                target_bases: Dict[str, int]) -> dict:
        """Build Makefile include context."""
        region_vars = []
        for mr in memory_regions:
            target = mr['target']
            linker_name = mr['linker_name']
            try:
                default_addr = self._resolve_address(target, 'default', init_data, target_bases)
            except ValueError:
                continue
            phys_size = mr.get('phys_size') if mr['region_type'] == 'memory' else None
            region_vars.append({
                'var_name': linker_name,
                'base': f"0x{default_addr:08X}",
                'size': f"0x{phys_size:X}" if phys_size else "0x0",
            })

        profile_vars = {}
        for pname, regions in linker_ctx.items():
            ro_base = "0x00000000"
            rw_base = "0x00000000"
            for r in regions:
                if 'r' in r['attrs'] and 'w' not in r['attrs']:
                    ro_base = r['origin']
                elif 'w' in r['attrs']:
                    rw_base = r['origin']
            profile_vars[pname] = {'ro_base': ro_base, 'rw_base': rw_base}

        hex_adjust = {}
        if fw.hex_adjust:
            for adj_name, adj_cfg in fw.hex_adjust.items():
                target = adj_cfg['target']
                addr_select = adj_cfg.get('address_select', 'default')
                try:
                    addr = self._resolve_address(target, addr_select, init_data, target_bases)
                    hex_adjust[adj_name] = f"-0x{addr:08X}"
                except ValueError:
                    pass

        adp_cfg = fw.adp or {}
        adp_addr = "0x00000000"
        if adp_cfg:
            target = adp_cfg['upload_target']
            addr_select = adp_cfg.get('address_select', 'default')
            try:
                addr = self._resolve_address(target, addr_select, init_data, target_bases)
                adp_addr = f"0x{addr:08X}"
            except ValueError:
                pass

        return {
            'region_vars': region_vars,
            'profile_vars': profile_vars,
            'hex_adjust': hex_adjust,
            'adp_upload_address': adp_addr,
        }

    def _build_adp_context(self, fw: Firmware, init_data: dict,
                           target_bases: Dict[str, int] = None) -> dict:
        """Build ADP context for Verilog and Python outputs."""
        adp_cfg = fw.adp or {}
        if not adp_cfg:
            return {
                'adp_address_hex': '00000000',
                'adp_nibbles': [],
                'adp_upload_address_python': '0x00000000',
            }

        target = adp_cfg['upload_target']
        addr_select = adp_cfg.get('address_select', 'default')
        try:
            addr = self._resolve_address(target, addr_select, init_data, target_bases)
        except ValueError:
            addr = 0

        hex_str = f"{addr:08X}"
        nibbles = [(i, ch) for i, ch in enumerate(hex_str)]

        return {
            'adp_address_hex': hex_str.lower(),
            'adp_nibbles': nibbles,
            'adp_upload_address_python': f"0x{hex_str}",
        }
