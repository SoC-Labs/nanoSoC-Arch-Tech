#-----------------------------------------------------------------------------
# NanoSoC Firmware - GCC (arm-none-eabi) CMake Toolchain File
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Equivalent to firmware/build/toolchain/gcc.mk in the Make flow.
#
# Produces bit-identical output to Make builds when the same optimisation
# level, CPU variant, and endianness are selected.
#-----------------------------------------------------------------------------

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

# arm-none-eabi-* — expected on PATH. Optionally pin via NANOSOC_GCC_PREFIX.
if(NOT DEFINED NANOSOC_GCC_PREFIX)
    set(NANOSOC_GCC_PREFIX "arm-none-eabi-")
endif()

set(CMAKE_C_COMPILER   ${NANOSOC_GCC_PREFIX}gcc)
set(CMAKE_ASM_COMPILER ${NANOSOC_GCC_PREFIX}gcc)
set(CMAKE_OBJCOPY      ${NANOSOC_GCC_PREFIX}objcopy CACHE FILEPATH "objcopy")
set(CMAKE_OBJDUMP      ${NANOSOC_GCC_PREFIX}objdump CACHE FILEPATH "objdump")

# Skip compiler identification link test — targets a bare-metal MCU.
set(CMAKE_C_COMPILER_WORKS   TRUE)
set(CMAKE_ASM_COMPILER_WORKS TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Exported so NanoSoCFirmwareFunctions.cmake knows which post-build strategy
# to pick (GCC: objcopy/objdump; ARMClang: fromelf).
set(NANOSOC_TOOLCHAIN_ID "gcc" CACHE INTERNAL "NanoSoC toolchain identifier")

# Per-target optimisation is driven by nanosoc_add_test(... OPT_LEVEL ...)
# which maps to testcode.mk's OPT_LEVEL. These baselines only add -g; adding
# -O here would affect LTO partitioning for targets that override (-O1/Os).
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "" FORCE)
endif()
set(CMAKE_C_FLAGS_RELEASE        "-g"     CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_MINSIZEREL     "-g"     CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_DEBUG          "-O0 -g" CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_RELWITHDEBINFO "-g"     CACHE STRING "" FORCE)
