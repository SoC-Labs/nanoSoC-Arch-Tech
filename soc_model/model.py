"""Object-oriented data model for SoC system descriptions."""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class Param:
    """A design parameter."""
    name: str
    type: str = 'int'
    default: Any = None
    desc: str = ''


@dataclass
class Clock:
    """A clock domain."""
    name: str
    source: str = ''
    desc: str = ''


@dataclass
class Reset:
    """A reset domain."""
    name: str
    active: str = 'low'
    source: str = ''
    desc: str = ''


@dataclass
class InterfaceSignal:
    """A signal within a protocol interface definition."""
    name: str
    direction: str = 'in'  # in, out
    width: Any = 1  # int or str expression
    desc: str = ''


@dataclass
class InterfaceDefinition:
    """A protocol interface definition (from interfaces/ YAML files)."""
    name: str
    protocol: str = ''
    role: str = ''
    params: Dict[str, Any] = field(default_factory=dict)
    signals: List[InterfaceSignal] = field(default_factory=list)


@dataclass
class Interface:
    """A port/interface on a module."""
    name: str
    type: str = 'wire'  # wire, ahb, apb, axis, axis_byte, swd, gpio
    direction: str = 'in'  # in, out, inout, initiator, target, receiver
    params: Dict[str, Any] = field(default_factory=dict)
    desc: str = ''

    @property
    def width(self) -> Optional[int]:
        """Get the width of a wire interface."""
        if self.type == 'wire':
            w = self.params.get('WIDTH', 1)
            if isinstance(w, int):
                return w
        return None

    @property
    def addr_width(self) -> Optional[int]:
        """Get address width for bus interfaces."""
        w = self.params.get('ADDR_WIDTH') or self.params.get('ADDR_W')
        return w if isinstance(w, int) else None

    @property
    def data_width(self) -> Optional[int]:
        """Get data width for bus/stream interfaces."""
        w = self.params.get('DATA_WIDTH') or self.params.get('DATA_W')
        if w is None and self.type == 'axis_byte':
            return 8
        return w if isinstance(w, int) else None

    @property
    def is_input(self) -> bool:
        return self.direction in ('in', 'target', 'receiver')

    @property
    def is_output(self) -> bool:
        return self.direction in ('out', 'initiator', 'sender')

    @property
    def is_bidirectional(self) -> bool:
        return self.direction == 'inout'


@dataclass
class Connection:
    """A port-to-signal connection on an instance."""
    port: str
    conn: str  # signal reference, or 'unconnected' for intentionally open ports
    desc: str = ''

    @property
    def is_unconnected(self) -> bool:
        return self.conn == 'unconnected'


@dataclass
class Assign:
    """A combinational assign statement (legacy format)."""
    target: str
    expr: str
    type: Optional[str] = None  # 'interrupt' or None
    bit: Any = None  # int, str like "31:16", or "nmi"
    combining: Optional[str] = None  # 'OR', 'AND'
    origin: Optional[str] = None
    desc: str = ''


@dataclass
class GlueLogicEntry:
    """A typed glue logic entry — maps to a structural helper module instance.

    Types:
      passthrough — connects input directly to output
      or_reduce   — reduction OR of multi-bit input to 1-bit output
      or_combine  — N-input OR of equal-width operands
      and_gate    — 2-input AND
      constant    — drives output to a fixed value
    """
    name: str
    type: str  # passthrough, or_reduce, or_combine, and_gate, constant
    output: str  # target signal (may include bit slice)
    inputs: List[str] = field(default_factory=list)  # for or_combine, and_gate
    input: Optional[str] = None  # for passthrough, or_reduce (single input)
    value: Any = None  # for constant
    width: Optional[int] = None  # for constant (explicit width)
    desc: str = ''


@dataclass
class InterconnectTarget:
    """A target (subordinate) in an interconnect."""
    name: str
    instance: Optional[str] = None  # associated module instance name
    base: int = 0
    size: int = 0
    phys_size: Any = None  # int or expression string
    sw_access: str = 'rw'
    region_type: Optional[str] = None
    role: Optional[str] = None
    subordinate_bus: bool = False  # True if this target connects to another bus matrix/NoC
    protocol: str = 'ahb'  # 'ahb' or 'apb'
    apb_config: Optional[Dict[str, Any]] = None  # APB bridge/mux config when protocol='apb'
    desc: str = ''


@dataclass
class InterconnectInitiatorTarget:
    """A target reference from an initiator, with optional visibility overrides."""
    name: str
    visibility: Optional[List[Dict[str, Any]]] = None  # address window overrides


