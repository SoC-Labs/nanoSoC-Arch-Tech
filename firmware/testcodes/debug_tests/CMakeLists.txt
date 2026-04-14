nanosoc_add_test(debug_tests
    SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/debug_tests"
    SOURCES
        "${NanoSoC_TESTCODES_GENERIC_DIR}/mcu_debugtester_interface.c"
        "${NanoSoC_CMSDK_DRIVER_C}"
    INCLUDES "${NanoSoC_DEBUG_TESTER_DIR}"
    USE_GENERIC
)
