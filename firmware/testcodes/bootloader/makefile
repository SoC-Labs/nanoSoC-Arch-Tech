#-----------------------------------------------------------------------------
# NanoSoC Bootloader Build
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Flynn (d.w.flynn@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
TESTNAME       := bootloader
SOURCE_DIR      = $(SOFTWARE_DIR)/common/bootloader
LINKER_NAME    := cmsdk_bootloader
LINKER_BASE_RO  = $(CMSDK_BOOTLOADER_RO_BASE)
LINKER_BASE_RW  = $(CMSDK_BOOTLOADER_RW_BASE)
OPT_LEVEL      := -O1
USE_RETARGET   := 0
GNU_CC_EXTRA_FLAGS := -Os -flto -mthumb-interwork

include $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/testcode.mk

# DS-6 requires --no_scatterload_enabled for bootloader linking
ifeq ($(TOOL_CHAIN),ds6)
  ARM_LINK_OPTIONS += --no_scatterload_enabled
endif
