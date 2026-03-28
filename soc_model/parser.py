"""YAML file parser for SoC system descriptions.

Supports a two-directory layout:
  - base_dir: directory containing the top-level SoC YAML file
  - lib_dir:  directory containing reusable component descriptions
              (modules, interfaces, register_maps) — typically the
              arch_tech's rtl/sys_desc/ directory

Modules are discovered by recursively scanning lib_dir for YAML files
containing a 'module:' key. This allows the YAML hierarchy to mirror
the RTL source hierarchy (e.g. subsystems/cpu/, regions/bootrom_0/).
"""

import os
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml


class SoCParser:
    """Parses YAML system description files into raw dictionaries."""

    def __init__(self, base_dir: str, lib_dir: str = None):
        self.base_dir = Path(base_dir)
        self.lib_dir = Path(lib_dir) if lib_dir else self.base_dir
        self._module_cache: Dict[str, Dict] = {}
        self._modules_scanned = False

    def parse_top_level(self, filename: str) -> Dict[str, Any]:
        """Parse the top-level system YAML file."""
        filepath = self.base_dir / filename
        return self._load_yaml(filepath)

    def parse_module(self, module_name: str) -> Optional[Dict[str, Any]]:
        """Parse a module YAML file by module name.

        Scans the lib_dir recursively on first call, caching all
        discovered modules by both their module.name and filename stem.
        """
        if not self._modules_scanned:
            self._scan_modules()
            self._modules_scanned = True

        return self._module_cache.get(module_name)

    def _scan_modules(self):
        """Recursively scan lib_dir for module YAML files and cache them."""
        search_dirs = []

        # Legacy flat layout: lib_dir/modules/
        modules_dir = self.lib_dir / 'modules'
        if modules_dir.is_dir():
            search_dirs.append(modules_dir)

        # Hierarchical layout: lib_dir/subsystems/*/ and lib_dir/regions/*/
        for subdir_name in ('subsystems', 'regions'):
            subdir = self.lib_dir / subdir_name
            if subdir.is_dir():
                for child in subdir.iterdir():
                    if child.is_dir():
                        search_dirs.append(child)

        for search_dir in search_dirs:
            for yaml_file in search_dir.glob('*.yaml'):
                if yaml_file.name.startswith('.'):
                    continue
                data = self._load_yaml(yaml_file)
                if data and 'module' in data:
                    mod_data = data['module']
                    name = mod_data.get('name', '')
                    if name:
                        self._module_cache[name] = data
                    # Also cache by filename stem
                    self._module_cache[yaml_file.stem] = data

    def parse_register_map(self, filename: str) -> Optional[Dict[str, Any]]:
        """Parse a register map YAML file.

        Searches in both base_dir and lib_dir for the file.
        Accepts paths like 'register_maps/cmsdk_apb_timer.yaml'
        or just 'cmsdk_apb_timer.yaml'.
        """
        # Try base_dir first (for SoC-specific register maps)
        filepath = self.base_dir / filename
        if filepath.exists():
            return self._load_yaml(filepath)

        # Try lib_dir
        filepath = self.lib_dir / filename
        if filepath.exists():
            return self._load_yaml(filepath)

        # Try just the filename in lib_dir/register_maps/
        basename = Path(filename).name
        filepath = self.lib_dir / 'register_maps' / basename
        if filepath.exists():
            return self._load_yaml(filepath)

        print(f"Warning: Register map not found: {filename}")
        return None

    def parse_interface_definition(self, filename: str) -> Optional[Dict[str, Any]]:
        """Parse an interface definition YAML file.

        Searches in both base_dir and lib_dir interfaces/ directories.
        """
        for search_base in [self.base_dir, self.lib_dir]:
            filepath = search_base / filename
            if filepath.exists():
                return self._load_yaml(filepath)
            filepath = search_base / 'interfaces' / filename
            if filepath.exists():
                return self._load_yaml(filepath)

        return None

    def list_module_files(self) -> List[str]:
        """List all discovered module names."""
        if not self._modules_scanned:
            self._scan_modules()
            self._modules_scanned = True
        return list(self._module_cache.keys())

    def _load_yaml(self, filepath: Path) -> Dict[str, Any]:
        """Load a YAML file, handling errors gracefully."""
        try:
            with open(filepath) as f:
                data = yaml.safe_load(f)
            return data if data else {}
        except FileNotFoundError:
            print(f"Warning: File not found: {filepath}")
            return {}
        except yaml.YAMLError as e:
            print(f"Warning: YAML parse error in {filepath}: {e}")
            return {}
