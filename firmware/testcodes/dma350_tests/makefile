#-----------------------------------------------------------------------------
# NanoSoC Test: dma350_tests
# DMA-350 controller validation tests
#-----------------------------------------------------------------------------
TESTNAME        := dma350_tests
SOURCE_DIR       = $(SOFTWARE_DIR)/common/validation
USE_GENERIC     := 1
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/drivers
DRIVER_FILES    += $(SOFTWARE_DIR)/drivers/dma_350_command_lib.c
# AC6 uses -std=gnu99 (not -std=c99) because retarget.c uses GNU struct
# extensions that strict C99 rejects. gnu99 keeps the C99 features dma350
# needs while allowing those extensions.
CC_EXTRA_FLAGS_ARMCC    := --c99
CC_EXTRA_FLAGS_ARMCLANG := -std=gnu99

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
