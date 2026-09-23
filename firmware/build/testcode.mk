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
TOOL_CHAIN       ?= ds5
TARGET           := arm-none-eabi
USE_RETARGET     ?= 1
USE_GENERIC      ?= 0
OPT_LEVEL        ?= -O3
# Per-toolchain extra flags. CC_EXTRA_FLAGS is applied to BOTH ARM compilers
# (AC5 armcc and AC6 armclang) for backward compat. Use the toolchain-specific
# variables for flags that differ (e.g. AC5 `--c99` vs AC6 `-std=c99`).
CC_EXTRA_FLAGS        ?=
CC_EXTRA_FLAGS_ARMCC  ?=
CC_EXTRA_FLAGS_ARMCLANG ?=
GNU_CC_EXTRA_FLAGS    ?=
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
FIRMWARE_CONFIG_DIR ?= $(SOCLABS_NANOSOC_SOC_DIR)/build_soc/firmware
-include $(FIRMWARE_CONFIG_DIR)/nanosoc_memmap.mk

#=============================================================================
# CPU Selection (data-driven)
#
# Resolution order (first non-empty wins):
#   1. NANOSOC_CPU=<name> on the make command line or environment
#   2. CPU_PRODUCT=CORTEX_M0[PLUS] (legacy, translated here)
#   3. NANOSOC_DEFAULT_CPU from the generated *_memmap.mk (driven by YAML)
#   4. Hard-coded fallback: cortex-m0
#=============================================================================
ifdef CPU_PRODUCT
  ifeq ($(CPU_PRODUCT),CORTEX_M0PLUS)
    NANOSOC_CPU ?= cortex-m0plus
  else
    NANOSOC_CPU ?= cortex-m0
  endif
endif

NANOSOC_CPU ?= $(NANOSOC_DEFAULT_CPU)
NANOSOC_CPU ?= cortex-m0

