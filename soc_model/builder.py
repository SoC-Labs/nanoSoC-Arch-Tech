"""Builds the OO model from parsed YAML dictionaries."""

from typing import Any, Dict, List, Optional

from .model import (
    AddressDecode, AddressDecodeSlot, Assign, Clock, Connection, Firmware,
    GlueLogicEntry, Instance, Interconnect, InterconnectInitiator,
    InterconnectInitiatorTarget, InterconnectTarget, Interface, LinkerProfile,
    LinkerRegion, Module, Param, Register, RegisterField, RegisterMap, Reset,
)
from .parser import SoCParser
from .utils import flatten_params, resolve_param_ref


class SoCBuilder:
    """Constructs Module objects from parsed YAML data."""

    def __init__(self, parser: SoCParser):
        self.parser = parser
        self._built_modules: Dict[str, Module] = {}

    def build_system(self, filename: str) -> Module:
        """Build the complete system model from a top-level YAML file."""
        data = self.parser.parse_top_level(filename)
        if 'module' not in data:
            raise ValueError(f"No 'module:' key in {filename}")

        module = self._build_module(data['module'], filename)

        # Resolve module references for all instances
        self._resolve_instances(module)

        return module

    def _build_module(self, data: Dict[str, Any], source_file: str = '') -> Module:
        """Build a Module from a YAML module dict."""
        name = data.get('name', 'unknown')

        if name in self._built_modules:
            return self._built_modules[name]

        module = Module(
            name=name,
            gen=data.get('gen', False),
            desc=data.get('desc', ''),
            source_file=source_file,
        )

        # Parse params
        for pname, pval in data.get('params', {}).items():
            if isinstance(pval, dict):
                module.params[pname] = Param(
                    name=pname,
                    type=pval.get('type', 'int'),
                    default=pval.get('default'),
                    desc=pval.get('desc', ''),
                )
            else:
                module.params[pname] = Param(name=pname, default=pval)

        # Parse clocks
        for c in data.get('clocks', []):
            module.clocks.append(Clock(
                name=c.get('name', ''),
                source=c.get('source', ''),
                desc=c.get('desc', ''),
            ))

        # Parse resets
        for r in data.get('resets', []):
            module.resets.append(Reset(
                name=r.get('name', ''),
                active=r.get('active', 'low'),
                source=r.get('source', ''),
                desc=r.get('desc', ''),
            ))

        # Parse interfaces
        for iface in data.get('interfaces', []):
            module.interfaces.append(self._build_interface(iface))

        # Parse instances
        for inst in data.get('instances', []):
            module.instances.append(self._build_instance(inst))

        # Parse assigns (legacy format)
        for a in data.get('assigns', []):
            module.assigns.append(Assign(
                target=str(a.get('target', '')),
                expr=str(a.get('expr', '')),
                type=a.get('type'),
                bit=a.get('bit'),
                combining=a.get('combining'),
                origin=a.get('origin'),
                desc=a.get('desc', ''),
            ))

        # Parse internal_wires
        for w in data.get('internal_wires', []):
            module.internal_wires.append(Interface(
                name=w.get('name', ''),
                type=w.get('type', 'wire'),
                direction='internal',
                params=w.get('params', {}),
                desc=w.get('desc', ''),
            ))

        # Parse glue_logic (typed structural entries)
        for gl in data.get('glue_logic', []):
            entry = GlueLogicEntry(
                name=gl.get('name', ''),
                type=gl.get('type', ''),
                output=str(gl.get('output', '')),
                inputs=gl.get('inputs', []),
                input=gl.get('input'),
                value=gl.get('value'),
                width=gl.get('width'),
                desc=gl.get('desc', ''),
            )
            # Normalise: ensure inputs are strings
            entry.inputs = [str(i) for i in entry.inputs]
            if entry.input is not None:
                entry.input = str(entry.input)
            module.glue_logic.append(entry)

        # Parse interconnects
        for ic in data.get('interconnects', []):
            module.interconnects.append(self._build_interconnect(ic))

        # Parse address_decode
        if 'address_decode' in data:
            module.address_decode = self._build_address_decode(data['address_decode'])

        # Parse firmware
        if 'firmware' in data:
            module.firmware = self._build_firmware(data['firmware'])

        self._built_modules[name] = module
        return module

    def _build_interface(self, data: Dict[str, Any]) -> Interface:
        """Build an Interface from a YAML dict."""
        return Interface(
            name=data.get('name', ''),
            type=data.get('type', 'wire'),
            direction=data.get('direction', 'in'),
            params=data.get('params', {}),
            desc=data.get('desc', ''),
        )

    def _build_instance(self, data: Dict[str, Any]) -> Instance:
        """Build an Instance from a YAML dict."""
        is_rtl = 'rtl_module' in data
        module_name = data.get('rtl_module', data.get('module', ''))

        inst = Instance(
            instance_name=data.get('instance_name', ''),
            module_name=module_name,
            is_rtl_module=is_rtl,
            addressable=data.get('addressable', False),
            condition=data.get('condition'),
            params=data.get('params', {}),
        )

        # Parse connections
        for conn in data.get('connections', []):
            inst.connections.append(Connection(
                port=str(conn.get('port', '')),
                conn=str(conn.get('conn', '')),
                desc=conn.get('desc', ''),
            ))

        # Parse inline interfaces (for rtl_module)
        for iface in data.get('interfaces', []):
            inst.inline_interfaces.append(self._build_interface(iface))

        return inst

    def _build_interconnect(self, data: Dict[str, Any]) -> Interconnect:
        """Build an Interconnect from a YAML dict."""
        ic = Interconnect(
            name=data.get('name', ''),
            gen=data.get('gen', True),
            type=data.get('type', 'ahb_lite'),
            desc=data.get('desc', ''),
            params=data.get('params', {}),
        )

        # Parse connections (clock, reset, scan, remap, etc.)
        for conn in data.get('connections', []):
            ic.connections.append(Connection(
                port=str(conn.get('port', '')),
                conn=str(conn.get('conn', '')),
                desc=conn.get('desc', ''),
            ))

        for t in data.get('targets', []):
            target = InterconnectTarget(
                name=t.get('name', '') if isinstance(t, dict) else str(t),
                instance=t.get('instance') if isinstance(t, dict) else None,
                base=t.get('base', 0) if isinstance(t, dict) else 0,
                size=t.get('size', 0) if isinstance(t, dict) else 0,
                phys_size=t.get('phys_size') if isinstance(t, dict) else None,
                sw_access=t.get('sw_access', 'rw') if isinstance(t, dict) else 'rw',
                region_type=t.get('region_type') if isinstance(t, dict) else None,
                role=t.get('role') if isinstance(t, dict) else None,
                subordinate_bus=t.get('subordinate_bus', False) if isinstance(t, dict) else False,
                protocol=t.get('protocol', 'ahb').lower() if isinstance(t, dict) else 'ahb',
                apb_config=t.get('apb_config') if isinstance(t, dict) else None,
                desc=t.get('desc', '') if isinstance(t, dict) else '',
            )
            ic.targets.append(target)

        for init in data.get('initiators', []):
            targets_list = init.get('targets', [])
            init_targets = []
            for tgt in targets_list:
                if isinstance(tgt, dict):
                    init_targets.append(InterconnectInitiatorTarget(
                        name=tgt.get('name', ''),
                        visibility=tgt.get('visibility'),
                    ))
                else:
                    init_targets.append(InterconnectInitiatorTarget(name=str(tgt)))

            ic.initiators.append(InterconnectInitiator(
                name=init.get('name', ''),
                instance=init.get('instance'),
                targets=init_targets,
            ))

        return ic

    def _build_address_decode(self, data: Dict[str, Any]) -> AddressDecode:
        """Build an AddressDecode from a YAML dict."""
        ad = AddressDecode(
            type=data.get('type', ''),
            module=data.get('module', ''),
            bridge=data.get('bridge'),
        )

        for s in data.get('slots', []):
            slot = AddressDecodeSlot(
                slot=s.get('slot', 0),
                name=s.get('name', ''),
                module=s.get('module', ''),
                offset=s.get('offset', 0),
                size=s.get('size', 0),
                register_map=s.get('register_map'),
                desc=s.get('desc', ''),
            )
            # Load and attach register map if referenced
            if slot.register_map:
                slot.resolved_register_map = self._build_register_map(
                    slot.register_map
                )
            if 'address_decode' in s:
                slot.address_decode = self._build_address_decode(s['address_decode'])
            ad.slots.append(slot)

        return ad

    def _build_register_map(self, filename: str) -> Optional[RegisterMap]:
        """Load and build a RegisterMap from a YAML file path."""
        data = self.parser.parse_register_map(filename)
        if not data or 'register_map' not in data:
            return None

        rm_data = data['register_map']
        rm = RegisterMap(
            name=rm_data.get('name', ''),
            module=rm_data.get('module', ''),
            gen=rm_data.get('gen', False),
            desc=rm_data.get('description', ''),
            address_width=rm_data.get('address_width', 12),
            data_width=rm_data.get('data_width', 32),
            source_file=filename,
        )

        for reg in rm_data.get('registers', []):
            r = Register(
                name=reg.get('name', ''),
                offset=reg.get('offset', 0),
                width=reg.get('width', 32),
                access=reg.get('access', 'RW'),
                reset_value=reg.get('reset_value'),
                desc=reg.get('description', ''),
            )
            for fld in reg.get('fields', []):
                r.fields.append(RegisterField(
                    name=fld.get('name', ''),
                    bits=str(fld.get('bits', '')),
                    access=fld.get('access', 'RO'),
                    reset_value=fld.get('reset_value'),
                    desc=fld.get('description', ''),
                ))
            rm.registers.append(r)

        return rm

    def _build_firmware(self, data: Dict[str, Any]) -> Firmware:
        """Build a Firmware from a YAML dict."""
        fw = Firmware(
            cpu_initiator=data.get('cpu_initiator', ''),
            adp=data.get('adp'),
            hex_adjust=data.get('hex_adjust'),
        )

        for lp in data.get('linker_profiles', []):
            profile = LinkerProfile(name=lp.get('name', ''))
            for r in lp.get('regions', []):
                profile.regions.append(LinkerRegion(
                    target=r.get('target', ''),
                    address_select=r.get('address_select', 'default'),
                    linker_name=r.get('linker_name'),
                    software_access=r.get('software_access'),
                    size_adjust=r.get('size_adjust'),
                    phys_size=r.get('phys_size'),
                ))
            fw.linker_profiles.append(profile)

        return fw

    def _resolve_instances(self, module: Module):
        """Resolve module references for all instances."""
        for inst in module.instances:
            if inst.is_rtl_module:
                # RTL modules have inline interfaces — create a stub Module
                stub = Module(
                    name=inst.module_name,
                    gen=False,
                    desc=f'Standalone RTL module: {inst.module_name}',
                )
                for iface in inst.inline_interfaces:
                    stub.interfaces.append(iface)
                inst.resolved_module = stub
            else:
                # Look up YAML module file
                mod_data = self.parser.parse_module(inst.module_name)
                if mod_data and 'module' in mod_data:
                    child = self._build_module(
                        mod_data['module'],
                        source_file=f'modules/{inst.module_name}.yaml',
                    )
                    inst.resolved_module = child
                    # Recurse into child instances
                    self._resolve_instances(child)
