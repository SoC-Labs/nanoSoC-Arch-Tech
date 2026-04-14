nanosoc_add_test(dhry
    MAIN_SOURCE "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry/dhry_1.c"
    SOURCES "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry/dhry_2.c"
    INCLUDES "${NanoSoC_SOFTWARE_COMMON_DIR}/dhry"
    DEFINES -DITERATIONS=200
    # AC5 has armcc-specific no-inline / no-multifile / loopref options.
    # AC6 armclang is clang-based; use gcc-style -fno-inline instead.
    # GCC uses -fno-inline -fno-common.
    CC_FLAGS_ARMCC -Ono_inline --no_inline --no_multifile -Oloopref
    CC_FLAGS_ARMCLANG -fno-inline
    CC_FLAGS_GCC -fno-inline -fno-common
)
