#-----------------------------------------------------------------------------
# NanoSoC Test: dhry
# Dhrystone benchmark
#-----------------------------------------------------------------------------
TESTNAME           := dhry
SOURCE_DIR          = $(SOFTWARE_DIR)/common/dhry
MAIN_SOURCE         = $(SOURCE_DIR)/dhry_1.c
SOURCE_FILES       += $(SOURCE_DIR)/dhry_2.c
EXTRA_INCLUDES     += -I $(SOFTWARE_DIR)/common/dhry -DITERATIONS=200
CC_EXTRA_FLAGS     := -Ono_inline --no_inline --no_multifile -Oloopref
GNU_CC_EXTRA_FLAGS := -fno-inline -fno-common

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