@dataclass
class InterconnectInitiator:
    """An initiator (master) in an interconnect."""
    name: str
    instance: Optional[str] = None  # associated module instance name
    targets: List[InterconnectInitiatorTarget] = field(default_factory=list)

    @property
    def target_names(self) -> List[str]:
        """Get flat list of target names."""
        return [t.name for t in self.targets]


@dataclass
class Interconnect:
    """A bus interconnect (e.g., AHB bus matrix)."""
    name: str
    gen: bool = True
    type: str = 'ahb_lite'
    desc: str = ''
    params: Dict[str, Any] = field(default_factory=dict)
    connections: List[Connection] = field(default_factory=list)
    targets: List[InterconnectTarget] = field(default_factory=list)
    initiators: List[InterconnectInitiator] = field(default_factory=list)


@dataclass
class RegisterField:
    """A field within a register."""
    name: str
    bits: str = ''
    access: str = 'RO'
    reset_value: Any = None
    desc: str = ''


@dataclass
class Register:
    """A register within a register map."""
    name: str
    offset: int = 0
    width: int = 32
    access: str = 'RW'
    reset_value: Any = None
    desc: str = ''
    fields: List['RegisterField'] = field(default_factory=list)


@dataclass
class RegisterMap:
    """A parsed register map definition."""
    name: str
    module: str = ''
    gen: bool = False
    desc: str = ''
    address_width: int = 12
    data_width: int = 32
    registers: List[Register] = field(default_factory=list)
    source_file: str = ''


@dataclass
class AddressDecodeSlot:
    """A slot in an address decoder."""
    slot: int
    name: str
    module: str = ''
    offset: int = 0
    size: int = 0
    register_map: Optional[str] = None
    resolved_register_map: Optional[RegisterMap] = None
    desc: str = ''
    address_decode: Optional['AddressDecode'] = None  # nested decode


@dataclass
class AddressDecode:
    """An address decode hierarchy (AHB/APB slave mux)."""
    type: str = ''  # ahb_slave_mux, apb_slave_mux
    module: str = ''
    bridge: Optional[Dict[str, Any]] = None
    slots: List[AddressDecodeSlot] = field(default_factory=list)


@dataclass
class LinkerRegion:
    """A memory region in a linker profile."""
    target: str
    address_select: str = 'default'
    linker_name: Optional[str] = None
    software_access: Optional[str] = None
    size_adjust: Optional[int] = None
    phys_size: Optional[int] = None


@dataclass
class LinkerProfile:
    """A firmware linker profile."""
    name: str
    regions: List[LinkerRegion] = field(default_factory=list)


@dataclass
class Firmware:
    """Firmware configuration."""
    cpu_initiator: str = ''
    linker_profiles: List[LinkerProfile] = field(default_factory=list)
    adp: Optional[Dict[str, Any]] = None
    hex_adjust: Optional[Dict[str, Any]] = None


@dataclass
class Instance:
    """An instance of a module within a parent module."""
    instance_name: str
    module_name: str = ''  # YAML module name (from module: or rtl_module:)
    is_rtl_module: bool = False  # True if rtl_module: (no YAML file)
    addressable: bool = False
    condition: Optional[str] = None
    params: Dict[str, Any] = field(default_factory=dict)
    connections: List[Connection] = field(default_factory=list)
    inline_interfaces: List[Interface] = field(default_factory=list)  # for rtl_module
    resolved_module: Optional['Module'] = None  # set by builder


@dataclass
class Module:
    """A hardware module (top-level or sub-module)."""
    name: str
    gen: bool = False
    desc: str = ''
    source_file: str = ''

    params: Dict[str, Param] = field(default_factory=dict)
    clocks: List[Clock] = field(default_factory=list)
    resets: List[Reset] = field(default_factory=list)
    interfaces: List[Interface] = field(default_factory=list)
    instances: List[Instance] = field(default_factory=list)
    assigns: List[Assign] = field(default_factory=list)
    glue_logic: List[GlueLogicEntry] = field(default_factory=list)
    internal_wires: List[Interface] = field(default_factory=list)
    interconnects: List[Interconnect] = field(default_factory=list)
    address_decode: Optional[AddressDecode] = None
    firmware: Optional[Firmware] = None

    def get_interface(self, name: str) -> Optional[Interface]:
        """Find an interface by name."""
        for iface in self.interfaces:
            return next((i for i in self.interfaces if i.name == name), None)
        return None

    def get_instance(self, name: str) -> Optional[Instance]:
        """Find an instance by name."""
        return next((i for i in self.instances if i.instance_name == name), None)

    def get_interconnect(self, name: str) -> Optional[Interconnect]:
        """Find an interconnect by name."""
        return next((ic for ic in self.interconnects if ic.name == name), None)

    @property
    def flat_params(self) -> Dict[str, Any]:
        """Get params as {name: default_value} dict."""
        return {name: p.default for name, p in self.params.items()}
