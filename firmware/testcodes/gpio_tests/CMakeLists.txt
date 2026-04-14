#-----------------------------------------------------------------------------
# NanoSoC Test: gpio_tests (CMake)
# Mirrors firmware/testcodes/gpio_tests/makefile (SOURCE_DIR override)
#-----------------------------------------------------------------------------
nanosoc_add_test(gpio_tests SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/validation")
