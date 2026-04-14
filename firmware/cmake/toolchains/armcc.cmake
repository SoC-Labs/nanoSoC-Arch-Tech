#-----------------------------------------------------------------------------
# NanoSoC Firmware - ARM Compiler 5 (armcc/armlink) CMake Toolchain File
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# WARNING: AC5 cannot currently build this codebase regardless of build system.
# CMSDK_CM0.h uses __has_include (C2x / GNU extension) which AC5 does not
# support. The Make `all_ds5` path also fails for the same reason. This file
# exists to validate CMake's armcc toolchain wiring; productive use requires
# either header changes or AC5 deprecation (recommended).
#
# Equivalent to firmware/build/toolchain/ds5.mk in the Make flow.
#-----------------------------------------------------------------------------

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   armcc)
set(CMAKE_ASM_COMPILER armasm)
set(CMAKE_LINKER       armlink CACHE FILEPATH "armlink")

find_program(NANOSOC_FROMELF fromelf DOC "ARM fromelf image converter")

set(CMAKE_C_COMPILER_WORKS   TRUE)
set(CMAKE_ASM_COMPILER_WORKS TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# CMake's built-in Modules/Compiler/ARMCC.cmake supports armcc since 3.7.
# It sets up:
#   - CMAKE_C_COMPILE_OBJECT  : armcc -c -o <obj> <src>
#   - CMAKE_C_LINK_EXECUTABLE : armlink -o <target> <objs>
# We override the link rule so it matches testcode.mk (no driver indirection).
set(CMAKE_C_LINK_EXECUTABLE
    "<CMAKE_LINKER> <LINK_FLAGS> <OBJECTS> -o <TARGET>"
    CACHE STRING "" FORCE)

set(NANOSOC_TOOLCHAIN_ID "armcc" CACHE INTERNAL "NanoSoC toolchain identifier")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "" FORCE)
endif()
