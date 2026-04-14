nanosoc_add_test(dataio_tests
    SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/dataio_functions.c"
    INCLUDES "${NanoSoC_DRIVERS_DIR}"
    CC_FLAGS_ARMCC    -Ospace       # AC5 size-opt spelling
    CC_FLAGS_ARMCLANG -Os           # AC6 (clang-style) equivalent
)
