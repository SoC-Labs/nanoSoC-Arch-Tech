"""AHB interconnect backend — generates bus matrix XML, SV wrapper, flist, and config package.

Produces the same output files as the standalone ahb_interconnect_tool, but driven
directly from the soc_model data structures instead of separate YAML files.

Supports both AHB and APB protocol targets. APB targets have a cmsdk_ahb_to_apb
bridge and (optionally) a cmsdk_apb_slave_mux inlined into the wrapper; their APB
slave ports are exposed at the module boundary instead.

Generated files per interconnect (with gen: True):
  - ARM BuildBusMatrix XML configuration
  - SystemVerilog interconnect wrapper (with inline APB bridges if applicable)
  - Verilog filelist for simulation/synthesis
  - SystemVerilog config package with address constants
  - Bus matrix RTL via ARM BuildBusMatrix.pl (when arm_ip_library_path is provided)
"""

import datetime
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ..model import (
    Interconnect, InterconnectInitiator, InterconnectInitiatorTarget,
    InterconnectTarget, Module,
)
from ..utils import resolve_param_ref, flatten_params

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    Environment = None
    FileSystemLoader = None

# Templates and interfaces bundled with this package
_BACKEND_DIR = Path(__file__).resolve().parent
_TEMPLATE_DIR = _BACKEND_DIR / 'templates'
_INTERFACES_DIR = _BACKEND_DIR / 'interfaces'

# AHB-Lite interface defaults (from interfaces/ahb_lite.yaml)
_AHB_LITE_DEFAULTS = {
    'architecture_version': 'ahb2',
    'arbitration_scheme': 'burst',
    'routing_data_width': 32,
    'routing_address_width': 32,
    'user_signal_width': 0,
}

# Number of APB mux ports in cmsdk_apb_slave_mux (fixed by CMSDK IP)
_APB_MUX_PORTS = 16

# Max tag name length for XML column alignment
_REGION_TAG_WIDTH = len("address_region")  # 14 chars


def _to_hex(val) -> str:
    """Normalise an address value to an 8-digit lowercase hex string."""
    if isinstance(val, int):
        return f"{val:08x}"
    return f"{int(str(val).strip(), 16):08x}"


def _mem_hi(base_hex: str, size_hex: str) -> str:
    """Compute mem_hi (inclusive end address) from base and size hex strings."""
    return f"{int(base_hex, 16) + int(size_hex, 16) - 1:08x}"


def _transform_name(name: str) -> str:
    """Transform lowercase name to uppercase XML name with leading underscore."""
    return f"_{name.upper()}"


# ---------------------------------------------------------------------------
# APB helpers (replicated from ahb_interconnect_tool)
# ---------------------------------------------------------------------------

def _build_apb_slot_list(apb_cfg: Dict[str, Any], n_slots: int = _APB_MUX_PORTS) -> List[dict]:
    """Expand the slaves list from an APB config into a full n_slots list.

    Unlisted slots are auto-filled as gaps (PORT_ENABLE=0).
    """
    defined = {int(s['slot']): s for s in apb_cfg.get('slaves', [])}
    slots = []
    for i in range(n_slots):
        if i in defined:
            s = defined[i]
            name       = str(s['name'])
            enabled    = bool(s.get('enabled', True))
            comment    = str(s.get('comment', ''))
            is_gap     = False
            param_name = name.upper()
        else:
            name       = f'gap_{i}'
            enabled    = False
            comment    = 'Reserved'
            is_gap     = True
            param_name = f'GAP_{i}'
        slots.append({
            'slot':       i,
            'name':       name,
            'enabled':    enabled,
            'is_gap':     is_gap,
            'param_name': param_name,
            'comment':    comment,
        })
    return slots


