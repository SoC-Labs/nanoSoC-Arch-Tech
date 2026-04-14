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

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk

# Note: an old DS-5 era flag --no_scatterload_enabled was previously appended
# here for ds6 builds. AC6.16 armlink does not recognise that option (returns
# fatal L3900U). The flag served to suppress scatter-load helper insertion;
# with the explicit --rw_base / --ro_base used below, no scatter file is
# produced anyway, so the flag is unnecessary.
