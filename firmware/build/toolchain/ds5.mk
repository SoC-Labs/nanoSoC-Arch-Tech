#-----------------------------------------------------------------------------
# NanoSoC Firmware Build - DS-5 (armcc/armasm/armlink) Toolchain Configuration
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# Compiler and assembler tools
CC_TOOL   := armcc
ASM_TOOL  := armasm
LINK_TOOL := armlink

# DS-5 specific target flag
CC_TARGET ?= -Otime

# CPU type flags are pulled from the CPU description file included by
# testcode.mk before this toolchain file is included.
CPU_TYPE := $(CPU_FLAGS_ARMCC)

# Startup code directory
STARTUP_DIR := $(DEVICE_DIR)/Source/ARM

# Output tools
HEX_CMD  = fromelf --vhx --8x1 $< --output $@
BIN_CMD  = fromelf --bin $< --output $@
LST_CMD  = fromelf -c -d -e -s -z -v $< --output $@
