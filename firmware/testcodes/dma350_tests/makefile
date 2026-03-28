#-----------------------------------------------------------------------------
# NanoSoC Test: dma350_tests
# DMA-350 controller validation tests
#-----------------------------------------------------------------------------
TESTNAME        := dma350_tests
SOURCE_DIR       = $(SOFTWARE_DIR)/common/validation
USE_GENERIC     := 1
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/drivers
DRIVER_FILES    += $(SOFTWARE_DIR)/drivers/dma_350_command_lib.c
CC_EXTRA_FLAGS  := --c99

include $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/testcode.mk
