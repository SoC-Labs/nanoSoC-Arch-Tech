#-----------------------------------------------------------------------------
# NanoSoC Firmware Build - GCC (arm-none-eabi) Toolchain Configuration
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# Compiler and assembler tools
CC_TOOL     := $(TARGET)-gcc
GNU_OBJDUMP := $(TARGET)-objdump
GNU_OBJCOPY := $(TARGET)-objcopy

# CC_TARGET not used for GCC
CC_TARGET :=

# CPU type flags are pulled from the CPU description file included by
# testcode.mk before this toolchain file is included.
CPU_TYPE := $(CPU_FLAGS_GCC)

# Startup code directory
STARTUP_DIR := $(DEVICE_DIR)/Source/GCC

# Linker script support
LINKER_SCRIPT_PATH := $(SOFTWARE_DIR)/common/scripts
LINKER_SCRIPT       = $(LINKER_SCRIPT_PATH)/$(LINKER_NAME).ld

# Search path for generated linker MEMORY fragments
FIRMWARE_LINKER_SEARCH = -L $(LINKER_SCRIPT_PATH) -L $(FIRMWARE_CONFIG_DIR)

# GCC optimization specs
GCC_SPEC_OPTS := --specs=nano.specs -Wl,--gc-sections
