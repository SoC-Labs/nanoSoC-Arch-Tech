"""Top-level SV module backend — generates the structural nanosoc.sv from the SoC model.

Produces a purely structural SystemVerilog top-level module where:
  - All combinational glue logic is expressed as helper module instantiations
  - AHB/AXIS/APB bus bundles are auto-expanded from protocol definitions
  - Every wire has provenance comments (driver/consumer)

Generated files:
  - nanosoc.sv — top-level structural module
"""

import datetime
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from ..model import (
    Connection, GlueLogicEntry, Instance, Interconnect,
    InterconnectInitiator, InterconnectTarget, Interface, Module,
)
from ..utils import parse_bit_slice, parse_conn_ref, resolve_param_ref, flatten_params

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    Environment = None
    FileSystemLoader = None

_BACKEND_DIR = Path(__file__).resolve().parent
_TEMPLATE_DIR = _BACKEND_DIR / 'templates'

# ---------------------------------------------------------------------------
# Protocol signal definitions — maps interface type to its constituent signals
# ---------------------------------------------------------------------------

# AHB initiator (master) signals: (name_suffix, direction_from_initiator, width_expr)
AHB_INITIATOR_SIGNALS = [
    ('haddr',     'out', 'SYS_ADDR_W'),
    ('htrans',    'out', '2'),
    ('hwrite',    'out', '1'),
    ('hsize',     'out', '3'),
    ('hburst',    'out', '3'),
    ('hprot',     'out', '4'),
    ('hwdata',    'out', 'SYS_DATA_W'),
    ('hmastlock', 'out', '1'),
    ('hrdata',    'in',  'SYS_DATA_W'),
    ('hready',    'in',  '1'),
    ('hresp',     'in',  '1'),
]

# AHB target (slave) signals: (name_suffix, direction_from_target, width_expr)
AHB_TARGET_SIGNALS = [
    ('hsel',      'in',  '1'),
    ('haddr',     'in',  'SYS_ADDR_W'),
    ('htrans',    'in',  '2'),
    ('hwrite',    'in',  '1'),
    ('hsize',     'in',  '3'),
    ('hburst',    'in',  '3'),
    ('hprot',     'in',  '4'),
    ('hwdata',    'in',  'SYS_DATA_W'),
    ('hmastlock', 'in',  '1'),
    ('hready',    'in',  '1'),
    ('hrdata',    'out', 'SYS_DATA_W'),
    ('hresp',     'out', '1'),
    ('hreadyout', 'out', '1'),
]

# AXIS stream signals: (name_suffix, direction_from_source, width_expr)
AXIS_SIGNALS = [
    ('tvalid', 'out', '1'),
    ('tready', 'in',  '1'),
    ('tdata',  'out', 'SYS_DATA_W'),
    ('tstrb',  'out', '4'),
    ('tlast',  'out', '1'),
]

# AXIS byte signals
AXIS_BYTE_SIGNALS = [
    ('tvalid', 'out', '1'),
    ('tready', 'in',  '1'),
    ('tdata',  'out', '8'),
]

# SWD signals (from receiver perspective)
SWD_SIGNALS = [
    ('swdi',   'in',  '1'),
    ('swclk',  'in',  '1'),
    ('swdo',   'out', '1'),
    ('swdoen', 'out', '1'),
]

# GPIO signals
GPIO_SIGNALS = [
    ('in',     'in',  'WIDTH'),
    ('out',    'out', 'WIDTH'),
    ('outen',  'out', 'WIDTH'),
]


def _width_str(w) -> str:
    """Convert width to SV declaration string. Returns '' for 1-bit, '[N-1:0]' otherwise."""
    if isinstance(w, int):
        return '' if w == 1 else f'[{w-1}:0]'
    if isinstance(w, str):
        # Strip $ prefix from param references
        w_clean = w.lstrip('$')
        try:
            v = int(w_clean)
            return '' if v == 1 else f'[{v-1}:0]'
        except ValueError:
            return f'[{w_clean}-1:0]'
    return ''


