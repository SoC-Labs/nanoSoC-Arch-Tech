#-----------------------------------------------------------------------------
# NanoSoC Firmware - ARM Compiler 6 (armclang/armlink) CMake Toolchain File
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Equivalent to firmware/build/toolchain/ds6.mk in the Make flow.
#
# NOTE: armclang was not on PATH during Phase 0 spike authoring. This file is
# drafted against ds6.mk and CMake documentation; validate in Phase 0b when
# armclang becomes available. Expected CMake version: 3.15+ for native AC6
# support.
#-----------------------------------------------------------------------------

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   armclang)
set(CMAKE_ASM_COMPILER armclang)
set(CMAKE_C_COMPILER_TARGET   arm-arm-none-eabi)
set(CMAKE_ASM_COMPILER_TARGET arm-arm-none-eabi)
set(CMAKE_LINKER       armlink CACHE FILEPATH "armlink")

# Locate fromelf for hex/bin/lst post-processing (see ds6.mk:32-34).
find_program(NANOSOC_FROMELF fromelf DOC "ARM fromelf image converter")
if(NOT NANOSOC_FROMELF)
    message(FATAL_ERROR "fromelf not found — required for armclang post-build. Install ARM Compiler 6.")
endif()

set(CMAKE_C_COMPILER_WORKS   TRUE)
set(CMAKE_ASM_COMPILER_WORKS TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# armlink is driven directly (not via armclang). This matches testcode.mk:246
# which invokes $(LINK_TOOL) = armlink. See ds6.mk:16.
set(CMAKE_C_LINK_EXECUTABLE
    "<CMAKE_LINKER> <LINK_FLAGS> <OBJECTS> -o <TARGET>"
    CACHE STRING "" FORCE)

# Assembly via armclang -masm=armasm — matches ds6.mk:15.
set(CMAKE_ASM_FLAGS_INIT "-masm=armasm --target=arm-arm-none-eabi -c")

set(NANOSOC_TOOLCHAIN_ID "armclang" CACHE INTERNAL "NanoSoC toolchain identifier")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "" FORCE)
endif()
# Per-target optimisation driven by nanosoc_add_test(... OPT_LEVEL ...).
# Also strip CMake's -DNDEBUG from MinSizeRel (Make doesn't add it).
set(CMAKE_C_FLAGS_MINSIZEREL     "-g"     CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_RELEASE        "-g"     CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_RELWITHDEBINFO "-g"     CACHE STRING "" FORCE)
set(CMAKE_C_FLAGS_DEBUG          "-O0 -g" CACHE STRING "" FORCE)