def _build_apb_target_context(target: InterconnectTarget) -> dict:
    """Build Jinja2 context dict for one APB target from the model.

    Uses target.apb_config for bridge/mux parameters.
    """
    name = target.name
    apb_cfg = target.apb_config or {}

    ahb_addr_width = int(apb_cfg.get('ahb_addr_width', 16))
    big_endian     = bool(apb_cfg.get('big_endian_support', False))

    slaves = apb_cfg.get('slaves', [])
    if slaves:
        decode_msb  = int(apb_cfg.get('decode_msb', 15))
        decode_lsb  = int(apb_cfg.get('decode_lsb', 12))
        region_base = apb_cfg.get('region_base', target.base)
        slots       = _build_apb_slot_list(apb_cfg)
        has_mux     = True
    else:
        decode_msb  = int(apb_cfg.get('decode_msb', 11))
        decode_lsb  = int(apb_cfg.get('decode_lsb', 0))
        region_base = apb_cfg.get('region_base', target.base)
        slots       = []
        has_mux     = False

    n_slots   = 1 << (decode_msb - decode_lsb + 1)
    slot_size = 1 << decode_lsb

    base_int = int(region_base) if isinstance(region_base, int) else int(str(region_base), 16)
    for s in slots:
        s['ahb_addr'] = f"0x{base_int + s['slot'] * slot_size:08x}"
        s['paddr_offset'] = f"0x{s['slot'] * slot_size:08x}"

    return {
        'name':             name,
        'ahb_addr_width':   ahb_addr_width,
        'big_endian':       big_endian,
        'decode_msb':       decode_msb,
        'decode_lsb':       decode_lsb,
        'region_base':      f"0x{base_int:08x}",
        'n_slots':          n_slots,
        'slot_size':        f"0x{slot_size:04x}",
        'slots':            slots,
        'has_mux':          has_mux,
    }


