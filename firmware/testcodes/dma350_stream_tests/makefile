#-----------------------------------------------------------------------------
# NanoSoC Test: dma350_stream_tests
# DMA-350 streaming mode validation tests
#-----------------------------------------------------------------------------
TESTNAME        := dma350_stream_tests
SOURCE_DIR       = $(SOFTWARE_DIR)/common/validation
USE_GENERIC     := 1
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/drivers
DRIVER_FILES    += $(SOFTWARE_DIR)/drivers/dma_350_command_lib.c
CC_EXTRA_FLAGS  := --c99

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
