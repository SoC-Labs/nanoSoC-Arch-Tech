#!/usr/bin/env python3
#------------------------------------------------------------------------------------
# Verilog and Binary Bootrom Generation Script
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (c) 2023, SoC Labs (www.soclabs.org)
#------------------------------------------------------------------------------------

import argparse
import math
import os
from jinja2 import Environment, FileSystemLoader
from datetime import datetime

TEMPLATE_NAME         = 'bootrom_templ.sv.jinja'
REGION_TEMPLATE_NAME  = 'bootrom_region_templ.v.jinja'
DATA_WIDTH            = 32
ADDRESS_WIDTH         = 9
MODULE_NAME           = 'bootrom'

def normalise_hex_file(input_hex):
    """Read a hex file and return a flat list of hex byte strings.

    Handles hex files with:
    - @address lines (with arbitrary base address offsets)
    - Multiple space-separated bytes per line
    - One byte per line
    - Non-contiguous address sections (gaps filled with 00)
    """
    with open(input_hex, "r") as f:
        hex_lines = f.readlines()

    # First pass: collect addressed sections
    sections = []  # list of (address, [byte_strings])
    base_address = None
    current_address = None
    current_bytes = []
    has_address_lines = False

    for line in hex_lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith('@'):
            has_address_lines = True
            # Save previous section
            if current_address is not None and current_bytes:
                sections.append((current_address, current_bytes))
            current_address = int(line[1:], 16)
            if base_address is None:
                base_address = current_address
            current_bytes = []
        else:
            # Parse space-separated hex bytes from line
            for b in line.split():
                current_bytes.append(b)

    # Save final section
    if current_address is not None and current_bytes:
        sections.append((current_address, current_bytes))

    if not has_address_lines:
        # No @ lines found - return all parsed bytes directly
        return current_bytes

    # Build flat byte list from sections, filling gaps with 00
    hex_bytes = []
    for addr, data in sections:
        relative_addr = addr - base_address
        # Fill gap between previous data and this section
        while len(hex_bytes) < relative_addr:
            hex_bytes.append("00")
        hex_bytes.extend(data)

    return hex_bytes

def bootrom_gen(args):
    # Extract Data from Parsed Arguments
    input_hex = args.input_hex
    address_width = args.address_width
    output_verilog = args.verilog_output
    output_binary = args.binary_output
    module_name = args.module_name or MODULE_NAME
    
    # Create Binary and Verilog Outputs
    print(f"Generating Bootrom {input_hex}")
    if(args.tool_chain=='gcc'):
        bootrom_verilog, bootrom_binary = output_construct_gcc(input_hex, address_width, module_name)
    else:
        bootrom_verilog, bootrom_binary = output_construct(input_hex, address_width, module_name)

    # Write Out Verilog File
    f_verilog = open(output_verilog, "w")
    f_verilog.write(bootrom_verilog)
    f_verilog.close()

    # Write Out Binary File
    f_binary = open(output_binary, "w")
    f_binary.write(bootrom_binary)
    f_binary.close()

    # Optionally generate the bootrom region wrapper
    if args.region_output and args.region_module_name:
        region_verilog = generate_region_wrapper(args.region_module_name, module_name)
        with open(args.region_output, "w") as f:
            f.write(region_verilog)
        print(f"Generated region wrapper: {args.region_output}")

def generate_region_wrapper(region_module_name, rom_module_name):
    """Generate a bootrom region wrapper using the Jinja2 template."""
    template_dir = os.path.dirname(os.path.abspath(__file__))
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template(REGION_TEMPLATE_NAME)
    date_str = datetime.today().strftime('%Y-%m-%d %H:%M:%S')
    return template.render(
        region_module_name=region_module_name,
        rom_module_name=rom_module_name,
        date=date_str
    )

def output_construct(input_hex, address_width, module_name=MODULE_NAME):
    # Read in Hex File
    f = open(input_hex, "r")
    hex_bytes = f.readlines()
    f.close()

    # Number of bytes addressable by the requested word_addr width
    address_bytes = 1 << (address_width + 2)
    print(len(hex_bytes))

    if len(hex_bytes) > address_bytes:
        raise SystemExit(
            f"ERROR: bootrom_gen: input '{input_hex}' is {len(hex_bytes)} bytes "
            f"but -a {address_width} only addresses {address_bytes} bytes. "
            f"Increase BOOTROM_ADDRW (need at least "
            f"{max(1, math.ceil(math.log2(math.ceil(len(hex_bytes)/4))))})."
        )

    # Fill hex_bytes with zeros for addresses than aren't in the hex file
    while (len(hex_bytes) < address_bytes): hex_bytes.append("00")
    hex_words = math.ceil(len(hex_bytes)/4)
    hex_data = []

    # Combine bytes into words and prepare data for template
    hex_data_for_template = []
    for i in range(hex_words):
        temp_hex_word= f"{hex_bytes[i*4+3].rstrip()}{hex_bytes[(i*4)+2].rstrip()}{hex_bytes[(i*4)+1].rstrip()}{hex_bytes[(i*4)].rstrip()}"
        word_value = int(temp_hex_word, 16)
        hex_data.append(word_value)
        hex_data_for_template.append({'index': i, 'word': word_value})

    # Get Date and Time to put in Generated Header
    date_str = datetime.today().strftime('%Y-%m-%d %H:%M:%S')

    # Set up Jinja2 environment and load template
    template_dir = os.path.dirname(os.path.abspath(__file__))
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template(TEMPLATE_NAME)
    
    # Generate complete Verilog module using Jinja2 template
    bootrom_verilog = template.render(
        module_name=module_name,
        word_address_width=address_width,
        data_width=32,
        date=date_str,
        hex_data=hex_data_for_template
    )

    bootrom_binary = ""

    # Generate binary data
    for word in hex_data:
        temp_binary = f"""{word:032b}\n"""
        bootrom_binary += temp_binary

    return bootrom_verilog, bootrom_binary

