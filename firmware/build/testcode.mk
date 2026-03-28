#-----------------------------------------------------------------------------
# NanoSoC Firmware Build - Shared Test Code Makefile Template
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Usage: Each test makefile sets configuration variables then includes this file.
#
# Required variables:
#   TESTNAME        - Name of the test (e.g., hello, gpio_tests)
#
# Optional variables (all have sensible defaults):
#   SOURCE_DIR      - Directory containing $(TESTNAME).c (default: test dir)
#   SOURCE_FILES    - Additional .c source files to compile and link
#   DRIVER_FILES    - Driver .c files (compiled without -g for size optimization)
#   EXTRA_INCLUDES  - Additional -I include paths
#   LINKER_NAME     - Linker script name without .ld (default: cmsdk_cm0)
#   LINKER_BASE_RO  - Read-only base address (default: CMSDK_CM0_RO_BASE)
#   LINKER_BASE_RW  - Read-write base address (default: CMSDK_CM0_RW_BASE)
#   OPT_LEVEL       - Optimization level (default: -O3)
#   USE_RETARGET    - Include retarget/uart_stdout (default: 1)
#   USE_GENERIC     - Add -I ../generic for config_id.h (default: 0)
#   CC_EXTRA_FLAGS  - Extra flags for ARM CC (e.g., --c99)
#   GNU_CC_EXTRA_FLAGS - Extra flags for GCC (e.g., -flto)
#   COMPILE_BIGEND  - Big endian build (default: 0)
#   COMPILE_MICROLIB - Use MicroLIB (default: 0)
#   COMPILE_SMALLMUL - Small multiplier (default: 0)
#   MAIN_SOURCE     - Override main source file (default: $(SOURCE_DIR)/$(TESTNAME).c)
#   OBJCOPY_EXTRA   - Extra flags for objcopy hex generation (e.g., --adjust-vma)
#   ARM_LINK_EXTRA  - Extra flags for armlink (e.g., --no_debug)
#-----------------------------------------------------------------------------

#=============================================================================
# Defaults
#=============================================================================
CPU_PRODUCT      ?= CORTEX_M0
TOOL_CHAIN       ?= ds5
TARGET           := arm-none-eabi
USE_RETARGET     ?= 1
USE_GENERIC      ?= 0
OPT_LEVEL        ?= -O3
CC_EXTRA_FLAGS   ?=
GNU_CC_EXTRA_FLAGS ?=
LINKER_NAME      ?= cmsdk_cm0
COMPILE_BIGEND   ?= 0
COMPILE_MICROLIB ?= 0
COMPILE_SMALLMUL ?= 0
OBJCOPY_EXTRA    ?=
ARM_LINK_EXTRA   ?=

#=============================================================================
# Environment Paths
#=============================================================================
SOFTWARE_DIR        := $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/software
CMSIS_DIR           := $(SOFTWARE_DIR)/cmsis
CORE_DIR            := $(CMSIS_DIR)/CMSIS/Include
FIRMWARE_CONFIG_DIR ?= $(SOCLABS_PROJECT_DIR)/build/firmware_config
-include $(FIRMWARE_CONFIG_DIR)/nanosoc_memmap.mk

#=============================================================================
# CPU Product Selection
#=============================================================================
ifeq ($(CPU_PRODUCT),CORTEX_M0PLUS)
  DEVICE_DIR   := $(CMSIS_DIR)/Device/ARM/CMSDK_CM0plus
  USER_DEFINE  := -DCORTEX_M0PLUS
  STARTUP_FILE := startup_CMSDK_CM0plus
  SYSTEM_FILE  := system_CMSDK_CM0plus
else
  DEVICE_DIR   := $(CMSIS_DIR)/Device/ARM/CMSDK_CM0
  USER_DEFINE  := -DCORTEX_M0
  STARTUP_FILE := startup_CMSDK_CM0
  SYSTEM_FILE  := system_CMSDK_CM0
endif

#=============================================================================
# Toolchain Configuration
#=============================================================================
include $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/toolchain/$(TOOL_CHAIN).mk

#=============================================================================
# Directory Setup
#=============================================================================
TEST_DIR   ?= $(CURDIR)
SOURCE_DIR ?= $(TEST_DIR)

DEPS_LIST := makefile

