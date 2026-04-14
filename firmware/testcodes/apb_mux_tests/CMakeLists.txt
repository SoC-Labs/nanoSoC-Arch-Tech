nanosoc_add_test(apb_mux_tests
    SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/validation"
    CC_FLAGS_GCC -flto
)