def _param_width_str(w) -> str:
    """Width string for parameterised widths like 'SYS_ADDR_W'."""
    if isinstance(w, int):
        return '' if w == 1 else f'[{w-1}:0]'
    if isinstance(w, str):
        w_clean = w.lstrip('$')
        # Try to parse as integer first
        try:
            v = int(w_clean)
            return '' if v == 1 else f'[{v-1}:0]'
        except ValueError:
            return f'[{w_clean}-1:0]'
    return ''


class SoCTopLevelBackend:
    """Generates the top-level structural SV module from the SoC model."""

    def __init__(self, top_module: Module):
        self.top = top_module
        self.flat_params = flatten_params({n: p.default for n, p in top_module.params.items()})

    def generate(self, output_dir: Path) -> Optional[Path]:
        """Generate nanosoc.sv in output_dir. Returns the path to the generated file."""
        if Environment is None:
            print("  WARNING: jinja2 not available — skipping top-level generation")
            return None

        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        env = Environment(
            loader=FileSystemLoader(str(_TEMPLATE_DIR)),
            trim_blocks=True,
            lstrip_blocks=True,
            keep_trailing_newline=True,
        )
        template = env.get_template('nanosoc_toplevel.sv.j2')

        ctx = self._build_context()
        content = template.render(**ctx)

        out_path = output_dir / f'{self.top.name}.sv'
        out_path.write_text(content)

        # Also generate the flist
        flist_dir = output_dir.parent / 'flist'
        flist_dir.mkdir(parents=True, exist_ok=True)
        flist_template = env.get_template('nanosoc_toplevel.flist.j2')
        flist_content = flist_template.render(**ctx)
        flist_path = flist_dir / f'{self.top.name}_toplevel.flist'
        flist_path.write_text(flist_content)

        return out_path

    def _build_context(self) -> Dict[str, Any]:
        """Build the full template context."""
        return {
            'module_name': self.top.name,
            'generated_date': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'params': self._build_params(),
            'ports': self._build_ports(),
            'internal_wires': self._build_internal_wires(),
            'bus_wires': self._build_bus_wires(),
            'glue_instances': self._build_glue_instances(),
            'instances': self._build_instances(),
            'interconnect': self._build_interconnect(),
        }

    def _build_params(self) -> List[Dict[str, Any]]:
        """Build parameter list for module declaration."""
        params = []
        for name, p in self.top.params.items():
            default = p.default
            # Format large integers as sized hex to avoid signed overflow warnings
            if p.type == 'int' and isinstance(default, int) and default >= 2**31:
                default = f"32'h{default:08X}"
            params.append({
                'name': name,
                'type': p.type,
                'default': default,
                'desc': p.desc,
            })
        return params

    def _build_ports(self) -> List[Dict[str, Any]]:
        """Build port list, expanding protocol interfaces into individual signals."""
        ports = []
        for iface in self.top.interfaces:
            if iface.type == 'wire':
                width = iface.params.get('WIDTH', 1)
                direction = 'input' if iface.direction == 'in' else 'output'
                ports.append({
                    'name': iface.name,
                    'direction': direction,
                    'width': width,
                    'width_str': _width_str(width),
                    'desc': iface.desc,
                })
            elif iface.type == 'swd':
                for sig_name, sig_dir, sig_width in SWD_SIGNALS:
                    direction = 'input' if sig_dir == 'in' else 'output'
                    ports.append({
                        'name': f'{iface.name[:-4]}_{sig_name}' if iface.name.endswith('_swd') else f'{iface.name}_{sig_name}',
                        'direction': direction,
                        'width': int(sig_width),
                        'width_str': '',
                        'desc': f'{iface.desc} — {sig_name}',
                    })
            elif iface.type == 'gpio':
                width = iface.params.get('WIDTH', 16)
                for sig_name, sig_dir, _ in GPIO_SIGNALS:
                    direction = 'input' if sig_dir == 'in' else 'output'
                    ports.append({
                        'name': f'{iface.name}_{sig_name}',
                        'direction': direction,
                        'width': width,
                        'width_str': _width_str(width),
                        'desc': f'{iface.desc} — {sig_name}',
                    })
            elif iface.type == 'ahb':
                self._expand_ahb_port(iface, ports)
            elif iface.type in ('axis', 'axis_stream'):
                self._expand_axis_port(iface, ports, full=True)
            elif iface.type == 'axis_byte':
                self._expand_axis_port(iface, ports, full=False)
        return ports

    def _expand_ahb_port(self, iface: Interface, ports: List[Dict]):
        """Expand an AHB interface into individual port signals."""
        is_target = iface.direction in ('target', 'in')
        signals = AHB_TARGET_SIGNALS if is_target else AHB_INITIATOR_SIGNALS
        addr_w = iface.params.get('ADDR_WIDTH', iface.params.get('ADDR_W', 'SYS_ADDR_W'))
        data_w = iface.params.get('DATA_WIDTH', iface.params.get('DATA_W', 'SYS_DATA_W'))

        for sig_name, sig_dir, sig_width in signals:
            # Resolve width
            w = sig_width
            if w == 'SYS_ADDR_W':
                w = addr_w
            elif w == 'SYS_DATA_W':
                w = data_w

            # For target ports, the perspective is inverted from the module port direction
            if is_target:
                # Target port on nanosoc = outputs to external (for address/data going out)
                direction = 'output' if sig_dir == 'in' else 'input'
            else:
                direction = 'input' if sig_dir == 'in' else 'output'

            ports.append({
                'name': f'{iface.name}_{sig_name}',
                'direction': direction,
                'width': w,
                'width_str': _param_width_str(w),
                'desc': f'{iface.desc} — {sig_name}',
            })

    def _expand_axis_port(self, iface: Interface, ports: List[Dict], full: bool = True):
        """Expand an AXIS interface into individual port signals."""
        signals = AXIS_SIGNALS if full else AXIS_BYTE_SIGNALS
        is_output = iface.direction in ('out', 'sender', 'initiator')
        data_w = iface.params.get('DATA_WIDTH', iface.params.get('DATA_W', 'SYS_DATA_W'))
        has_flush = iface.params.get('HAS_FLUSH', 0)

        for sig_name, sig_dir, sig_width in signals:
            w = sig_width
            if w == 'SYS_DATA_W':
                w = data_w

            if is_output:
                direction = 'output' if sig_dir == 'out' else 'input'
            else:
                direction = 'input' if sig_dir == 'out' else 'output'

            ports.append({
                'name': f'{iface.name}_{sig_name}',
                'direction': direction,
                'width': w,
                'width_str': _param_width_str(w),
                'desc': f'{iface.desc} — {sig_name}',
            })

        # Add flush signal for input AXIS streams with HAS_FLUSH
        if full and has_flush and not is_output:
            ports.append({
                'name': f'{iface.name}_flush',
                'direction': 'output',
                'width': 1,
                'width_str': '',
                'desc': f'{iface.desc} — flush',
            })

    def _build_internal_wires(self) -> List[Dict[str, Any]]:
        """Build internal wire declarations from the model."""
        # Collect top-level port names to avoid duplicate declarations
        port_names = {iface.name for iface in self.top.interfaces}
        wires = []
        for w in self.top.internal_wires:
            if w.name in port_names:
                continue  # already declared as a top-level port
            width = w.params.get('WIDTH', 1)
            # Resolve parameterised widths
            if isinstance(width, str) and width.startswith('$'):
                width = resolve_param_ref(width, self.flat_params)
            wires.append({
                'name': w.name,
                'width': width,
                'width_str': _param_width_str(width),
                'desc': w.desc,
            })
        return wires

    def _build_bus_wires(self) -> List[Dict[str, Any]]:
        """Build AHB/AXIS bus wire bundles needed for internal instance connections."""
        bus_wires = []
        seen = set()

        # Walk all instance connections to find bus references that need wires
        for inst in self.top.instances:
            if inst.resolved_module is None:
                continue
            for conn in inst.connections:
                if conn.is_unconnected:
                    continue
                inst_ref, port_name, high, low = parse_conn_ref(conn.conn)
                # If it references an interconnect port, we need the wire bundle
                if inst_ref and any(ic.name == inst_ref for ic in self.top.interconnects):
                    ic = next(ic for ic in self.top.interconnects if ic.name == inst_ref)
                    # Determine if it's an initiator or target port
                    wire_prefix = port_name
                    if wire_prefix not in seen:
                        seen.add(wire_prefix)
                        # Check if it's an initiator port
                        is_init = any(init.name == port_name for init in ic.initiators)
                        if is_init:
                            for sig, sig_dir, sig_w in AHB_INITIATOR_SIGNALS:
                                bus_wires.append({
                                    'name': f'{wire_prefix}_{sig}',
                                    'width_str': _param_width_str(sig_w),
                                    'desc': f'{wire_prefix} AHB initiator — {sig}',
                                })
                        else:
                            # Target port
                            for sig, sig_dir, sig_w in AHB_TARGET_SIGNALS:
                                bus_wires.append({
                                    'name': f'{wire_prefix}_{sig}',
                                    'width_str': _param_width_str(sig_w),
                                    'desc': f'{wire_prefix} AHB target — {sig}',
                                })
        return bus_wires

    def _build_glue_instances(self) -> List[Dict[str, Any]]:
        """Build glue logic helper module instantiations."""
        instances = []
        for gl in self.top.glue_logic:
            inst = {
                'name': gl.name,
                'type': gl.type,
                'output': gl.output,
                'desc': gl.desc,
            }
            if gl.type == 'passthrough':
                inst['input'] = gl.input
                inst['width'] = self._infer_width(gl.input or '', gl.output)
            elif gl.type == 'or_reduce':
                inst['input'] = gl.input
                inst['width'] = self._infer_width(gl.input or '', None)
            elif gl.type == 'or_combine':
                inst['inputs'] = gl.inputs
                inst['n_inputs'] = len(gl.inputs)
                inst['width'] = self._infer_width(gl.inputs[0] if gl.inputs else '', gl.output)
            elif gl.type == 'and_gate':
                inst['input_a'] = gl.inputs[0] if len(gl.inputs) > 0 else ''
                inst['input_b'] = gl.inputs[1] if len(gl.inputs) > 1 else ''
                inst['width'] = self._infer_width(gl.inputs[0] if gl.inputs else '', gl.output)
            elif gl.type == 'constant':
                inst['value'] = gl.value
                inst['width'] = gl.width or 1
            instances.append(inst)
        return instances

    def _infer_width(self, signal: str, output: Optional[str] = None) -> int:
        """Infer the width of a signal from bit slices or internal_wires."""
        # Check for bit slice
        _, high, low = parse_bit_slice(signal)
        if high is not None and low is not None:
            return high - low + 1

        # Check output bit slice
        if output:
            _, high, low = parse_bit_slice(output)
            if high is not None and low is not None:
                return high - low + 1

        # Build list of candidate base names from both input and output signals
        base, _, _ = parse_bit_slice(signal)
        inst_name = None
        if '.' in base:
            inst_name, base = base.split('.', 1)
        candidates = [base]
        if output:
            out_base, _, _ = parse_bit_slice(output)
            if out_base and out_base != base:
                candidates.append(out_base)

        # Check internal_wires
        for cand in candidates:
            for w in self.top.internal_wires:
                if w.name == cand:
                    width = w.params.get('WIDTH', 1)
                    if isinstance(width, str):
                        width = resolve_param_ref(width, self.flat_params)
                    if isinstance(width, int):
                        return width

        # Check top-level interfaces (direct name match)
        for cand in candidates:
            for iface in self.top.interfaces:
                if iface.name == cand:
                    width = iface.params.get('WIDTH', 1)
                    if isinstance(width, int):
                        return width

        # Check GPIO-expanded top-level port names (e.g. p0_out from gpio iface p0)
        # Check both input base and output base since either might be the GPIO port
        for check_name in candidates:
            if not check_name:
                continue
            for iface in self.top.interfaces:
                if iface.type == 'gpio':
                    gpio_width = iface.params.get('WIDTH', 16)
                    for suffix in ('in', 'out', 'outen'):
                        if check_name == f'{iface.name}_{suffix}':
                            return gpio_width if isinstance(gpio_width, int) else 16

        # Check instance module interfaces for hierarchical references
        if inst_name:
            inst_obj = self.top.get_instance(inst_name)
            if inst_obj and inst_obj.resolved_module:
                for mod_iface in inst_obj.resolved_module.interfaces:
                    if mod_iface.name == base:
                        width = mod_iface.params.get('WIDTH', 1)
                        if isinstance(width, str):
                            width = resolve_param_ref(width, self.flat_params)
                        if isinstance(width, int):
                            return width

        return 1  # default

    def _build_instances(self) -> List[Dict[str, Any]]:
        """Build instance data for template rendering."""
        instances = []
        for inst in self.top.instances:
            module_name = inst.module_name
            inst_data = {
                'instance_name': inst.instance_name,
                'module_name': module_name,
                'params': [],
                'connections': [],
                'condition': inst.condition,
            }

            # Build parameter overrides
            for pname, pval in inst.params.items():
                # Strip $ prefix from parameter references
                val = pval
                if isinstance(val, str) and val.startswith('$'):
                    val = val[1:]
                inst_data['params'].append({
                    'name': pname,
                    'value': val,
                })

            # Build port connections
            for conn in inst.connections:
                port = conn.port
                signal = conn.conn

                # Handle intentionally unconnected ports
                if conn.is_unconnected:
                    inst_data['connections'].append({
                        'port': port,
                        'signal': None,
                        'desc': conn.desc,
                    })
                    continue

                # Resolve connection references
                inst_ref, port_name, high, low = parse_conn_ref(signal)

                if inst_ref:
                    # Check if it's an interconnect bus reference
                    is_ic = any(ic.name == inst_ref for ic in self.top.interconnects)
                    if is_ic:
                        # This is a bus connection — expand it
                        self._expand_bus_connection(inst, inst_data, port, port_name, inst_ref)
                        continue
                    # Otherwise it's an instance.port cross-reference — resolve to wire name
                    # These are resolved to intermediate wires by the wire mapping
                    signal = self._resolve_conn_to_wire(signal)
                else:
                    # Bare signal name — check if it maps to a top-level protocol interface
                    top_iface = self._find_top_interface(port_name)
                    if top_iface and top_iface.type in ('axis', 'axis_stream', 'axis_byte', 'swd'):
                        self._expand_protocol_connection(inst, inst_data, port, top_iface)
                        continue

                inst_data['connections'].append({
                    'port': port,
                    'signal': signal,
                    'desc': conn.desc,
                })

            # Post-process: coalesce port bit-selects into valid SV connections
            inst_data['connections'] = self._coalesce_bit_select_ports(
                inst_data['connections'], inst)

            instances.append(inst_data)
        return instances

    def _expand_bus_connection(self, inst: Instance, inst_data: Dict, port: str,
                               ic_port: str, ic_name: str):
        """Expand a bus interface connection into individual signal connections."""
        ic = next(ic for ic in self.top.interconnects if ic.name == ic_name)

        # Determine if this instance connects as initiator or target
        is_init = any(init.name == ic_port for init in ic.initiators)

        if is_init:
            # Instance is an initiator — its port drives the bus
            signals = AHB_INITIATOR_SIGNALS
            for sig, sig_dir, _ in signals:
                if port.isupper():
                    inst_port = f'{port}_{sig.upper()}'
                else:
                    inst_port = f'{port}_{sig}'
                wire_name = f'{ic_port}_{sig}'
                inst_data['connections'].append({
                    'port': inst_port,
                    'signal': wire_name,
                })
        else:
            # Instance is a target — the bus drives its port
            signals = AHB_TARGET_SIGNALS
            # Check for excluded signals (e.g. EXCLUDE: [hready, hburst])
            inst_iface = self._find_instance_interface(inst, port)
            exclude = set(inst_iface.params.get('EXCLUDE', [])) if inst_iface else set()
            for sig, sig_dir, _ in signals:
                if sig in exclude:
                    continue
                inst_port = f'{port}_{sig}' if port != 'ahb_slave' else sig.upper()
                if port == 'ahb_slave':
                    # Regions use uppercase port names without prefix
                    inst_port = sig.upper()
                elif port.isupper():
                    # Uppercase port prefix (like SOC_PERIPHERAL)
                    inst_port = f'{port}_{sig.upper()}'
                else:
                    inst_port = f'{port}_{sig}'
                wire_name = f'{ic_port}_{sig}'
                inst_data['connections'].append({
                    'port': inst_port,
                    'signal': wire_name,
                })

    def _resolve_conn_to_wire(self, conn: str) -> str:
        """Resolve a connection reference to a wire name.

        Cross-instance references like 'u_ss_cpu.sys_hclk' are resolved
        based on what they actually connect to in the hand-written RTL.
        """
        # For now, keep the hierarchical reference as-is — the template
        # will need wire declarations for these. The mapping between
        # YAML connection refs and actual wire names is handled via
        # the internal_wires and bus_wires infrastructure.
        return conn

    def _find_top_interface(self, name: str) -> Optional[Interface]:
        """Find a top-level interface by name."""
        return next((i for i in self.top.interfaces if i.name == name), None)

    def _find_instance_interface(self, inst: Instance, port_name: str) -> Optional[Interface]:
        """Find an interface on an instance's module by port name."""
        if inst.resolved_module:
            for iface in inst.resolved_module.interfaces:
                if iface.name == port_name:
                    return iface
        for iface in inst.inline_interfaces:
            if iface.name == port_name:
                return iface
        return None

    def _top_iface_signal_name(self, iface: Interface, sig_name: str) -> str:
        """Get the top-level port signal name for a protocol interface signal.

        SWD interfaces named '*_swd' strip the '_swd' suffix before appending
        the signal name (e.g. cpu_0_swd + swdi -> cpu_0_swdi).
        """
        if iface.type == 'swd' and iface.name.endswith('_swd'):
            return f'{iface.name[:-4]}_{sig_name}'
        return f'{iface.name}_{sig_name}'

    def _expand_protocol_connection(self, inst: Instance, inst_data: Dict,
                                     port: str, top_iface: Interface):
        """Expand a protocol interface connection into individual signal connections."""
        if top_iface.type in ('axis', 'axis_stream'):
            for sig_name, _, _ in AXIS_SIGNALS:
                inst_data['connections'].append({
                    'port': f'{port}_{sig_name}',
                    'signal': self._top_iface_signal_name(top_iface, sig_name),
                })
            # Add flush signal if either side declares HAS_FLUSH
            inst_iface = self._find_instance_interface(inst, port)
            has_flush = top_iface.params.get('HAS_FLUSH', 0)
            if not has_flush and inst_iface:
                has_flush = inst_iface.params.get('HAS_FLUSH', 0)
            if has_flush:
                inst_data['connections'].append({
                    'port': f'{port}_flush',
                    'signal': self._top_iface_signal_name(top_iface, 'flush'),
                })
        elif top_iface.type == 'axis_byte':
            for sig_name, _, _ in AXIS_BYTE_SIGNALS:
                inst_data['connections'].append({
                    'port': f'{port}_{sig_name}',
                    'signal': self._top_iface_signal_name(top_iface, sig_name),
                })
        elif top_iface.type == 'swd':
            for sig_name, _, _ in SWD_SIGNALS:
                # SWD ports strip '_swd' suffix: cpu_0_swd + swdi -> cpu_0_swdi
                if port.endswith('_swd'):
                    inst_port = f'{port[:-4]}_{sig_name}'
                else:
                    inst_port = f'{port}_{sig_name}'
                inst_data['connections'].append({
                    'port': inst_port,
                    'signal': self._top_iface_signal_name(top_iface, sig_name),
                })

    def _coalesce_bit_select_ports(self, connections: List[Dict],
                                    inst: Instance) -> List[Dict]:
        """Coalesce port bit-select connections into valid SV port connections.

        Converts .port[0](signal) into .port(signal) when the port is 1-bit,
        or groups multiple bit connections into a concatenation.
        """
        from collections import OrderedDict

        result = []
        bit_groups: Dict[str, List[Tuple]] = OrderedDict()

        for conn in connections:
            if conn.get('signal') is None:
                result.append(conn)
                continue
            port = conn['port']
            base, high, low = parse_bit_slice(port)
            if high is not None:
                if base not in bit_groups:
                    bit_groups[base] = []
                bit_groups[base].append((high, low, conn['signal'], conn.get('desc')))
            else:
                result.append(conn)

        for base, bits in bit_groups.items():
            # Sort by bit position descending (MSB first for concatenation)
            bits.sort(key=lambda x: x[0], reverse=True)

            # Check if this is a single-bit port (resolves the FT1248_WIDTH=1 case)
            port_width = self._get_instance_port_width(inst, base)
            total_connected = sum(h - l + 1 for h, l, _, _ in bits)

            if port_width is not None and port_width == 1 and len(bits) == 1:
                # 1-bit port — just use the base port name
                result.append({'port': base, 'signal': bits[0][2]})
            elif len(bits) == 1 and port_width is not None and total_connected == port_width:
                # Single connection covering the full port width
                result.append({'port': base, 'signal': bits[0][2]})
            elif len(bits) == 1:
                # Single partial bit — connect directly (best effort)
                result.append({'port': base, 'signal': bits[0][2]})
            else:
                # Multiple bit connections — build concatenation {msb, ..., lsb}
                concat_parts = [sig for _, _, sig, _ in bits]
                result.append({'port': base, 'signal': '{' + ', '.join(concat_parts) + '}'})

        return result

    def _get_instance_port_width(self, inst: Instance, port_name: str) -> Optional[int]:
        """Get resolved width of a port on an instance's module."""
        iface = self._find_instance_interface(inst, port_name)
        if iface is None:
            return None
        width = iface.params.get('WIDTH', 1)
        if isinstance(width, str):
            width = resolve_param_ref(width, self.flat_params)
        return width if isinstance(width, int) else None

    def _build_interconnect(self) -> Optional[Dict[str, Any]]:
        """Build interconnect instance data."""
        if not self.top.interconnects:
            return None

        ic = self.top.interconnects[0]  # Assume single interconnect for now
        ic_data = {
            'name': ic.name,
            'module_name': f'{self.top.name}_interconnect',
            'params': [],
            'connections': [],
            'initiators': [],
            'targets': [],
        }

        # Parameters
        for pname, pval in ic.params.items():
            val = pval
            if isinstance(val, str) and val.startswith('$'):
                val = val[1:]
            ic_data['params'].append({'name': pname, 'value': val})

        # Fixed connections (clock, reset, scan, remap)
        for conn in ic.connections:
            signal = self._resolve_conn_to_wire(conn.conn)
            ic_data['connections'].append({
                'port': conn.port,
                'signal': signal,
            })

        # Build flat port list for the interconnect to avoid nested loop.parent issues in Jinja2
        ic_ports = []

        for init in ic.initiators:
            ic_ports.append({'type': 'comment', 'text': f'{init.name} Master Port'})
            for sig, sig_dir, sig_w in AHB_INITIATOR_SIGNALS:
                ic_ports.append({
                    'type': 'port',
                    'port': f'{init.name}_{sig}',
                    'signal': f'{init.name}_{sig}',
                })

        for tgt in ic.targets:
            ic_ports.append({'type': 'comment', 'text': f'{tgt.name} Target Port'})
            for sig, sig_dir, sig_w in AHB_TARGET_SIGNALS:
                if sig == 'hready':
                    ic_ports.append({
                        'type': 'port',
                        'port': f'{tgt.name}_hreadymux',
                        'signal': f'{tgt.name}_hready',
                    })
                else:
                    ic_ports.append({
                        'type': 'port',
                        'port': f'{tgt.name}_{sig}',
                        'signal': f'{tgt.name}_{sig}',
                    })

        ic_data['ports'] = ic_ports
        return ic_data
