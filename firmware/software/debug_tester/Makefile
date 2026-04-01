#-----------------------------------------------------------------------------
# The confidential and proprietary information contained in this file may
# only be used by a person authorised under and to the extent permitted
# by a subsisting licensing agreement from Arm Limited or its affiliates.
#
#            (C) COPYRIGHT 2010-2013 Arm Limited or its affiliates.
#                ALL RIGHTS RESERVED
#
# This entire notice must be reproduced on all copies of this file
# and copies of this file may only be made by a person if such person is
# permitted to do so under the terms of a subsisting license agreement
# from Arm Limited or its affiliates.
#
#      SVN Information
#
#      Checked In          : $Date: 2017-10-10 15:55:38 +0100 (Tue, 10 Oct 2017) $
#
#      Revision            : $Revision: 371321 $
#
#      Release Information : Cortex-M System Design Kit-r1p1-00rel0
#-----------------------------------------------------------------------------
#
# CMSDK Debug Tester Makefile
#
#-----------------------------------------------------------------------------
# Remove any current implicit rules
.IMPLICIT	=

# Choose the core instantiated, can be
#  - CORTEX_M0
#  - CORTEX_M0PLUS
#  - CORTEX_M3
#  - CORTEX_M4
#  - CORTEX_M4F
#    Note: if CORTEX_M4F is used, make sure:
#     1. RTL is configured to enable FPU option (cmsdk_mcu_defs.v) and recompiled
#     2. __FPU_PRESENT variable in header file (e.g. CMSDK_CM4.h) is set to 1
CPU_PRODUCT  = CORTEX_M0

TARGET = arm-none-eabi
# Shared software directory
SOFTWARE_DIR = ../
CMSIS_DIR    = $(SOFTWARE_DIR)/cmsis
CORE_DIR     = $(CMSIS_DIR)/CMSIS/Include

# Generated firmware config (address variables, linker bases)
FIRMWARE_CONFIG_DIR ?= $(SOCLABS_PROJECT_DIR)/build/firmware_config
-include $(FIRMWARE_CONFIG_DIR)/nanosoc_memmap.mk

GCC_LINKER_SCRIPT_PATH = $(SOFTWARE_DIR)/common/scripts

ifeq ($(CPU_PRODUCT),CORTEX_M0_DS)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM0
  STARTUP_FILE = startup_CMSDK_CM0
  USER_DEFINE  = -DCORTEX_M0
  ifeq ($(TOOL_CHAIN),ds6)
    ARM_CPU_TYPE = -mcpu=Cortex-M0
  else
    ARM_CPU_TYPE = --cpu=Cortex-M0
  endif
  GCC_CPU_TYPE = -mcpu=cortex-m0
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif
ifeq ($(CPU_PRODUCT),CORTEX_M0)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM0
  STARTUP_FILE = startup_CMSDK_CM0
  USER_DEFINE  = -DCORTEX_M0
  ifeq ($(TOOL_CHAIN),ds6)
    ARM_CPU_TYPE = -mcpu=Cortex-M0
  else
    ARM_CPU_TYPE = --cpu=Cortex-M0
  endif
  GCC_CPU_TYPE = -mcpu=cortex-m0
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif
ifeq ($(CPU_PRODUCT),CORTEX_M0PLUS)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM0plus
  STARTUP_FILE = startup_CMSDK_CM0plus
  USER_DEFINE  = -DCORTEX_M0PLUS
  ARM_CPU_TYPE = --cpu=Cortex-M0plus
  GCC_CPU_TYPE = -mcpu=cortex-m0plus
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif
ifeq ($(CPU_PRODUCT),CORTEX_M3)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM3
  STARTUP_FILE = startup_CMSDK_CM3
  USER_DEFINE  = -DCORTEX_M3
  ARM_CPU_TYPE = --cpu=Cortex-M3
  GCC_CPU_TYPE = -mcpu=cortex-m3
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif
ifeq ($(CPU_PRODUCT),CORTEX_M4)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM4
  STARTUP_FILE = startup_CMSDK_CM4
  USER_DEFINE  = -DCORTEX_M4
  ARM_CPU_TYPE = --cpu=Cortex-M4
  GCC_CPU_TYPE = -mcpu=cortex-m4
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif
ifeq ($(CPU_PRODUCT),CORTEX_M4F)
  DEVICE_DIR   = $(CMSIS_DIR)/Device/ARM/CMSDK_CM4
  STARTUP_FILE = startup_CMSDK_CM4
  USER_DEFINE  = -DCORTEX_M4
  # The debug tester processor for M4F as the target is an M4, so the processor
  # for compiling the debug tester code must be M4
  ARM_CPU_TYPE = --cpu=Cortex-M4
  GCC_CPU_TYPE = -mcpu=cortex-m4
  GCC_LINKER_SCRIPT = $(GCC_LINKER_SCRIPT_PATH)/debugtester.ld
