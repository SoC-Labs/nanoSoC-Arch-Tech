#-----------------------------------------------------------------------------
# NanoSoC Test: spi_loopback (CMake)
# PL022 SSP internal (SSPCR1.LBM) + external (pin-jumper) loopback smoke.
#
# SPI_PL022_BASE tracks the generated memmap symbol (NANOSOC_SPI_BASE,
# 0x2800C000 for this SoC) instead of the driver's multicore-oriented
# fallbacks. SPI_PL022_POLL_TIMEOUT bounds the driver's blocking polls so
# a dead SSP reports a timeout on the UART instead of hanging the test.
#-----------------------------------------------------------------------------
nanosoc_add_test(spi_loopback
    DRIVERS "${NanoSoC_DRIVERS_DIR}/spi_pl022.c"
    DEFINES
        -DSPI_PL022_BASE=NANOSOC_SPI_BASE
        -DSPI_PL022_POLL_TIMEOUT=1000000u
)
