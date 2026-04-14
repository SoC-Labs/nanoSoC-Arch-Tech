#-----------------------------------------------------------------------------
# NanoSoC Test: dataio_tests
# Data I/O interface tests
#-----------------------------------------------------------------------------
TESTNAME        := dataio_tests
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/drivers
SOURCE_FILES    += $(TEST_DIR)/dataio_functions.c
# AC5 uses -Ospace (size opt); AC6 armclang uses -Os (clang-style).
CC_EXTRA_FLAGS_ARMCC    := -Ospace
CC_EXTRA_FLAGS_ARMCLANG := -Os

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
