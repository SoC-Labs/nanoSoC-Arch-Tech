#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# NanoSoC QSPI Flash Image Packing Tool
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Assembles a complete QSPI flash binary from:
#   - YAML flash_layout partition definitions
#   - Per-core Stage 1 bootloader binaries
#   - Per-core application image binaries
#
# Generates:
#   - Boot table (header + per-core entries with offsets, sizes, CRCs)
#   - Complete flash image with all partitions placed at their defined offsets
#
# Usage:
#   python3 flash_pack.py --yaml <soc.yaml> --output <flash.bin> \
#       --stage1 <core_id>:<stage1.bin> --app <core_id>:<app.bin>
#
# Example:
#   python3 flash_pack.py --yaml nanosoc_m0_soc.yaml --output flash.bin \
#       --stage1 0:stage1_core0.bin --app 0:app_core0.bin
#

import argparse
import struct
import sys
import os

# Boot table constants (must match boot_table.h)
BOOT_TABLE_MAGIC = 0x424F4F54   # "BOOT"
BOOT_TABLE_VERSION = 1
BOOT_ENTRY_FLAG_VALID = 0x01
BOOT_TABLE_ENTRY_SIZE = 32      # bytes per entry
BOOT_TABLE_HEADER_SIZE = 16     # bytes for header


def crc32(data):
    """Compute CRC32 matching the boot_table.h implementation."""
    import binascii
    return binascii.crc32(data) & 0xFFFFFFFF


def parse_yaml_flash_layout(yaml_path):
    """Parse flash_layout from YAML file.

    Returns a dict with partition definitions:
        { 'partitions': [ {'name': str, 'offset': int, 'size': int, 'type': str}, ... ] }
    """
    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML not installed. Install with: pip install pyyaml",
              file=sys.stderr)
        sys.exit(1)

    with open(yaml_path, 'r') as f:
        data = yaml.safe_load(f)

    # Navigate to flash_layout section
    module = data.get('module', data)
    flash_layout = module.get('flash_layout', None)

    if flash_layout is None:
        print(f"ERROR: No flash_layout section found in {yaml_path}",
              file=sys.stderr)
        sys.exit(1)

    return flash_layout


def build_boot_table(entries, num_cores):
    """Build the boot table binary (header + entries).

    Args:
        entries: dict mapping core_id -> (stage1_offset, stage1_size, stage1_crc,
                                          app_offset, app_size, app_crc)
        num_cores: total number of core entries

    Returns:
        bytes: the complete boot table binary
    """
    # Header: magic, version, num_entries, reserved
    header = struct.pack('<IIII',
                         BOOT_TABLE_MAGIC,
                         BOOT_TABLE_VERSION,
                         num_cores,
                         0)  # reserved

    # Entries
    entry_data = b''
    for core_id in range(num_cores):
        if core_id in entries:
            e = entries[core_id]
            entry_data += struct.pack('<IIIIIIII',
                                      e['stage1_offset'],
                                      e['stage1_size'],
                                      e['app_offset'],
                                      e['app_size'],
                                      BOOT_ENTRY_FLAG_VALID,
                                      e['stage1_crc'],
                                      e['app_crc'],
                                      0)  # reserved
        else:
            # Invalid/empty entry
            entry_data += struct.pack('<IIIIIIII', 0, 0, 0, 0, 0, 0, 0, 0)

    return header + entry_data


