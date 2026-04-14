#-----------------------------------------------------------------------------
# NanoSoC Firmware Build - DS-6 (armclang/armlink) Toolchain Configuration
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# Compiler and assembler tools
ARM_TARGET := --target=arm-$(TARGET)
CC_TOOL    := armclang
ASM_TOOL   := armclang -masm=armasm $(ARM_TARGET) -c
LINK_TOOL  := armlink

# DS-6 specific target flag — propagate ARM_TARGET so armclang gets
# --target=arm-arm-none-eabi (without it, armclang errors out with
# "no target architecture given").
CC_TARGET := $(ARM_TARGET)

# CPU type flags are pulled from the CPU description file included by
# testcode.mk before this toolchain file is included.
CPU_TYPE := $(CPU_FLAGS_ARMCLANG)

# Startup code directory
STARTUP_DIR := $(DEVICE_DIR)/Source/ARM

# Output tools (same as DS-5)
HEX_CMD  = fromelf --vhx --8x1 $< --output $@
BIN_CMD  = fromelf --bin $< --output $@
LST_CMD  = fromelf -c -d -e -s -z -v $< --output $@