endif

# Program file
DEBUGTESTER       = debugtester

# Endian Option
COMPILE_BIGEND = 0

DEPS_LIST      = Makefile debugtester.h cmsdk_debugtester.h

# Tool chain : ds5 / gcc / keil
TOOL_CHAIN     = ds5

# ---------------------------------------------------------------------------------------
# DS-5 options
ifeq ($(TOOL_CHAIN),ds6)
  ARM_TARGET = --target=arm-$(TARGET)
  CC_TOOL   = armclang -O1
  ASM_TOOL = armclang -masm=armasm $(ARM_TARGET) -c
else
  CC_TOOL   = armcc -O3
  ASM_TOOL = armasm
  ARM_TARGET = -Otime
endif

# MicroLIB option (DS-5)
COMPILE_MICROLIB = 0

ARM_CC_OPTIONS   = $(ARM_TARGET) -c -g -I $(CORE_DIR) -I $(DEVICE_DIR)/Include \
		   -I $(SOFTWARE_DIR)/common/retarget $(USER_DEFINE)
ARM_ASM_OPTIONS  = -g

ARM_LINK_OPTIONS = "--keep=$(STARTUP_FILE).o(RESET)" "--first=$(STARTUP_FILE).o(RESET)" \
		--rw_base $(DEBUGTESTER_RW_BASE) --ro_base $(DEBUGTESTER_RO_BASE) --map

# Big Endian
ARM_CC_OPTIONS_BE = $(ARM_CC_OPTIONS) -DDEBUGTESTER_BE

ifeq ($(COMPILE_MICROLIB),1)
 # MicroLib
 ARM_CC_OPTIONS   += --library_type=microlib
 ARM_ASM_OPTIONS  += --library_type=microlib --pd "__MICROLIB SETA 1"
 ARM_LINK_OPTIONS += --library_type=microlib
endif

# ---------------------------------------------------------------------------------------
# gcc options

GNG_CC      = $(TARGET)-gcc
GNU_OBJDUMP = $(TARGET)-objdump
GNU_OBJCOPY = $(TARGET)-objcopy

# The optimisation level for the GCC compiler should be fixed at -01 or the results can
# cause unpredictable results for the debugtester behaviour.
GNU_CC_FLAGS = -g -O1 -mthumb $(GCC_CPU_TYPE)

# ---------------------------------------------------------------------------------------
all: all_$(TOOL_CHAIN)

SOFTWARE_BUILD_DIR := $(SOCLABS_PROJECT_DIR)/build/firmware
TEST_BUILD_DIR := $(SOFTWARE_BUILD_DIR)
COMPILE_DIR := $(TEST_BUILD_DIR)/$(DEBUGTESTER)/compile
OUTPUT_DIR := $(TEST_BUILD_DIR)/$(DEBUGTESTER)/out

DS5_TEST_BUILD_DIR := $(SOFTWARE_BUILD_DIR)/ds5
DS5_COMPILE_DIR := $(DS5_TEST_BUILD_DIR)/$(DEBUGTESTER)/compile
DS5_OUTPUT_DIR := $(DS5_TEST_BUILD_DIR)/$(DEBUGTESTER)/out

DS6_TEST_BUILD_DIR := $(SOFTWARE_BUILD_DIR)/ds6
DS6_COMPILE_DIR := $(DS6_TEST_BUILD_DIR)/$(DEBUGTESTER)/compile
DS6_OUTPUT_DIR := $(DS6_TEST_BUILD_DIR)/$(DEBUGTESTER)/out

GCC_TEST_BUILD_DIR := $(SOFTWARE_BUILD_DIR)/gcc
GCC_COMPILE_DIR := $(GCC_TEST_BUILD_DIR)/$(DEBUGTESTER)/compile
GCC_OUTPUT_DIR := $(GCC_TEST_BUILD_DIR)/$(DEBUGTESTER)/out

# Create output directory
$(OUTPUT_DIR) $(COMPILE_DIR):
	@mkdir -p $@

