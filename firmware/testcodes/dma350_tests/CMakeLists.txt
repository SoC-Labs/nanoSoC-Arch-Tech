nanosoc_add_test(dma350_tests
    SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/validation"
    DRIVERS "${NanoSoC_DRIVERS_DIR}/dma_350_command_lib.c"
    USE_GENERIC
    CC_FLAGS_ARMCLANG --c99
)