CPUS_DIR := $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/cpus
CPU_FILE := $(CPUS_DIR)/$(NANOSOC_CPU).mk
ifeq ($(wildcard $(CPU_FILE)),)
  $(error NANOSOC_CPU='$(NANOSOC_CPU)' has no description file. \
          Expected: $(CPU_FILE). \
          Available: $(notdir $(basename $(wildcard $(CPUS_DIR)/*.mk))))
endif
include $(CPU_FILE)

# Backward-compatibility: older makefiles / flows pass CPU_PRODUCT. Keep the
# variable exported so sub-makes that also reference it still work.
ifeq ($(NANOSOC_CPU),cortex-m0plus)
  CPU_PRODUCT := CORTEX_M0PLUS
else
  CPU_PRODUCT := CORTEX_M0
endif

DEVICE_DIR   := $(CMSIS_DIR)/Device/ARM/$(CPU_DEVICE_DIR_NAME)
USER_DEFINE  := -D$(CPU_DEFINE)
STARTUP_FILE := $(CPU_STARTUP_STEM)
SYSTEM_FILE  := $(CPU_SYSTEM_STEM)

#=============================================================================
# C Library Variant (data-driven) — resolved BEFORE the toolchain file
# so gcc.mk / ds6.mk / ds5.mk can read CLIB_* to build their own flag strings.
#
# Resolution order:
#   1. NANOSOC_C_LIBRARY=<name> on the make command line
#   2. COMPILE_MICROLIB=1 (legacy) → microlib
#   3. Sensible toolchain default (gcc → nano, others → default)
#=============================================================================
ifeq ($(COMPILE_MICROLIB),1)
  NANOSOC_C_LIBRARY ?= microlib
endif
ifeq ($(TOOL_CHAIN),gcc)
  NANOSOC_C_LIBRARY ?= nano
else
  NANOSOC_C_LIBRARY ?= default
endif

LIBRARIES_DIR := $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/libraries
CLIB_FILE := $(LIBRARIES_DIR)/$(NANOSOC_C_LIBRARY).mk
ifeq ($(wildcard $(CLIB_FILE)),)
  $(error NANOSOC_C_LIBRARY='$(NANOSOC_C_LIBRARY)' has no description file. \
          Expected: $(CLIB_FILE). \
          Available: $(notdir $(basename $(wildcard $(LIBRARIES_DIR)/*.mk))))
endif
include $(CLIB_FILE)

ifeq ($(filter $(TOOL_CHAIN),$(CLIB_SUPPORTED)),)
  $(error NANOSOC_C_LIBRARY='$(NANOSOC_C_LIBRARY)' ($(CLIB_DISPLAY_NAME)) \
          does not support TOOL_CHAIN='$(TOOL_CHAIN)'. \
          Supported: $(CLIB_SUPPORTED))
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
# Build Output Directory Setup
#=============================================================================
SOFTWARE_BUILD_DIR ?= $(SOCLABS_PROJECT_DIR)/build/firmware
TEST_BUILD_DIR    := $(SOFTWARE_BUILD_DIR)/$(TESTNAME)
COMPILE_DIR       := $(TEST_BUILD_DIR)/compile
OUTPUT_DIR        := $(TEST_BUILD_DIR)/out

$(COMPILE_DIR) $(OUTPUT_DIR):
	@mkdir -p $@
	@echo "$(TOOL_CHAIN)" > $(TEST_BUILD_DIR)/toolchain.txt

#=============================================================================
# Linker Base Addresses
#=============================================================================
LINKER_BASE_RO ?= $(CMSDK_CM0_RO_BASE)
LINKER_BASE_RW ?= $(CMSDK_CM0_RW_BASE)

#=============================================================================
# Include Paths
#=============================================================================
ALL_INCLUDES := -I $(DEVICE_DIR)/Include -I $(CORE_DIR) $(USER_DEFINE)
ALL_INCLUDES += -I $(FIRMWARE_CONFIG_DIR)

ifeq ($(USE_RETARGET),1)
  ALL_INCLUDES += -I $(SOFTWARE_DIR)/common/retarget
endif

ifeq ($(USE_GENERIC),1)
  ALL_INCLUDES += -I $(TEST_DIR)/../generic
endif

ALL_INCLUDES += $(EXTRA_INCLUDES)

#=============================================================================
# System clock (flows/fw_clk.mk has the whole story)
#
# SYS_CLK_FREQ_HZ set: NANOSOC_SYS_CLK_FREQ_HZ is defined on the command line,
# for the application and the boot ROM alike, and the generated
# nanosoc_memmap.h (#ifndef-wrapped by nanosoc_gen) yields to it.
# Unset: nothing is added and the header's value is used, as before.
#
# check_fw_clk asks the preprocessor what NANOSOC_SYS_CLK_FREQ_HZ actually is
# with these flags and this header, and fails naming both numbers if it is not
# the requested clock. That catches the one way the override can be lost
# silently: a header generated before the #ifndef wrapper, whose later
# #define wins over -D with nothing but a "redefined" warning.
#=============================================================================
ifneq ($(strip $(SYS_CLK_FREQ_HZ)),)
  FW_CLK_VALUE  := $(strip $(SYS_CLK_FREQ_HZ))UL
  ALL_INCLUDES  += -DNANOSOC_SYS_CLK_FREQ_HZ=$(FW_CLK_VALUE)
  # A C preprocessor that accepts -E -P -x c -. The GCC driver for gcc builds;
  # the host's cpp otherwise (the header is plain #define/#ifndef).
  FW_CLK_CPP    ?= $(if $(filter gcc,$(TOOL_CHAIN)),$(CC_TOOL),cpp)
  FW_CLK_CHECK  := check_fw_clk
endif

.PHONY: check_fw_clk
check_fw_clk:
	@got=$$(printf '#include "nanosoc_memmap.h"\nFW_CLK=NANOSOC_SYS_CLK_FREQ_HZ\n' | \
	   $(FW_CLK_CPP) -E -P $(ALL_INCLUDES) -x c - 2>/dev/null | sed -n 's/^FW_CLK=//p'); \
	 if [ "$$got" != "$(FW_CLK_VALUE)" ]; then \
	   echo "ERROR: SYS_CLK_FREQ_HZ=$(SYS_CLK_FREQ_HZ) asks for NANOSOC_SYS_CLK_FREQ_HZ = $(FW_CLK_VALUE)," >&2; \
	   echo "       but this build would compile NANOSOC_SYS_CLK_FREQ_HZ = $${got:-<nothing: the preprocessor failed>}." >&2; \
	   echo "       $(FIRMWARE_CONFIG_DIR)/nanosoc_memmap.h defines it without #ifndef, so its value" >&2; \
	   echo "       replaces the -D. Regenerate build_soc/firmware with a nanosoc_gen that wraps it" >&2; \
	   echo "       (fix/firmware-clock or later), or unset SYS_CLK_FREQ_HZ." >&2; \
	   exit 1; \
	 fi

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

# Select the toolchain-specific extra flags based on TOOL_CHAIN.
ifeq ($(TOOL_CHAIN),ds6)
  _CC_EXTRA_TOOLCHAIN := $(CC_EXTRA_FLAGS_ARMCLANG)
else ifeq ($(TOOL_CHAIN),ds5)
  _CC_EXTRA_TOOLCHAIN := $(CC_EXTRA_FLAGS_ARMCC)
else
  _CC_EXTRA_TOOLCHAIN :=
endif
ARM_CC_OPTIONS := $(CC_TARGET) -c $(OPT_LEVEL) -g $(CC_EXTRA_FLAGS) $(_CC_EXTRA_TOOLCHAIN) $(ALL_INCLUDES)
ARM_ASM_OPTIONS := -g

ARM_LINK_OPTIONS := "--keep=$(STARTUP_FILE).o(RESET)" "--first=$(STARTUP_FILE).o(RESET)" \
		--rw_base $(LINKER_BASE_RW) --ro_base $(LINKER_BASE_RO) --map $(ARM_LINK_EXTRA)

# Driver compile options (without -g for size optimization)
DRIVER_CC_OPTIONS ?= $(CC_TARGET) -c $(OPT_LEVEL) $(CC_EXTRA_FLAGS) $(_CC_EXTRA_TOOLCHAIN) $(ALL_INCLUDES)

ifeq ($(COMPILE_BIGEND),1)
  ARM_CC_OPTIONS   += --bigend
  ARM_ASM_OPTIONS  += --bigend
  ARM_LINK_OPTIONS += --be8
endif

# C library flags (driven by NANOSOC_C_LIBRARY). Toolchain-specific flags
# come from build/libraries/<name>.mk via CLIB_*_ARMCLANG / CLIB_*_ARMCC.
ifeq ($(TOOL_CHAIN),ds6)
  ARM_CC_OPTIONS   += $(CLIB_CC_ARMCLANG)
  ARM_ASM_OPTIONS  += $(CLIB_ASM_ARMCLANG)
  ARM_LINK_OPTIONS += $(CLIB_LINK_ARMCLANG)
endif
ifeq ($(TOOL_CHAIN),ds5)
  ARM_CC_OPTIONS   += $(CLIB_CC_ARMCC)
  ARM_ASM_OPTIONS  += $(CLIB_ASM_ARMCC)
  ARM_LINK_OPTIONS += $(CLIB_LINK_ARMCC)
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

# CPU_TYPE is set by the toolchain .mk from CPU_FLAGS_GCC (which already
# includes -mthumb for GCC), so no explicit -mthumb here.
GNU_CC_FLAGS := -g $(OPT_LEVEL) $(CPU_TYPE) $(GCC_SPEC_OPTS) $(GNU_CC_EXTRA_FLAGS)

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
all_ds5 : $(FW_CLK_CHECK) $(OUTPUT_DIR)/$(TESTNAME).hex $(OUTPUT_DIR)/$(TESTNAME).lst
all_ds6 : $(FW_CLK_CHECK) $(OUTPUT_DIR)/$(TESTNAME).hex $(OUTPUT_DIR)/$(TESTNAME).lst

ifneq ($(TOOL_CHAIN),gcc)

# Full paths for compile objects
COMPILE_OBJECTS_FULL := $(addprefix $(COMPILE_DIR)/,$(COMPILE_OBJECTS))

# Pattern rule for C sources
$(COMPILE_DIR)/%.o: %.c $(DEPS_LIST) | $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS) $(CPU_TYPE) $< -o $@

# Static pattern rule for driver files (different flags)
ifneq ($(DRIVER_OBJECTS),)
$(addprefix $(COMPILE_DIR)/,$(DRIVER_OBJECTS)): $(COMPILE_DIR)/%.o: %.c $(DEPS_LIST) | $(COMPILE_DIR)
	$(CC_TOOL) $(DRIVER_CC_OPTIONS) $(CPU_TYPE) $< -o $@
endif

# Pattern rule for assembly sources
$(COMPILE_DIR)/%.o: %.s $(DEPS_LIST) | $(COMPILE_DIR)
	$(ASM_TOOL) $(ARM_ASM_OPTIONS) $(CPU_TYPE) $< -o $@

# Link
$(COMPILE_DIR)/$(TESTNAME).ELF : $(COMPILE_OBJECTS_FULL)
	$(LINK_TOOL) $(ARM_LINK_OPTIONS) -o $@ $(COMPILE_OBJECTS_FULL)

# Generate Verilog hex
$(OUTPUT_DIR)/$(TESTNAME).hex : $(COMPILE_DIR)/$(TESTNAME).ELF | $(OUTPUT_DIR)
	$(HEX_CMD)

# Generate binary
$(OUTPUT_DIR)/$(TESTNAME).bin : $(COMPILE_DIR)/$(TESTNAME).ELF | $(OUTPUT_DIR)
	$(BIN_CMD)

# Generate listing
$(OUTPUT_DIR)/$(TESTNAME).lst : $(COMPILE_DIR)/$(TESTNAME).ELF | $(OUTPUT_DIR)
	$(LST_CMD)

endif # ifneq gcc

# ---------------------------------------------------------------------------------------
# GCC Build
# ---------------------------------------------------------------------------------------
ifeq ($(TOOL_CHAIN),gcc)

# STACK_SIZE/HEAP_SIZE are overridable from the parent makefile. They
# control the .stack_dummy and .heap section sizes in the startup file.
# Note: -x assembler-with-cpp is required so the CMSIS startup file's
# #ifdef __HEAP_SIZE directive actually gets preprocessed (GCC does not
# preprocess lowercase .s files by default).
STACK_SIZE ?= 0x200
HEAP_SIZE  ?= 0x1000

all_gcc: $(FW_CLK_CHECK) | $(COMPILE_DIR) $(OUTPUT_DIR)
	$(CC_TOOL) $(GNU_CC_FLAGS) \
		-x assembler-with-cpp $(filter %.s,$(GCC_ALL_SOURCES)) \
		-x none $(filter-out %.s,$(GCC_ALL_SOURCES)) \
		$(ALL_INCLUDES) \
		$(FIRMWARE_LINKER_SEARCH) \
		-D__STACK_SIZE=$(STACK_SIZE) \
		-D__HEAP_SIZE=$(HEAP_SIZE) \
		-T $(LINKER_SCRIPT) -o $(COMPILE_DIR)/$(TESTNAME).o
	# Generate disassembly code
	$(GNU_OBJDUMP) -S $(COMPILE_DIR)/$(TESTNAME).o > $(OUTPUT_DIR)/$(TESTNAME).lst
	# Generate binary file
	$(GNU_OBJCOPY) -S $(COMPILE_DIR)/$(TESTNAME).o -O binary $(OUTPUT_DIR)/$(TESTNAME).bin
	# Generate hex file
	$(GNU_OBJCOPY) -S $(COMPILE_DIR)/$(TESTNAME).o $(OBJCOPY_EXTRA) -O verilog $(OUTPUT_DIR)/$(TESTNAME).hex

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
all_bin: $(OUTPUT_DIR)/$(TESTNAME).bin
	od -v -A n -t x1 --width=1 $(OUTPUT_DIR)/$(TESTNAME).bin > $(OUTPUT_DIR)/$(TESTNAME).hex

# ---------------------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------------------
clean :
	@rm -rf $(TEST_BUILD_DIR)
