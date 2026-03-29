#-----------------------------------------------------------------------------
# NanoSoC Test: dataio_dma230_tests
# Data I/O with DMA-230 tests
#-----------------------------------------------------------------------------
TESTNAME        := dataio_dma230_tests
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/drivers
SOURCE_FILES    += $(TEST_DIR)/dataio_functions.c
DRIVER_FILES    += $(SOFTWARE_DIR)/drivers/dma_pl230_driver.c
CC_EXTRA_FLAGS  := -Ospace

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
