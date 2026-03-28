"""Validation of the SoC model: width matching, direction compatibility, address overlaps."""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from .model import Connection, Instance, Interconnect, Interface, Module
from .utils import parse_bit_slice, parse_conn_ref, bit_slice_width


@dataclass
class ValidationMessage:
    """A validation error or warning."""
    level: str  # 'error', 'warning', 'info'
    category: str  # 'width', 'direction', 'reference', 'address', 'connection'
    instance: str = ''
    port: str = ''
    message: str = ''

    def __str__(self):
        loc = f"{self.instance}.{self.port}" if self.instance else self.port
        return f"[{self.level.upper()}] ({self.category}) {loc}: {self.message}"


class SoCValidator:
    """Validates the SoC model for connectivity correctness."""

    def __init__(self, top_module: Module):
        self.top = top_module
        self.messages: List[ValidationMessage] = []

    def validate_all(self) -> List[ValidationMessage]:
        """Run all validation checks."""
        self.messages = []
        self._validate_connections(self.top)
        self._validate_interconnects(self.top)
        self._validate_address_overlaps(self.top)
        self._validate_instance_references(self.top)
        return self.messages

    @property
    def errors(self) -> List[ValidationMessage]:
        return [m for m in self.messages if m.level == 'error']

    @property
    def warnings(self) -> List[ValidationMessage]:
        return [m for m in self.messages if m.level == 'warning']

    def _validate_connections(self, module: Module):
        """Validate all connections on all instances in a module."""
        for inst in module.instances:
            child_module = inst.resolved_module
            if not child_module:
                self.messages.append(ValidationMessage(
                    level='warning',
                    category='reference',
                    instance=inst.instance_name,
                    message=f"Unresolved module '{inst.module_name}'",
                ))
                continue

            # Build port lookup for the child module
            child_ports = {iface.name: iface for iface in child_module.interfaces}

            for conn in inst.connections:
                port_name, port_high, port_low = parse_bit_slice(conn.port)

                # Check port exists on child module
                child_iface = child_ports.get(port_name)
                if not child_iface:
                    self.messages.append(ValidationMessage(
                        level='warning',
                        category='reference',
                        instance=inst.instance_name,
                        port=conn.port,
                        message=f"Port '{port_name}' not found on module '{child_module.name}'",
                    ))
                    continue

                # Resolve the connection target
                self._validate_single_connection(module, inst, conn, child_iface, port_high, port_low)

    def _validate_single_connection(
        self,
        parent: Module,
        inst: Instance,
        conn: Connection,
        child_iface: Interface,
        port_high: Optional[int],
        port_low: Optional[int],
    ):
        """Validate a single port-to-signal connection."""
        conn_inst, conn_port, conn_high, conn_low = parse_conn_ref(conn.conn)

        # --- Width validation ---
        self._check_width(inst, conn, child_iface, port_high, port_low,
                          parent, conn_inst, conn_port, conn_high, conn_low)

        # --- Direction validation ---
        self._check_direction(inst, conn, child_iface, parent, conn_inst, conn_port)

    def _check_width(
        self,
        inst: Instance,
        conn: Connection,
        child_iface: Interface,
        port_high: Optional[int],
        port_low: Optional[int],
        parent: Module,
        conn_inst: Optional[str],
        conn_port: str,
        conn_high: Optional[int],
        conn_low: Optional[int],
    ):
        """Check that widths match on both sides of a connection."""
        # Get port side width
        port_width = self._get_effective_width(child_iface, port_high, port_low)
        if port_width is None:
            return  # can't validate without width info

        # Get connection side width
        conn_width = self._resolve_conn_width(
            parent, conn_inst, conn_port, conn_high, conn_low
        )

        if conn_width is not None and port_width != conn_width:
            self.messages.append(ValidationMessage(
                level='error',
                category='width',
                instance=inst.instance_name,
                port=conn.port,
                message=(
                    f"Width mismatch: port '{conn.port}' has width {port_width}, "
                    f"but conn '{conn.conn}' has width {conn_width}"
                ),
            ))

    def _check_direction(
        self,
        inst: Instance,
        conn: Connection,
        child_iface: Interface,
        parent: Module,
        conn_inst: Optional[str],
        conn_port: str,
    ):
        """Check that port directions are compatible."""
        if child_iface.is_bidirectional:
            return  # inout always compatible

        # If connecting to another instance's port, check directions are opposite
        if conn_inst:
            other_inst = parent.get_instance(conn_inst)
            if other_inst and other_inst.resolved_module:
                other_iface = other_inst.resolved_module.get_interface(conn_port)
                if other_iface:
                    if not other_iface.is_bidirectional:
                        # For bus protocols, initiator connects to target
                        if child_iface.type in ('ahb', 'apb', 'axis', 'axis_byte'):
                            self._check_bus_direction(inst, conn, child_iface, other_iface)
                        else:
                            # For wires: output must connect to input
                            if child_iface.is_output and other_iface.is_output:
                                self.messages.append(ValidationMessage(
                                    level='error',
                                    category='direction',
                                    instance=inst.instance_name,
                                    port=conn.port,
                                    message=(
                                        f"Direction conflict: port '{conn.port}' (output) "
                                        f"connects to '{conn.conn}' (also output)"
                                    ),
                                ))
                            elif child_iface.is_input and other_iface.is_input:
                                self.messages.append(ValidationMessage(
                                    level='error',
                                    category='direction',
                                    instance=inst.instance_name,
                                    port=conn.port,
                                    message=(
                                        f"Direction conflict: port '{conn.port}' (input) "
                                        f"connects to '{conn.conn}' (also input)"
                                    ),
                                ))

        # If connecting to parent module port, check directions match
        elif not conn_inst:
            parent_iface = parent.get_interface(conn_port)
            if parent_iface:
                # Child input should connect to parent input (pass-through)
                # Child output should connect to parent output (pass-through)
                # This is correct — no error needed
                pass

    def _check_bus_direction(
        self,
        inst: Instance,
        conn: Connection,
        child_iface: Interface,
        other_iface: Interface,
    ):
        """Check bus protocol direction compatibility."""
        child_dir = child_iface.direction
        other_dir = other_iface.direction

        # initiator <-> target is correct
        # out <-> in is correct for streams
        compatible_pairs = {
            ('initiator', 'target'), ('target', 'initiator'),
            ('out', 'in'), ('in', 'out'),
            ('sender', 'receiver'), ('receiver', 'sender'),
        }

        if (child_dir, other_dir) not in compatible_pairs:
            # Only warn, not error — some connections are indirect through interconnect
            self.messages.append(ValidationMessage(
                level='warning',
                category='direction',
                instance=inst.instance_name,
                port=conn.port,
                message=(
                    f"Bus direction check: '{conn.port}' ({child_dir}) "
                    f"connects to '{conn.conn}' ({other_dir})"
                ),
            ))

    def _get_effective_width(
        self,
        iface: Interface,
        high: Optional[int],
        low: Optional[int],
    ) -> Optional[int]:
        """Get effective width of an interface, accounting for bit slicing."""
        if high is not None and low is not None:
            return bit_slice_width(high, low)

        if iface.type == 'wire':
            return iface.width
        # Bus interfaces have multiple signals — width check is per-signal
        # For bus types, we check data_width and addr_width separately
        return None

    def _resolve_conn_width(
        self,
        parent: Module,
        conn_inst: Optional[str],
        conn_port: str,
        high: Optional[int],
        low: Optional[int],
    ) -> Optional[int]:
        """Resolve the width of a connection target."""
        if high is not None and low is not None:
            return bit_slice_width(high, low)

        # Check if it's a parent interface
        parent_iface = parent.get_interface(conn_port)
        if parent_iface and parent_iface.type == 'wire':
            return parent_iface.width

        # Check if it's another instance's port
        if conn_inst:
            other_inst = parent.get_instance(conn_inst)
            if other_inst and other_inst.resolved_module:
                other_iface = other_inst.resolved_module.get_interface(conn_port)
                if other_iface and other_iface.type == 'wire':
                    return other_iface.width

        return None  # can't determine width

    def _validate_interconnects(self, module: Module):
        """Validate interconnect target/initiator consistency."""
        for ic in module.interconnects:
            target_names = {t.name for t in ic.targets}

            for init in ic.initiators:
                for tgt_name in init.target_names:
                    if tgt_name not in target_names:
                        self.messages.append(ValidationMessage(
                            level='error',
                            category='reference',
                            instance=ic.name,
                            port=init.name,
                            message=(
                                f"Initiator '{init.name}' references target "
                                f"'{tgt_name}' which is not defined in targets"
                            ),
                        ))

    def _validate_address_overlaps(self, module: Module):
        """Check for overlapping address ranges in interconnects."""
        for ic in module.interconnects:
            targets = sorted(ic.targets, key=lambda t: t.base)

            for i in range(len(targets) - 1):
                t1 = targets[i]
                t2 = targets[i + 1]
                t1_end = t1.base + t1.size
                if t1_end > t2.base:
                    self.messages.append(ValidationMessage(
                        level='error',
                        category='address',
                        instance=ic.name,
                        message=(
                            f"Address overlap: '{t1.name}' "
                            f"(0x{t1.base:08X}-0x{t1_end - 1:08X}) overlaps with "
                            f"'{t2.name}' (0x{t2.base:08X}-0x{t2.base + t2.size - 1:08X})"
                        ),
                    ))

    def _validate_instance_references(self, module: Module):
        """Check that all instance module references can be resolved."""
        for inst in module.instances:
            if not inst.resolved_module and not inst.is_rtl_module:
                self.messages.append(ValidationMessage(
                    level='error',
                    category='reference',
                    instance=inst.instance_name,
                    message=f"Module '{inst.module_name}' not found",
                ))