def main():
    parser = argparse.ArgumentParser(
        description='NanoSoC QSPI Flash Image Packing Tool')
    parser.add_argument('--yaml', required=False,
                        help='Path to SoC YAML with flash_layout section')
    parser.add_argument('--output', '-o', required=True,
                        help='Output flash binary file')
    parser.add_argument('--flash-size', type=lambda x: int(x, 0),
                        default=0x400000,
                        help='Total flash size in bytes (default: 4MB)')
    parser.add_argument('--stage1', action='append', default=[],
                        help='Stage 1 binary: CORE_ID:filename (repeatable)')
    parser.add_argument('--app', action='append', default=[],
                        help='Application binary: CORE_ID:filename (repeatable)')
    parser.add_argument('--boot-table-offset', type=lambda x: int(x, 0),
                        default=0x0,
                        help='Boot table offset in flash (default: 0x0)')
    parser.add_argument('--stage1-offset', type=lambda x: int(x, 0),
                        default=0x1000,
                        help='Base offset for Stage 1 images (default: 0x1000)')
    parser.add_argument('--stage1-stride', type=lambda x: int(x, 0),
                        default=0x1000,
                        help='Stride between Stage 1 images (default: 0x1000)')
    parser.add_argument('--app-offset', type=lambda x: int(x, 0),
                        default=0x10000,
                        help='Base offset for app images (default: 0x10000)')
    parser.add_argument('--app-stride', type=lambda x: int(x, 0),
                        default=0x10000,
                        help='Stride between app images (default: 0x10000)')

    args = parser.parse_args()

    # Parse partition offsets from YAML if provided
    partitions = {}
    if args.yaml and os.path.exists(args.yaml):
        flash_layout = parse_yaml_flash_layout(args.yaml)
        for p in flash_layout.get('partitions', []):
            partitions[p['name']] = p

    # Parse stage1 and app binary file mappings
    stage1_bins = {}
    for spec in args.stage1:
        core_id_str, filename = spec.split(':', 1)
        core_id = int(core_id_str)
        with open(filename, 'rb') as f:
            stage1_bins[core_id] = f.read()
        print(f"  Stage 1 core {core_id}: {filename} ({len(stage1_bins[core_id])} bytes)")

    app_bins = {}
    for spec in args.app:
        core_id_str, filename = spec.split(':', 1)
        core_id = int(core_id_str)
        with open(filename, 'rb') as f:
            app_bins[core_id] = f.read()
        print(f"  App core {core_id}: {filename} ({len(app_bins[core_id])} bytes)")

    # Determine number of cores
    all_core_ids = set(stage1_bins.keys()) | set(app_bins.keys())
    if not all_core_ids:
        print("ERROR: No Stage 1 or app binaries specified", file=sys.stderr)
        sys.exit(1)
    num_cores = max(all_core_ids) + 1

    # Calculate offsets for each core
    entries = {}
    for core_id in sorted(all_core_ids):
        # Determine Stage 1 offset
        part_name = f"cpu_{core_id}_stage1"
        if part_name in partitions:
            s1_offset = partitions[part_name]['offset']
        else:
            s1_offset = args.stage1_offset + core_id * args.stage1_stride

        # Determine app offset
        part_name = f"cpu_{core_id}_app"
        if part_name in partitions:
            app_offset = partitions[part_name]['offset']
        else:
            app_offset = args.app_offset + core_id * args.app_stride

        s1_data = stage1_bins.get(core_id, b'')
        app_data = app_bins.get(core_id, b'')

        entries[core_id] = {
            'stage1_offset': s1_offset,
            'stage1_size': len(s1_data),
            'stage1_crc': crc32(s1_data) if s1_data else 0,
            'app_offset': app_offset,
            'app_size': len(app_data),
            'app_crc': crc32(app_data) if app_data else 0,
        }

    # Build boot table
    boot_table = build_boot_table(entries, num_cores)

    # Assemble flash image
    flash = bytearray(args.flash_size)
    # Fill with 0xFF (erased flash state)
    for i in range(len(flash)):
        flash[i] = 0xFF

    # Place boot table
    bt_offset = args.boot_table_offset
    flash[bt_offset:bt_offset + len(boot_table)] = boot_table
    print(f"  Boot table: offset 0x{bt_offset:08X}, {len(boot_table)} bytes")

    # Place Stage 1 and app binaries
    for core_id in sorted(all_core_ids):
        e = entries[core_id]

        if core_id in stage1_bins:
            data = stage1_bins[core_id]
            offset = e['stage1_offset']
            flash[offset:offset + len(data)] = data
            print(f"  Core {core_id} Stage 1: offset 0x{offset:08X}, "
                  f"{len(data)} bytes, CRC32=0x{e['stage1_crc']:08X}")

        if core_id in app_bins:
            data = app_bins[core_id]
            offset = e['app_offset']
            flash[offset:offset + len(data)] = data
            print(f"  Core {core_id} App:     offset 0x{offset:08X}, "
                  f"{len(data)} bytes, CRC32=0x{e['app_crc']:08X}")

    # Write output
    with open(args.output, 'wb') as f:
        f.write(flash)
    print(f"\nFlash image written: {args.output} ({len(flash)} bytes)")


if __name__ == '__main__':
    main()