#=============================================================================
# Linker Base Addresses
#=============================================================================
LINKER_BASE_RO ?= $(CMSDK_CM0_RO_BASE)
LINKER_BASE_RW ?= $(CMSDK_CM0_RW_BASE)

#=============================================================================
# Include Paths
#=============================================================================
ALL_INCLUDES := -I $(DEVICE_DIR)/Include -I $(CORE_DIR) $(USER_DEFINE)

ifeq ($(USE_RETARGET),1)
  ALL_INCLUDES += -I $(SOFTWARE_DIR)/common/retarget
endif

ifeq ($(USE_GENERIC),1)
  ALL_INCLUDES += -I $(TEST_DIR)/../generic
  ALL_INCLUDES += -I $(FIRMWARE_CONFIG_DIR)
endif

ALL_INCLUDES += $(EXTRA_INCLUDES)

#=============================================================================
# Source File Assembly
#=============================================================================
# Main source file (overridable for tests like dhry where TESTNAME != source filename)
MAIN_SOURCE ?= $(SOURCE_DIR)/$(TESTNAME).c

# Core C sources
ALL_C_SOURCES := $(MAIN_SOURCE)
ALL_C_SOURCES += $(DEVICE_DIR)/Source/$(SYSTEM_FILE).c

# Retarget sources (optional)
ifeq ($(USE_RETARGET),1)
  ALL_C_SOURCES += $(SOFTWARE_DIR)/common/retarget/retarget.c
  ALL_C_SOURCES += $(SOFTWARE_DIR)/common/retarget/uart_stdout.c
endif

# Extra sources from test makefile
ALL_C_SOURCES += $(SOURCE_FILES)

# Assembly sources
ALL_ASM_SOURCES := $(STARTUP_DIR)/$(STARTUP_FILE).s

#=============================================================================
# ARM (DS-5/DS-6) Compiler Options
#=============================================================================
ifneq ($(TOOL_CHAIN),gcc)

ARM_CC_OPTIONS := $(CC_TARGET) -c $(OPT_LEVEL) -g $(CC_EXTRA_FLAGS) $(ALL_INCLUDES)
ARM_ASM_OPTIONS := -g

ARM_LINK_OPTIONS := "--keep=$(STARTUP_FILE).o(RESET)" "--first=$(STARTUP_FILE).o(RESET)" \
		--rw_base $(LINKER_BASE_RW) --ro_base $(LINKER_BASE_RO) --map $(ARM_LINK_EXTRA)

# Driver compile options (without -g for size optimization)
DRIVER_CC_OPTIONS ?= $(CC_TARGET) -c $(OPT_LEVEL) $(CC_EXTRA_FLAGS) $(ALL_INCLUDES)

ifeq ($(COMPILE_BIGEND),1)
  ARM_CC_OPTIONS   += --bigend
  ARM_ASM_OPTIONS  += --bigend
  ARM_LINK_OPTIONS += --be8
endif

ifeq ($(COMPILE_MICROLIB),1)
  ARM_CC_OPTIONS   += --library_type=microlib
  ARM_ASM_OPTIONS  += --library_type=microlib --pd "__MICROLIB SETA 1"
  ARM_LINK_OPTIONS += --library_type=microlib
endif

ifeq ($(COMPILE_SMALLMUL),1)
  ARM_CC_OPTIONS += --multiply_latency=32
endif

# --- Object file lists ---
# Standard C objects (named after source file basename)
STD_C_OBJECTS := $(notdir $(patsubst %.c,%.o,$(ALL_C_SOURCES)))

# Driver objects
DRIVER_OBJECTS := $(notdir $(patsubst %.c,%.o,$(DRIVER_FILES)))

# Assembly objects
ASM_OBJECTS := $(notdir $(patsubst %.s,%.o,$(ALL_ASM_SOURCES)))

# All objects for linking
COMPILE_OBJECTS := $(STD_C_OBJECTS) $(DRIVER_OBJECTS) $(ASM_OBJECTS)

# --- vpath for source file lookup ---
vpath %.c $(sort $(dir $(ALL_C_SOURCES) $(DRIVER_FILES)))
vpath %.s $(sort $(dir $(ALL_ASM_SOURCES)))

endif # ifneq gcc

