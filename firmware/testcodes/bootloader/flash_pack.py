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

# Boot table constants (must match firmware/include/nanosoc_multicore_addrmap.h).
# CYCLE 3: the header is now v2 (32 bytes: magic, version=2, num_entries, seq,
# table_crc, active_note, reserved[2]); the entry format (32 B) is UNCHANGED.
# A v1 header (16 B: magic, version=1, num_entries, reserved) is still emittable
# via --table-version 1 for regression parity (CYCLE3_CONTRACT.md §2.3).
BOOT_TABLE_MAGIC = 0x424F4F54   # "BOOT"
BOOT_TABLE_VERSION = 2          # v2 (Cycle 3); was 1
BOOT_TABLE_VERSION_V1 = 1       # legacy single-table
BOOT_ENTRY_FLAG_VALID = 0x01
BOOT_TABLE_ENTRY_SIZE = 32      # bytes per entry (unchanged)
BOOT_TABLE_HEADER_SIZE = 32     # v2 header bytes (v1 = 16)
BOOT_TABLE_HEADER_SIZE_V1 = 16

# PINNED table_crc (v2) coverage — MUST match the ROM (addrmap.h
# NANOSOC_BOOT_TABLE_CRC_START_OFF): CRC32 over the table bytes
#   [ 0x14 , 0x20 + num_entries*0x20 )
# i.e. from active_note (0x14) through the end of the entries, excluding
# magic/version/num_entries/seq (0x00..0x14) and the table_crc field (0x10).
BOOT_TABLE_CRC_START_OFF = 0x14

# ---------------------------------------------------------------------------
# Boot ROLE -> PHYSICAL core_id mapping (CPU1-chip-control inversion, dec. B).
#
# Entries are written keyed by PHYSICAL core_id (the --app/--stage1
# CORE_ID:file argument), which is UNCHANGED by the inversion: eth/CPU0 stays
# physical entry 0 and CPU1 stays physical entry 1. The boot-role swap is
# purely behavioural in the bootroms (the chip-control MANAGER is CPU1, the
# SECONDARY is eth/CPU0). These role names document, for image builders, which
# physical slot each boot role maps to; the firmware side mirrors them in
# firmware/include/nanosoc_multicore_addrmap.h
# (NANOSOC_BOOT_ROLE_MASTER_IDX / NANOSOC_BOOT_ROLE_SECONDARY_IDX). Keeping the
# physical keying fixed is what lets the existing flash-builder tests stay green.
# ---------------------------------------------------------------------------
BOOT_PHYS_IDX_CPU0      = 0     # physical entry 0 = eth/CPU0
BOOT_PHYS_IDX_CPU1      = 1     # physical entry 1 = CPU1
BOOT_ROLE_MASTER_IDX    = BOOT_PHYS_IDX_CPU1   # chip-control MANAGER = CPU1
BOOT_ROLE_SECONDARY_IDX = BOOT_PHYS_IDX_CPU0   # SECONDARY            = eth/CPU0


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


def _pack_entries(entries, num_cores):
    """Pack the fixed 32-B-per-entry body (identical for v1 and v2)."""
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
    return entry_data


