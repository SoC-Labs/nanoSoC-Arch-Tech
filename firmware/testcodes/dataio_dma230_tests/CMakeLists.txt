nanosoc_add_test(dataio_dma230_tests
    SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/dataio_functions.c"
    DRIVERS "${NanoSoC_DRIVERS_DIR}/dma_pl230_driver.c"
    CC_FLAGS_ARMCLANG -Ospace
)