#=============================================================================
# GCC Compiler Options
#=============================================================================
ifeq ($(TOOL_CHAIN),gcc)

GNU_CC_FLAGS := -g $(OPT_LEVEL) -mthumb $(CPU_TYPE) $(GCC_SPEC_OPTS) $(GNU_CC_EXTRA_FLAGS)

ifeq ($(COMPILE_BIGEND),1)
  GNU_CC_FLAGS += -mbig-endian
endif

# All sources for GCC single-command compile+link
GCC_ALL_SOURCES := $(ALL_ASM_SOURCES) $(ALL_C_SOURCES) $(DRIVER_FILES)

endif # ifeq gcc

#=============================================================================
# Build Targets
#=============================================================================
all: all_$(TOOL_CHAIN)

# ---------------------------------------------------------------------------------------
# DS-5 / DS-6 Build
# ---------------------------------------------------------------------------------------
all_ds5 : $(TESTNAME).hex $(TESTNAME).lst
all_ds6 : $(TESTNAME).hex $(TESTNAME).lst

ifneq ($(TOOL_CHAIN),gcc)

# Pattern rule for C sources
%.o: %.c $(DEPS_LIST)
	$(CC_TOOL) $(ARM_CC_OPTIONS) $(CPU_TYPE) $< -o $@

# Static pattern rule for driver files (different flags)
ifneq ($(DRIVER_OBJECTS),)
$(DRIVER_OBJECTS): %.o: %.c $(DEPS_LIST)
	$(CC_TOOL) $(DRIVER_CC_OPTIONS) $(CPU_TYPE) $< -o $@
endif

# Pattern rule for assembly sources
%.o: %.s $(DEPS_LIST)
	$(ASM_TOOL) $(ARM_ASM_OPTIONS) $(CPU_TYPE) $< -o $@

# Link
$(TESTNAME).ELF : $(COMPILE_OBJECTS)
	$(LINK_TOOL) $(ARM_LINK_OPTIONS) -o $@ $(COMPILE_OBJECTS)

# Generate Verilog hex
$(TESTNAME).hex : $(TESTNAME).ELF
	$(HEX_CMD)

# Generate binary
$(TESTNAME).bin : $(TESTNAME).ELF
	$(BIN_CMD)

# Generate listing
$(TESTNAME).lst : $(TESTNAME).ELF
	$(LST_CMD)

endif # ifneq gcc

# ---------------------------------------------------------------------------------------
# GCC Build
# ---------------------------------------------------------------------------------------
ifeq ($(TOOL_CHAIN),gcc)

all_gcc:
	$(CC_TOOL) $(GNU_CC_FLAGS) \
		$(GCC_ALL_SOURCES) \
		$(ALL_INCLUDES) \
		$(FIRMWARE_LINKER_SEARCH) \
		-D__STACK_SIZE=0x200 \
		-D__HEAP_SIZE=0x1000 \
		-T $(LINKER_SCRIPT) -o $(TESTNAME).o
	# Generate disassembly code
	$(GNU_OBJDUMP) -S $(TESTNAME).o > $(TESTNAME).lst
	# Generate binary file
	$(GNU_OBJCOPY) -S $(TESTNAME).o -O binary $(TESTNAME).bin
	# Generate hex file
	$(GNU_OBJCOPY) -S $(TESTNAME).o $(OBJCOPY_EXTRA) -O verilog $(TESTNAME).hex

endif # ifeq gcc

# ---------------------------------------------------------------------------------------
# Keil MDK (manual compilation)
# ---------------------------------------------------------------------------------------
all_keil:
	@echo "Please compile your project code and press ENTER when ready"
	@read dummy

# ---------------------------------------------------------------------------------------
# Binary (generate hex from pre-existing binary)
# ---------------------------------------------------------------------------------------
all_bin: $(TESTNAME).bin
	od -v -A n -t x1 --width=1 $(TESTNAME).bin > $(TESTNAME).hex

# ---------------------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------------------
clean :
	@rm -rf *.o
	@rm -f $(TESTNAME).hex $(TESTNAME).lst $(TESTNAME).ELF $(TESTNAME).bin
	@rm -rf *.crf *.plg *.tra *.htm *.map *.dep *.d
	@rm -rf *.lnp *.bak *.axf *.sct *.__i *._ia