class SoCAhbBackend:
    """Generates AHB interconnect RTL and configuration from the SoC model."""

    def __init__(self, top_module: Module, arm_ip_library_path: Optional[str] = None):
        self.top = top_module
        self.arm_ip_library_path = arm_ip_library_path

    def generate_all(self, build_dir: Path, hierarchy_prefix: str = ''):
        """Generate all AHB interconnect outputs for every gen: True interconnect.

        Walks the module hierarchy. For each interconnect with gen=True, creates
        a subdirectory named by the hierarchical path and generates all outputs.

        Returns list of (ic_name, output_dir) tuples.
        """
        generated = []
        self._walk_module(self.top, build_dir, hierarchy_prefix or self.top.name, generated)
        return generated

    def _walk_module(self, module: Module, build_dir: Path, hier_path: str,
                     generated: list):
        """Recursively walk module hierarchy looking for gen: True interconnects."""
        for ic in module.interconnects:
            if ic.gen:
                ic_hier = f"{hier_path}_{ic.name}"
                ic_dir = build_dir / ic_hier
                ic_dir.mkdir(parents=True, exist_ok=True)

                params = module.flat_params
                self._generate_interconnect(ic, ic_dir, params)
                generated.append((ic.name, ic_dir))

        for inst in module.instances:
            if inst.resolved_module:
                child_hier = f"{hier_path}_{inst.instance_name}"
                self._walk_module(inst.resolved_module, build_dir, child_hier, generated)

    def _generate_interconnect(self, ic: Interconnect, output_dir: Path,
                               parent_params: Dict[str, Any]):
        """Generate all outputs for a single interconnect."""
        # Resolve interconnect params
        ic_params = {}
        for k, v in ic.params.items():
            ic_params[k] = resolve_param_ref(v, parent_params)

        addr_width = ic_params.get('SYS_ADDR_W', _AHB_LITE_DEFAULTS['routing_address_width'])
        data_width = ic_params.get('SYS_DATA_W', _AHB_LITE_DEFAULTS['routing_data_width'])

        # Directories
        xml_dir = output_dir / 'xml'
        verilog_dir = output_dir / 'verilog'
        flist_dir = output_dir / 'flist'
        address_maps_dir = output_dir / 'address_maps'
        logs_dir = output_dir / 'logs'
        ipxact_dir = output_dir / 'ipxact'

        for d in [xml_dir, verilog_dir, flist_dir, address_maps_dir, logs_dir, ipxact_dir]:
            d.mkdir(parents=True, exist_ok=True)

        # Derive module prefix from interconnect name
        # e.g. nanosoc_ahb_interconnect -> nanosoc
        module_prefix = ic.name.replace('_ahb_interconnect', '').replace('_interconnect', '')

        # Generate XML
        xml_content = self._generate_xml(ic, module_prefix, addr_width, data_width)
        xml_path = xml_dir / f"{ic.name}.xml"
        xml_path.write_text(xml_content)
        print(f"  XML: {xml_path}")

        # Generate address maps (text)
        maps_content = self._generate_address_maps_text(ic, addr_width)
        maps_path = address_maps_dir / f"{ic.name}_address_maps.txt"
        maps_path.write_text(maps_content)
        print(f"  Address maps: {maps_path}")

        # Run ARM BuildBusMatrix.pl to generate bus matrix RTL
        self._run_build_bus_matrix(ic, xml_dir, verilog_dir, ipxact_dir, logs_dir)

        # Generate SV wrapper, flist, config package (requires Jinja2)
        if Environment is None:
            print("  WARNING: Jinja2 not available, skipping SV/flist/pkg generation")
            return

        sv_context = self._build_sv_context(ic, module_prefix, addr_width, data_width)
        self._render_template('ahb_interconnect.sv.j2', sv_context,
                              verilog_dir / f"{module_prefix}_interconnect.sv")
        self._render_template('ahb_interconnect.flist.j2', sv_context,
                              flist_dir / f"{module_prefix}_interconnect.flist")

        pkg_context = self._build_pkg_context(ic, module_prefix, addr_width)
        self._render_template('config_pkg.sv.j2', pkg_context,
                              verilog_dir / f"{module_prefix}_config_pkg.sv")

    # -----------------------------------------------------------------------
    # ARM BuildBusMatrix.pl invocation
    # -----------------------------------------------------------------------

    def _run_build_bus_matrix(self, ic: Interconnect, xml_dir: Path,
                              verilog_dir: Path, ipxact_dir: Path,
                              logs_dir: Path):
        """Invoke the ARM BuildBusMatrix.pl Perl script to generate bus matrix RTL.

        Requires ARM_IP_LIBRARY_PATH to be set (either via constructor or env var).
        """
        arm_ip_path = self.arm_ip_library_path or os.environ.get('ARM_IP_LIBRARY_PATH')
        if not arm_ip_path:
            print("  WARNING: ARM_IP_LIBRARY_PATH not set, skipping BuildBusMatrix.pl")
            return

        source_dir = Path(arm_ip_path) / 'latest' / 'Corstone-101' / 'logical' / 'cmsdk_ahb_busmatrix'
        build_script = source_dir / 'bin' / 'BuildBusMatrix.pl'
        verilog_source_dir = source_dir / 'verilog' / 'src'
        ipxact_source_dir = source_dir / 'ipxact' / 'src'

        if not build_script.exists():
            print(f"  WARNING: BuildBusMatrix.pl not found at {build_script}")
            return

        log_file = logs_dir / f"{ic.name}.log"

        cmd = [
            'perl', str(build_script),
            '-notimescales', '-over', '-verbose',
            '-xmldir', str(xml_dir),
            '-cfg', f"{ic.name}.xml",
            f'-srcdir={verilog_source_dir}',
            f'-tgtdir={verilog_dir}',
            '-ipxact',
            f'-ipxactsrcdir={ipxact_source_dir}',
            f'-ipxacttgtdir={ipxact_dir}',
        ]

        print(f"  Running BuildBusMatrix.pl for {ic.name}...")
        try:
            result = subprocess.run(
                cmd,
                cwd=str(source_dir),
                capture_output=True,
                text=True,
                timeout=120,
            )
            # Write log regardless of success/failure
            with open(log_file, 'w') as f:
                f.write(f"Command: {' '.join(cmd)}\n\n")
                if result.stdout:
                    f.write("=== STDOUT ===\n")
                    f.write(result.stdout)
                if result.stderr:
                    f.write("\n=== STDERR ===\n")
                    f.write(result.stderr)

            if result.returncode != 0:
                print(f"  WARNING: BuildBusMatrix.pl exited with code {result.returncode}")
                print(f"  Log: {log_file}")
            else:
                print(f"  BuildBusMatrix: {verilog_dir / ic.name}")
        except FileNotFoundError:
            print("  WARNING: perl not found, cannot run BuildBusMatrix.pl")
        except subprocess.TimeoutExpired:
            print("  WARNING: BuildBusMatrix.pl timed out after 120s")

    # -----------------------------------------------------------------------
    # XML generation
    # -----------------------------------------------------------------------

    def _build_initiator_data(self, ic: Interconnect) -> Dict[str, dict]:
        """Build per-initiator address region data from the interconnect model."""
        target_defs = {t.name: t for t in ic.targets}

        result = {}
        for init in ic.initiators:
            connections = []
            addr_tuples = []  # (addr_int, name, lo_hex, hi_hex, remapping)
            remap_entries = []

            for init_tgt in init.targets:
                tgt_def = target_defs.get(init_tgt.name)
                if tgt_def is None:
                    continue

                connections.append(init_tgt.name)
                default_base = _to_hex(tgt_def.base)
                default_size = _to_hex(tgt_def.size)

                if init_tgt.visibility:
                    # Visibility fully describes all windows for this initiator
                    remap_spec = next(
                        (v.get('remap') for v in init_tgt.visibility
                         if isinstance(v.get('remap'), dict)
                         and v['remap'].get('remapping', False)),
                        None
                    )
                    default_remapping = (remap_spec.get('remap_behaviour', 'alias')
                                         if remap_spec else 'none')

                    for vis in init_tgt.visibility:
                        v_base = _to_hex(vis['base'])
                        v_size = _to_hex(vis.get('aperture', tgt_def.size))
                        remap = vis.get('remap')

                        if isinstance(remap, dict) and remap.get('remapping', False):
                            remap_entries.append({
                                'interface': init_tgt.name,
                                'mem_lo': v_base,
                                'mem_hi': _mem_hi(v_base, v_size),
                                'bit': remap['remap_bit'],
                            })
                        else:
                            vis_remapping = vis.get('remap_behaviour', default_remapping)
                            addr_tuples.append((
                                int(v_base, 16), init_tgt.name,
                                v_base, _mem_hi(v_base, v_size), vis_remapping
                            ))
                else:
                    # No visibility — use target's canonical address
                    addr_tuples.append((
                        tgt_def.base, init_tgt.name,
                        default_base, _mem_hi(default_base, default_size), 'none'
                    ))

            addr_tuples.sort(key=lambda x: x[0])

            result[init.name] = {
                'name': init.name,
                'connections': connections,
                'address_regions': [
                    {'interface': t[1], 'mem_lo': t[2], 'mem_hi': t[3], 'remapping': t[4]}
                    for t in addr_tuples
                ],
                'remap_regions': remap_entries,
            }

        return result

    def _generate_xml(self, ic: Interconnect, module_prefix: str,
                      addr_width: int, data_width: int) -> str:
        """Generate ARM BuildBusMatrix XML configuration."""
        initiator_data = self._build_initiator_data(ic)

        out = []
        out.append('<?xml version="1.0" encoding="iso-8859-1" ?>')
        out.append('')
        out.append('<!--//----------------------------------------------------------------------------- -->')
        out.append('<!--// Auto-generated AHB Bus Matrix XML configuration                             -->')
        out.append('<!--// Generated by soc_model AHB backend                                          -->')
        out.append('<!--//----------------------------------------------------------------------------- -->')
        out.append('')
        out.append('<!-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -  -->')
        out.append('<!--  The confidential and proprietary information contained in this file               -->')
        out.append('<!--  may only be used by a person authorised under and to the extent                   -->')
        out.append('<!--  permitted by a subsisting licensing agreement from Arm Limited or its affiliates. -->')
        out.append('<!--                                                                                    -->')
        out.append('<!--             (C) COPYRIGHT 2001-2013 Arm Limited or its affiliates.                 -->')
        out.append('<!--                 ALL RIGHTS RESERVED                                                -->')
        out.append('<!--                                                                                    -->')
        out.append('<!--  This entire notice must be reproduced on all copies of this file                  -->')
        out.append('<!--  and copies of this file may only be made by a person if such person               -->')
        out.append('<!--  is permitted to do so under the terms of a subsisting license                     -->')
        out.append('<!--  agreement from Arm Limited or its affiliates.                                     -->')
        out.append('<!-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -  -->')
        out.append('')
        out.append('<cfgfile>')
        out.append('')
        out.append('  <!-- - - - - *** DO NOT MODIFY ABOVE THIS LINE *** - - - - - - - - - - -  -->')
        out.append('')

        # Global definitions
        out.append('  <!-- Global definitions -->')
        out.append('')
        out.append(f'  <architecture_version>{_AHB_LITE_DEFAULTS["architecture_version"]}</architecture_version>')
        out.append(f'  <arbitration_scheme>{_AHB_LITE_DEFAULTS["arbitration_scheme"]}</arbitration_scheme>')
        out.append(f'  <routing_data_width>{data_width}</routing_data_width>')
        out.append(f'  <routing_address_width>{addr_width}</routing_address_width>')
        out.append(f'  <user_signal_width>{_AHB_LITE_DEFAULTS["user_signal_width"]}</user_signal_width>')
        out.append(f'  <bus_matrix_name>{ic.name}</bus_matrix_name>')
        out.append(f'  <input_stage_name>{module_prefix}_inititator_input</input_stage_name>')
        out.append(f'  <matrix_decode_name>{module_prefix}_matrix_decode</matrix_decode_name>')
        out.append(f'  <output_arbiter_name>{module_prefix}_arbiter</output_arbiter_name>')
        out.append(f'  <output_stage_name>{module_prefix}_target_output< /output_stage_name>')
        out.append('')
        out.append('')

        # Slave interfaces (initiator ports)
        out.append('  <!-- Slave interface definitions -->')
        out.append('')
        for init in ic.initiators:
            init_data = initiator_data[init.name]
            out.extend(self._build_xml_initiator_block(init_data))
            out.append('')

        # Master interfaces (target ports)
        out.append('  <!-- Master interface definitions -->')
        out.append('')
        for t in ic.targets:
            xml_name = _transform_name(t.name)
            out.append(f'  <master_interface name="{xml_name}"/>')

        out.append('')
        out.append('  <!-- - - - - *** DO NOT MODIFY BELOW THIS LINE *** - - - - - - - - - - - -->')
        out.append('')
        out.append('</cfgfile>')
        out.append('')

        return '\n'.join(out)

    def _build_xml_initiator_block(self, init_data: dict) -> List[str]:
        """Return XML lines for one <slave_interface> block."""
        name = _transform_name(init_data['name'])
        lines = [f'  <slave_interface name="{name}">']

        for conn in init_data.get('connections', []):
            conn_name = _transform_name(conn)
            lines.append(f'    <sparse_connect interface="{conn_name}"/>')

        regions = init_data.get('address_regions', [])
        remap_regions = init_data.get('remap_regions', [])

        if regions or remap_regions:
            all_ifaces = ([_transform_name(r['interface']) for r in regions] +
                          [_transform_name(r['interface']) for r in remap_regions])
            max_len = max(len(i) for i in all_ifaces) if all_ifaces else 0

            for r in regions:
                iface = _transform_name(r['interface'])
                pad = ' ' * (max_len - len(iface))
                tag_pad = ' ' * (_REGION_TAG_WIDTH - len('address_region'))
                lines.append(
                    f"    <address_region{tag_pad} interface=\"{iface}\"{pad}"
                    f" mem_lo='{r['mem_lo']}' mem_hi='{r['mem_hi']}'"
                    f" remapping='{r['remapping']}'/>"
                )

            for r in remap_regions:
                iface = _transform_name(r['interface'])
                pad = ' ' * (max_len - len(iface))
                tag_pad = ' ' * (_REGION_TAG_WIDTH - len('remap_region'))
                lines.append(
                    f"    <remap_region{tag_pad}   interface=\"{iface}\"{pad}"
                    f" mem_lo='{r['mem_lo']}' mem_hi='{r['mem_hi']}'"
                    f" bit='{r['bit']}'/>"
                )

        lines.append('  </slave_interface>')
        return lines

    # -----------------------------------------------------------------------
    # Address maps (text)
    # -----------------------------------------------------------------------

    def _compute_effective_address_map(self, init_data: dict,
                                       remap_config: Dict[int, bool]) -> List[dict]:
        """Compute the effective address map for an initiator given a remap config."""
        effective = []

        # Active remap regions
        for remap in init_data.get('remap_regions', []):
            bit = remap['bit']
            if remap_config.get(bit, False):
                effective.append({
                    'mem_lo': remap['mem_lo'],
                    'mem_hi': remap['mem_hi'],
                    'interface': remap['interface'],
                    'source': 'remap_region',
                    'remapping': 'remap',
                })

        # Address regions
        for region in init_data.get('address_regions', []):
            remapping = region.get('remapping', 'none')
            if remapping == 'move':
                # Check if there's an active remap for the same interface
                has_remap = any(
                    r['source'] == 'remap_region' and r['interface'] == region['interface']
                    for r in effective
                )
                if has_remap:
                    continue
            effective.append({
                'mem_lo': region['mem_lo'],
                'mem_hi': region['mem_hi'],
                'interface': region['interface'],
                'source': 'address_region',
                'remapping': remapping,
            })

        effective.sort(key=lambda x: int(x['mem_lo'], 16))

        # Remove address regions completely covered by remap regions (except aliases)
        final = []
        for r in effective:
            if r['source'] == 'remap_region':
                final.append(r)
            else:
                r_start = int(r['mem_lo'], 16)
                r_end = int(r['mem_hi'], 16)
                covered = False
                for other in effective:
                    if (other['source'] == 'remap_region'
                            and int(other['mem_lo'], 16) <= r_start
                            and r_end <= int(other['mem_hi'], 16)
                            and r.get('remapping') != 'alias'):
                        covered = True
                        break
                if not covered:
                    final.append(r)

        return final

    def _generate_remap_configurations(self, initiator_data: Dict[str, dict]) -> List[Dict[int, bool]]:
        """Generate all possible remap bit configurations."""
        all_bits = set()
        for init_data in initiator_data.values():
            for remap in init_data.get('remap_regions', []):
                all_bits.add(remap['bit'])

        if not all_bits:
            return [{}]

        bits = sorted(all_bits)
        configs = []
        for i in range(2 ** len(bits)):
            config = {}
            for j, bit in enumerate(bits):
                config[bit] = bool(i & (1 << j))
            configs.append(config)
        return configs

    def _generate_address_maps_text(self, ic: Interconnect, addr_width: int) -> str:
        """Generate text-format address maps for all initiators."""
        initiator_data = self._build_initiator_data(ic)
        remap_configs = self._generate_remap_configurations(initiator_data)

        lines = []
        title = f"{ic.name} — Address Maps"
        lines.append(title)
        lines.append('=' * len(title))
        lines.append('')

        for init_name, init_data in initiator_data.items():
            for config in remap_configs:
                regions = self._compute_effective_address_map(init_data, config)

                config_str = ', '.join(
                    f"remap[{bit}]={1 if val else 0}"
                    for bit, val in sorted(config.items())
                )
                if not config_str:
                    config_str = 'no remap bits'

                lines.append(f"Address Map for {init_name} ({config_str})")
                lines.append('=' * 60)
                lines.append('')

                if not regions:
                    lines.append('No accessible regions')
                    lines.append('')
                    continue

                max_iface_len = max(len(r['interface']) for r in regions)
                lines.append(f"{'Start':>10} {'End':>10} {'Size':>8} "
                             f"{'Target':<{max_iface_len}} {'Type'}")
                lines.append('-' * (10 + 10 + 8 + max_iface_len + 15))

                for r in regions:
                    start = int(r['mem_lo'], 16)
                    end = int(r['mem_hi'], 16)
                    size = end - start + 1
                    if size >= 1024 * 1024:
                        size_str = f"{size / (1024 * 1024):.1f}MB"
                    elif size >= 1024:
                        size_str = f"{size / 1024:.1f}KB"
                    else:
                        size_str = f"{size}B"

                    type_str = 'REMAP' if r['source'] == 'remap_region' else 'NORMAL'
                    if r.get('remapping') == 'alias':
                        type_str += ' (alias)'
                    elif r.get('remapping') == 'move':
                        type_str += ' (move)'

                    lines.append(f"{r['mem_lo']:>10} {r['mem_hi']:>10} {size_str:>8} "
                                 f"{r['interface']:<{max_iface_len}} {type_str}")

                lines.append('')

        return '\n'.join(lines)

    # -----------------------------------------------------------------------
    # SV wrapper context
    # -----------------------------------------------------------------------

    def _build_sv_context(self, ic: Interconnect, module_prefix: str,
                          addr_width: int, data_width: int) -> dict:
        """Build Jinja2 template context for the SV wrapper and flist."""
        # Split targets into AHB and APB lists
        ahb_targets = []
        apb_targets = []
        all_targets = []

        for t in ic.targets:
            entry = {'name': t.name, 'protocol': t.protocol}
            all_targets.append(entry)
            if t.protocol == 'apb':
                ctx = _build_apb_target_context(t)
                apb_targets.append(ctx)
            else:
                ahb_targets.append(t.name)

        initiators = [init.name for init in ic.initiators]

        # Column widths use all target names (AHB + APB) since the bus matrix
        # sees all targets as AHB ports regardless of protocol
        all_target_names = [t.name for t in ic.targets]
        sig_col, port_col, inst_col = self._compute_sv_columns(initiators, all_target_names)

        # Tag each APB target with whether it is the last target overall
        for i, t in enumerate(apb_targets):
            t['is_last_target'] = (i == len(apb_targets) - 1)

        # Build flat APB parameter list for module parameters
        apb_params = []
        for t in apb_targets:
            if t['has_mux']:
                for s in [sl for sl in t['slots'] if not sl['is_gap']]:
                    apb_params.append({
                        'name':    f"{t['name'].upper()}_{s['param_name']}_ENABLE",
                        'value':   1 if s['enabled'] else 0,
                        'comment': f"Slot {s['slot']:2d}: {s['comment'] or s['name']}",
                    })
            if t['big_endian']:
                apb_params.append({
                    'name':    f"{t['name'].upper()}_BE",
                    'value':   0,
                    'comment': f"Big endian support for {t['name']}",
                })

        return {
            'module_name': f'{module_prefix}_interconnect',
            'busmatrix_lite_name': f'{ic.name}_lite',
            'interconnect_name': ic.name,
            'module_prefix': module_prefix,
            'initiators': initiators,
            'ahb_targets': ahb_targets,
            'apb_targets': apb_targets,
            'apb_params': apb_params,
            'all_targets': all_targets,
            'addr_width': addr_width,
            'data_width': data_width,
            'sig_col': sig_col,
            'port_col': port_col,
            'inst_col': inst_col,
            'source_yaml': f'soc_model ({ic.name})',
            'template_name': 'ahb_interconnect.sv.j2',
            'generated_date': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        }

    def _build_pkg_context(self, ic: Interconnect, module_prefix: str,
                           addr_width: int) -> dict:
        """Build Jinja2 context for the config package."""
        all_target_info = []
        for t in ic.targets:
            entry = {
                'name': t.name,
                'base': t.base,
                'aperture': t.size,
                'config': None,
            }
            # For APB targets with slots, add sub-target config info
            if t.protocol == 'apb' and t.apb_config:
                apb_cfg = t.apb_config
                slot_configs = {}
                for s in apb_cfg.get('slaves', []):
                    if s.get('config'):
                        slot_configs.update(s['config'])
                if slot_configs:
                    entry['config'] = slot_configs
            all_target_info.append(entry)

        return {
            'package_name': f'{module_prefix}_config_pkg',
            'all_target_info': all_target_info,
            'addr_width': addr_width,
            'source_yaml': f'soc_model ({ic.name})',
            'template_name': 'config_pkg.sv.j2',
            'generated_date': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        }

    def _compute_sv_columns(self, initiator_names: List[str],
                            target_names: List[str]) -> Tuple[int, int, int]:
        """Compute column alignment widths for the SV wrapper template."""
        init_suffixes = ['_haddr,', '_htrans,', '_hwrite,', '_hsize,', '_hburst,',
                         '_hprot,', '_hwdata,', '_hmastlock,', '_hrdata,', '_hready,',
                         '_hresp,']
        target_suffixes = ['_hrdata,', '_hreadyout,', '_hresp,', '_hsel,', '_haddr,',
                           '_htrans,', '_hwrite,', '_hsize,', '_hburst,', '_hprot,',
                           '_hwdata,', '_hmastlock,', '_hreadymux,']

        names = initiator_names + target_names
        if not names:
            return 24, 24, 26

        all_sigs = ([n + s for n in initiator_names for s in init_suffixes] +
                    [n + s for n in target_names for s in target_suffixes])
        sig_col = max(24, max(len(s) for s in all_sigs) + 2) if all_sigs else 24

        init_prefixes = ['.HADDR_', '.HTRANS_', '.HWRITE_', '.HSIZE_', '.HBURST_',
                         '.HPROT_', '.HWDATA_', '.HMASTLOCK_', '.HRDATA_', '.HREADY_',
                         '.HRESP_']
        target_prefixes = ['.HRDATA_', '.HREADYOUT_', '.HRESP_', '.HSEL_', '.HADDR_',
                           '.HTRANS_', '.HWRITE_', '.HSIZE_', '.HBURST_', '.HPROT_',
                           '.HWDATA_', '.HMASTLOCK_', '.HREADYMUX_']
        system_ports = ['.HCLK', '.HRESETn', '.SCANENABLE', '.SCANINHCLK',
                        '.SCANOUTHCLK', '.REMAP']

        all_ports = ([p + n.upper() for n in initiator_names for p in init_prefixes] +
                     [p + n.upper() for n in target_names for p in target_prefixes] +
                     system_ports)
        port_col = max(24, max(len(p) for p in all_ports) + 2) if all_ports else 24

        inst_init_sfx = ['_haddr),', '_htrans),', '_hwrite),', '_hsize),',
                         '_hburst),', '_hprot),', '_hwdata),', '_hmastlock),',
                         '_hrdata),', '_hready),', '_hresp),']
        inst_tgt_sfx = ['_hrdata),', '_hreadyout),', '_hresp),', '_hsel),',
                         '_haddr),', '_htrans),', '_hwrite),', '_hsize),',
                         '_hburst),', '_hprot),', '_hwdata),', '_hmastlock),',
                         '_hreadymux),']

        all_inst = (['(' + n + s for n in initiator_names for s in inst_init_sfx] +
                    ['(' + n + s for n in target_names for s in inst_tgt_sfx])
        inst_col = max(26, max(len(s) for s in all_inst) + 2) if all_inst else 26

        return sig_col, port_col, inst_col

    # -----------------------------------------------------------------------
    # Template rendering
    # -----------------------------------------------------------------------

    def _render_template(self, template_name: str, context: dict, output_path: Path):
        """Render a Jinja2 template to a file."""
        env = Environment(
            loader=FileSystemLoader(str(_TEMPLATE_DIR)),
            keep_trailing_newline=True,
            trim_blocks=True,
            lstrip_blocks=True,
        )
        env.filters['ljust'] = lambda s, n: s.ljust(n)
        output = env.get_template(template_name).render(**context)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output)
        print(f"  Generated: {output_path}")
