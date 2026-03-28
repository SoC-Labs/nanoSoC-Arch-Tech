#-----------------------------------------------------------------------------
# NanoSoC Test: romtable_tests
# CoreSight ROM table validation tests
#-----------------------------------------------------------------------------
TESTNAME        := romtable_tests
SOURCE_DIR       = $(SOFTWARE_DIR)/common/romtable_tests
USE_GENERIC     := 1
EXTRA_INCLUDES  += -I $(SOFTWARE_DIR)/debug_tester
SOURCE_FILES    += $(TEST_DIR)/../generic/mcu_debugtester_interface.c
SOURCE_FILES    += $(DEVICE_DIR)/Source/CMSDK_driver.c

include $(SOCLABS_NANOSOC_FIRMWARE_TECH_DIR)/build/testcode.mk
