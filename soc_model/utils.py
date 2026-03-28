"""Utility functions for parameter resolution and bit-slice parsing."""

import re
from typing import Any, Dict, Optional, Tuple


def resolve_param_ref(value: Any, params: Dict[str, Any]) -> Any:
    """Resolve $PARAM references in a value.

    Handles strings like "$SYS_ADDR_W" -> 32, and expressions like
    "4 * (2 ** $SRAM_0_RAM_ADDR_W)" -> evaluated result.
    """
    if not isinstance(value, str):
        return value

    # Check for pure parameter reference: "$PARAM_NAME"
    m = re.fullmatch(r'\$(\w+)', value)
    if m:
        param_name = m.group(1)
        if param_name in params:
            return params[param_name]
        return value  # unresolved

    # Check for expression containing $PARAM references
    if '$' in value:
        resolved = value
        for param_name, param_val in params.items():
            resolved = resolved.replace(f'${param_name}', str(param_val))
        # Try to evaluate as arithmetic expression (safe subset)
        if '$' not in resolved:
            try:
                return _safe_eval(resolved)
            except Exception:
                return resolved
        return resolved

    return value


def _safe_eval(expr: str) -> Any:
    """Evaluate simple arithmetic expressions safely."""
    # Only allow digits, operators, parens, whitespace
    if re.fullmatch(r'[\d\s\+\-\*\/\(\)\.\*\*]+', expr):
        return eval(expr, {"__builtins__": {}})
    return expr


def resolve_params_in_dict(d: Dict[str, Any], params: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively resolve $PARAM references in a dictionary."""
    result = {}
    for k, v in d.items():
        if isinstance(v, dict):
            result[k] = resolve_params_in_dict(v, params)
        elif isinstance(v, list):
            result[k] = [resolve_param_ref(item, params) if not isinstance(item, (dict, list)) else item for item in v]
        else:
            result[k] = resolve_param_ref(v, params)
    return result


def parse_bit_slice(signal: str) -> Tuple[str, Optional[int], Optional[int]]:
    """Parse a signal name with optional bit slice.

    Returns (base_name, high_bit, low_bit).
    Examples:
        "cpu_0_irq[31:16]" -> ("cpu_0_irq", 31, 16)
        "p1_in[7]"         -> ("p1_in", 7, 7)
        "sys_hclk"         -> ("sys_hclk", None, None)
        "u_ss_cpu.sys_hclk" -> ("u_ss_cpu.sys_hclk", None, None)
        "u_ss_systemctrl.P1_OUT_MUX[6:4]" -> ("u_ss_systemctrl.P1_OUT_MUX", 6, 4)
    """
    m = re.match(r'^(.+?)\[(\d+):(\d+)\]$', signal)
    if m:
        return m.group(1), int(m.group(2)), int(m.group(3))

    m = re.match(r'^(.+?)\[(\d+)\]$', signal)
    if m:
        return m.group(1), int(m.group(2)), int(m.group(2))

    return signal, None, None


def bit_slice_width(high: Optional[int], low: Optional[int]) -> Optional[int]:
    """Calculate width of a bit slice. Returns None if no slice."""
    if high is None or low is None:
        return None
    return high - low + 1


def parse_conn_ref(conn: str) -> Tuple[Optional[str], str, Optional[int], Optional[int]]:
    """Parse a connection reference.

    Returns (instance_name, port_name, high_bit, low_bit).
    Examples:
        "u_ss_cpu.sys_hclk"     -> ("u_ss_cpu", "sys_hclk", None, None)
        "nanosoc_ahb_interconnect.cpu_0" -> ("nanosoc_ahb_interconnect", "cpu_0", None, None)
        "sys_sysresetn"         -> (None, "sys_sysresetn", None, None)
        "p1_in[6:0]"           -> (None, "p1_in", 6, 0)
        "u_ss_systemctrl.P1_OUT_MUX[6:4]" -> ("u_ss_systemctrl", "P1_OUT_MUX", 6, 4)
    """
    base, high, low = parse_bit_slice(conn)

    # Split on first dot to get instance.port
    parts = base.split('.', 1)
    if len(parts) == 2:
        return parts[0], parts[1], high, low
    return None, parts[0], high, low


def get_param_value(params: Dict[str, Any], name: str) -> Any:
    """Get a parameter value from a params dict, handling nested format.

    Params can be either {name: value} or {name: {type:, default:, desc:}}.
    """
    val = params.get(name)
    if isinstance(val, dict) and 'default' in val:
        return val['default']
    return val


def flatten_params(params: Dict[str, Any]) -> Dict[str, Any]:
    """Flatten a params dict from {name: {type, default, desc}} to {name: value}."""
    result = {}
    for name, val in params.items():
        if isinstance(val, dict) and 'default' in val:
            result[name] = val['default']
        else:
            result[name] = val
    return result