def build_boot_table(entries, num_cores, version=BOOT_TABLE_VERSION,
                     seq=1, active_note=0):
    """Build the boot table binary (header + entries).

    version 2 (default) -> 32-B v2 header {magic, version, num_entries, seq,
        table_crc, active_note, reserved[2]} with table_crc over the PINNED
        range [0x14 .. 0x20 + num_entries*0x20) (matches the bootrom).
    version 1 -> legacy 16-B header {magic, version, num_entries, reserved};
        no seq / table_crc (regression parity, --table-version 1).

    The entry body (32 B/entry) is identical for both.
    """
    entry_data = _pack_entries(entries, num_cores)

    if version == BOOT_TABLE_VERSION_V1:
        header = struct.pack('<IIII', BOOT_TABLE_MAGIC, BOOT_TABLE_VERSION_V1,
                             num_cores, 0)  # reserved
        return header + entry_data

    # v2: build with a zero table_crc placeholder, CRC the pinned range, patch.
    header = struct.pack('<IIIIIIII',
                         BOOT_TABLE_MAGIC,   # 0x00 magic
                         BOOT_TABLE_VERSION, # 0x04 version = 2
                         num_cores,          # 0x08 num_entries
                         seq,                # 0x0C seq
                         0,                  # 0x10 table_crc (placeholder)
                         active_note,        # 0x14 active_note
                         0, 0)               # 0x18 reserved[2]
    table = bytearray(header + entry_data)
    crc_end = BOOT_TABLE_HEADER_SIZE + num_cores * BOOT_TABLE_ENTRY_SIZE
    table_crc = crc32(bytes(table[BOOT_TABLE_CRC_START_OFF:crc_end]))
    struct.pack_into('<I', table, 0x10, table_crc)
    return bytes(table)


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

    # --- Cycle 3: v2 boot-table + A/B/golden slot layout --------------------
    parser.add_argument('--table-version', type=int, choices=(1, 2), default=2,
                        help='Boot-table header version: 2 = v2 (seq + '
                             'table_crc, default), 1 = legacy 16-B header '
                             '(regression parity)')
    parser.add_argument('--seq', type=lambda x: int(x, 0), default=1,
                        help='v2 monotonic sequence number (default: 1)')
    parser.add_argument('--active-note', type=lambda x: int(x, 0), default=None,
                        help='v2 active_note (0=A/1=B); default auto from the '
                             'CPU1 slot')
    parser.add_argument('--cpu1-slot', choices=('A', 'B'), default=None,
                        help='Place the CPU1 (core 1) app into A/B slot and set '
                             'active_note accordingly')
    parser.add_argument('--slot-a-offset', type=lambda x: int(x, 0),
                        default=0x30000, help='CPU1 image Slot A (default 0x30000)')
    parser.add_argument('--slot-b-offset', type=lambda x: int(x, 0),
                        default=0x40000, help='CPU1 image Slot B (default 0x40000)')
    parser.add_argument('--table1-offset', type=lambda x: int(x, 0), default=None,
                        help='Also write a duplicate boot-table copy here '
                             '(secondary sector, e.g. 0x10000)')
    parser.add_argument('--golden', default=None,
                        help='Golden CPU1 recovery image .bin (self-describing '
                             'v2 mini-table + image written to --golden-offset)')
    parser.add_argument('--golden-offset', type=lambda x: int(x, 0),
                        default=0x50000, help='Golden slot (default 0x50000)')

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

    # Cycle 3: optionally steer the CPU1 (core 1) app into an A/B slot and set
    # active_note so the on-flash offset matches the ping-pong layout.
    active_note = args.active_note
    if args.cpu1_slot is not None and BOOT_PHYS_IDX_CPU1 in entries:
        slot_off = args.slot_b_offset if args.cpu1_slot == 'B' else args.slot_a_offset
        entries[BOOT_PHYS_IDX_CPU1]['app_offset'] = slot_off
        if active_note is None:
            active_note = 1 if args.cpu1_slot == 'B' else 0
    if active_note is None:
        active_note = 0

    # Build boot table
    boot_table = build_boot_table(entries, num_cores,
                                  version=args.table_version,
                                  seq=args.seq, active_note=active_note)

    # Assemble flash image
    flash = bytearray(args.flash_size)
    # Fill with 0xFF (erased flash state)
    for i in range(len(flash)):
        flash[i] = 0xFF

    # Place boot table (primary copy)
    bt_offset = args.boot_table_offset
    flash[bt_offset:bt_offset + len(boot_table)] = boot_table
    print(f"  Boot table: v{args.table_version} offset 0x{bt_offset:08X}, "
          f"{len(boot_table)} bytes, seq={args.seq}")

    # Optional duplicate copy in a second sector (dual sequenced tables, §3b).
    if args.table1_offset is not None:
        flash[args.table1_offset:args.table1_offset + len(boot_table)] = boot_table
        print(f"  Boot table copy 1: offset 0x{args.table1_offset:08X}")

    # Optional golden slot: a self-describing v2 mini-table at --golden-offset
    # whose CPU1 (entry 1) points at the golden image placed right after it.
    # The ROM tries this via the identical validate+load+CRC path (§4.2).
    if args.golden is not None:
        with open(args.golden, 'rb') as f:
            gdata = f.read()
        while len(gdata) % 4:
            gdata += b'\x00'
        g_img_off = args.golden_offset + BOOT_TABLE_HEADER_SIZE + \
            2 * BOOT_TABLE_ENTRY_SIZE
        g_entries = {
            BOOT_PHYS_IDX_CPU0: {'stage1_offset': 0, 'stage1_size': 0,
                                 'stage1_crc': 0, 'app_offset': 0,
                                 'app_size': 0, 'app_crc': 0},
            BOOT_PHYS_IDX_CPU1: {'stage1_offset': 0, 'stage1_size': 0,
                                 'stage1_crc': 0, 'app_offset': g_img_off,
                                 'app_size': len(gdata),
                                 'app_crc': crc32(gdata)},
        }
        g_table = build_boot_table(g_entries, 2, version=2, seq=0, active_note=0)
        flash[args.golden_offset:args.golden_offset + len(g_table)] = g_table
        flash[g_img_off:g_img_off + len(gdata)] = gdata
        print(f"  Golden: table 0x{args.golden_offset:08X}, image 0x{g_img_off:08X}, "
              f"{len(gdata)} bytes, CRC32=0x{crc32(gdata):08X}")

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