# ---------------------------------------------------------------------------------------
# DS-5
all_ds5 : $(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_le.hex $(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_be.hex $(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_le.lst $(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_be.lst
all_ds6 : $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_le.hex $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_be.hex $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_le.lst $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_be.lst

$(DS5_COMPILE_DIR)/debugtester_le.o $(DS6_COMPILE_DIR)/debugtester_le.o: debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS) $(ARM_CPU_TYPE) $< -o  $@

$(DS5_COMPILE_DIR)/system_cmsdk_debugtester_le.o $(DS6_COMPILE_DIR)/system_cmsdk_debugtester_le.o: system_cmsdk_debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS) $(ARM_CPU_TYPE) $< -o  $@

$(DS5_COMPILE_DIR)/retarget_cmsdk_debugtester_le.o $(DS6_COMPILE_DIR)/retarget_cmsdk_debugtester_le.o: retarget_cmsdk_debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS) $(ARM_CPU_TYPE) $< -o  $@

$(DS5_COMPILE_DIR)/$(STARTUP_FILE).o $(DS6_COMPILE_DIR)/$(STARTUP_FILE).o : $(DEVICE_DIR)/Source/ARM/$(STARTUP_FILE).s $(DEPS_LIST) $(COMPILE_DIR)
	$(ASM_TOOL) $(ARM_ASM_OPTIONS) $(ARM_CPU_TYPE) $< -o  $@

$(DS5_COMPILE_DIR)/$(DEBUGTESTER)_le.elf $(DS6_COMPILE_DIR)/$(DEBUGTESTER)_le.elf : $(COMPILE_DIR)/$(DEBUGTESTER)_le.o $(COMPILE_DIR)/$(STARTUP_FILE).o $(COMPILE_DIR)/system_cmsdk_debugtester_le.o $(COMPILE_DIR)/retarget_cmsdk_debugtester_le.o
	armlink $(ARM_LINK_OPTIONS) $(COMPILE_DIR)/$(DEBUGTESTER)_le.o $(COMPILE_DIR)/$(STARTUP_FILE).o $(COMPILE_DIR)/system_cmsdk_debugtester_le.o $(COMPILE_DIR)/retarget_cmsdk_debugtester_le.o -o $@
	
$(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_le.hex $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_le.hex : $(COMPILE_DIR)/$(DEBUGTESTER)_le.elf $(OUTPUT_DIR)
	fromelf --vhx --8x1 $< --output $@

$(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_le.lst $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_le.lst : $(COMPILE_DIR)/$(DEBUGTESTER)_le.elf $(OUTPUT_DIR)
	fromelf -c -d -e -s $< --output $@

$(COMPILE_DIR)/debugtester_be.o : debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS_BE) $(ARM_CPU_TYPE) $< -o  $@

$(COMPILE_DIR)/system_cmsdk_debugtester_be.o : system_cmsdk_debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS_BE) $(ARM_CPU_TYPE) $< -o  $@

$(COMPILE_DIR)/retarget_cmsdk_debugtester_be.o : retarget_cmsdk_debugtester.c $(DEPS_LIST) $(COMPILE_DIR)
	$(CC_TOOL) $(ARM_CC_OPTIONS_BE) $(ARM_CPU_TYPE) $< -o  $@

$(COMPILE_DIR)/$(DEBUGTESTER)_be.elf : $(COMPILE_DIR)/$(DEBUGTESTER)_be.o $(COMPILE_DIR)/$(STARTUP_FILE).o $(COMPILE_DIR)/system_cmsdk_debugtester_be.o $(COMPILE_DIR)/retarget_cmsdk_debugtester_be.o
	armlink $(ARM_LINK_OPTIONS) $(COMPILE_DIR)/$(DEBUGTESTER)_be.o $(COMPILE_DIR)/$(STARTUP_FILE).o $(COMPILE_DIR)/system_cmsdk_debugtester_be.o $(COMPILE_DIR)/retarget_cmsdk_debugtester_be.o -o $@

$(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_be.hex $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_be.hex : $(COMPILE_DIR)/$(DEBUGTESTER)_be.elf $(OUTPUT_DIR)
	fromelf --vhx --8x1 $< --output $@

$(DS5_OUTPUT_DIR)/$(DEBUGTESTER)_be.lst $(DS6_OUTPUT_DIR)/$(DEBUGTESTER)_be.lst : $(COMPILE_DIR)/$(DEBUGTESTER)_be.elf $(OUTPUT_DIR)
	fromelf -c -d -e -s $< --output $@

# ---------------------------------------------------------------------------------------
# GCC
all_gcc : $(OUTPUT_DIR)/$(DEBUGTESTER)_le.hex $(OUTPUT_DIR)/$(DEBUGTESTER)_be.hex

$(GCC_COMPILE_DIR)/$(DEBUGTESTER)_le.o : $(OUTPUT_DIR) $(COMPILE_DIR)
	$(GNG_CC) $(GNU_CC_FLAGS) $(DEVICE_DIR)/Source/GCC/$(STARTUP_FILE).s \
		$(DEBUGTESTER).c \
		system_cmsdk_debugtester.c \
		retarget_cmsdk_debugtester.c \
		-I $(DEVICE_DIR)/Include -I $(CORE_DIR) \
		-L $(GCC_LINKER_SCRIPT_PATH) -L $(FIRMWARE_CONFIG_DIR) \
		-D__STACK_SIZE=0x200 \
		-D__HEAP_SIZE=0x1000 \
		$(USER_DEFINE) -T $(GCC_LINKER_SCRIPT) -o $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_le.lst : $(COMPILE_DIR)/$(DEBUGTESTER)_le.o
	$(GNU_OBJDUMP) -S $< > $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_le.bin : $(COMPILE_DIR)/$(DEBUGTESTER)_le.o
	$(GNU_OBJCOPY) -S $< -O binary $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_le.hex : $(OUTPUT_DIR)/$(DEBUGTESTER)_le.bin
	$(GNU_OBJCOPY) -S $(GCC_COMPILE_DIR)/$(DEBUGTESTER)_le.o -O verilog $@

$(GCC_COMPILE_DIR)/$(DEBUGTESTER)_be.o : $(COMPILE_DIR)
	$(GNG_CC) $(GNU_CC_FLAGS) $(DEVICE_DIR)/Source/GCC/$(STARTUP_FILE).s \
		$(DEBUGTESTER).c \
		system_cmsdk_debugtester.c \
		retarget_cmsdk_debugtester.c \
		-I $(DEVICE_DIR)/Include -I $(CORE_DIR) \
		-L $(GCC_LINKER_SCRIPT_PATH) -L $(FIRMWARE_CONFIG_DIR) \
		-D__STACK_SIZE=0x200 \
		-D__HEAP_SIZE=0x1000 \
		$(USER_DEFINE) -DDEBUGTESTER_BE -T $(GCC_LINKER_SCRIPT) -o $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_be.lst : $(COMPILE_DIR)/$(DEBUGTESTER)_be.o $(OUTPUT_DIR)
	$(GNU_OBJDUMP) -S $< > $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_be.bin : $(COMPILE_DIR)/$(DEBUGTESTER)_be.o $(OUTPUT_DIR)
	$(GNU_OBJCOPY) -S $< -O binary $@

$(GCC_OUTPUT_DIR)/$(DEBUGTESTER)_be.hex : $(OUTPUT_DIR)/$(DEBUGTESTER)_be.bin $(OUTPUT_DIR)
	$(GNU_OBJCOPY) -S $(COMPILE_DIR)/$(DEBUGTESTER)_be.o -O verilog $@
# Note:
# If the version of object copy you are using does not support verilog hex file output,
# you can generate the hex file from binary file using the following command
#       od -v -A n -t x1 --width=1  $(DEBUGTESTER)_le.bin > $(DEBUGTESTER)_le.hex

# ---------------------------------------------------------------------------------------
# Keil MDK

all_keil:
	@echo "Please compile your project code and press ENTER when ready"
	@read dummy

# ---------------------------------------------------------------------------------------
# Binary

all_bin: $(OUTPUT_DIR)/$(DEBUGTESTER)_le.bin
	# Generate hex file from binary
	od -v -A n -t x1 --width=1  $(OUTPUT_DIR)/$(DEBUGTESTER)_le.bin > $(OUTPUT_DIR)/$(DEBUGTESTER)_le.hex


# ---------------------------------------------------------------------------------------
# Clean
clean:
	@rm -f *.hex *.bin *.elf *.o *.lst
	@rm -rf *.crf
	@rm -rf *.plg
	@rm -rf *.tra
	@rm -rf *.htm
	@rm -rf *.map
	@rm -rf *.dep
	@rm -rf *.d
	@rm -rf *.lnp
	@rm -rf *.bak
	@rm -rf *.lst
	@rm -rf *.axf
	@rm -rf *.__i
	@rm -rf *._ia
