nanosoc_add_test(dhry
    MAIN_SOURCE "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry/dhry_1.c"
    SOURCES "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry/dhry_2.c"
    INCLUDES "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry"
    DEFINES -DITERATIONS=200
    CC_FLAGS_ARMCLANG -Ono_inline --no_inline --no_multifile -Oloopref
    CC_FLAGS_GCC -fno-inline -fno-common
)
