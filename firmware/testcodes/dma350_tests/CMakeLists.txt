nanosoc_add_test(dma350_tests
    SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/validation"
    DRIVERS "${NanoSoC_DRIVERS_DIR}/dma_350_command_lib.c"
    USE_GENERIC
    # AC5 uses --c99; AC6 armclang uses -std=gnu99 (strict -std=c99 breaks
    # retarget.c's GNU struct extensions).
    CC_FLAGS_ARMCC    --c99
    CC_FLAGS_ARMCLANG -std=gnu99
)