def output_construct_gcc(input_hex, address_width, module_name=MODULE_NAME):
    # Read and normalise hex file to a flat list of byte strings
    hex_bytes = normalise_hex_file(input_hex)

    # Number of bytes addressable by the requested word_addr width
    address_bytes = 1 << (address_width + 2)

    # Refuse to silently emit more entries than the requested word_addr can
    # index. Without this guard, case-statement labels above 2^address_width
    # quietly truncate to width and collide with low addresses, corrupting
    # the boot image (and producing width-mismatch errors at synthesis).
    if len(hex_bytes) > address_bytes:
        raise SystemExit(
            f"ERROR: bootrom_gen: input '{input_hex}' is {len(hex_bytes)} bytes "
            f"but -a {address_width} only addresses {address_bytes} bytes. "
            f"Increase BOOTROM_ADDRW (need at least "
            f"{max(1, math.ceil(math.log2(math.ceil(len(hex_bytes)/4))))})."
        )

    # Pad with zeros to fill the addressable space
    while (len(hex_bytes) < address_bytes): hex_bytes.append("00")
    hex_words = math.ceil(len(hex_bytes)/4)
    hex_data = []

    # Combine bytes into words and prepare data for template
    hex_data_for_template = []
    for i in range(hex_words):
        temp_hex_word= f"{hex_bytes[i*4+3].rstrip()}{hex_bytes[(i*4)+2].rstrip()}{hex_bytes[(i*4)+1].rstrip()}{hex_bytes[(i*4)].rstrip()}"
        word_value = int(temp_hex_word, 16)
        hex_data.append(word_value)
        hex_data_for_template.append({'index': i, 'word': word_value})
    
    # Get Date and Time to put in Generated Header
    date_str = datetime.today().strftime('%Y-%m-%d %H:%M:%S')

    # Set up Jinja2 environment and load template
    template_dir = os.path.dirname(os.path.abspath(__file__))
    env = Environment(loader=FileSystemLoader(template_dir))
    template = env.get_template(TEMPLATE_NAME)
    
    # Generate complete Verilog module using Jinja2 template.
    # NOTE: use the CLI-supplied address_width, not the ADDRESS_WIDTH
    # module-level default, so `-a 11` actually produces an 11-bit
    # word_addr (2 KB bootrom at 4-byte words = 8 KB total). Previously
    # the GCC path silently ignored -a and always emitted 9 bits,
    # truncating the reachable ROM to 512 words.
    bootrom_verilog = template.render(
        module_name=module_name,
        word_address_width=address_width,
        data_width=DATA_WIDTH,
        date=date_str,
        hex_data=hex_data_for_template
    )

    bootrom_binary = ""

    # Generate binary data
    for word in hex_data:
        temp_binary = f"""{word:032b}\n"""
        bootrom_binary += temp_binary

    return bootrom_verilog, bootrom_binary

if __name__ == "__main__":
    # Capture Arguments from Command Line
    parser = argparse.ArgumentParser(description='Generates NanoSoC CPU Bootrom File')
    parser.add_argument("-i", "--input_hex", type=str, help="Input Hex File to Generate Bootrom from")
    parser.add_argument("-a", "--address_width", type=int, help="Address Width (In 32bit Words) of Bootrom")
    parser.add_argument("-v", "--verilog_output", type=str, help="Output Bootrom verilog file")
    parser.add_argument("-b", "--binary_output", type=str, help="Output Bootrom binary file")
    parser.add_argument("-t", "--tool_chain", type=str, help="Tool Chain used to generate binary")
    parser.add_argument("-m", "--module_name", type=str, default=MODULE_NAME, help="Verilog module name for generated ROM (default: bootrom)")
    parser.add_argument("-r", "--region_output", type=str, default=None, help="Output path for generated bootrom region wrapper")
    parser.add_argument("-R", "--region_module_name", type=str, default=None, help="Verilog module name for the region wrapper (e.g. eth_ss_region_bootrom)")

    args = parser.parse_args()
    bootrom_gen(args)