#-----------------------------------------------------------------------------
# NanoSoC Test: debug_tests
# Debug infrastructure tests
#-----------------------------------------------------------------------------
TESTNAME        := debug_tests
SOURCE_DIR       = $(SOFTWARE_DIR)/common/debug_tests
USE_GENERIC     := 1
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/debug_tester
SOURCE_FILES    += $(TEST_DIR)/../generic/mcu_debugtester_interface.c
SOURCE_FILES    += $(DEVICE_DIR)/Source/CMSDK_driver.c

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
