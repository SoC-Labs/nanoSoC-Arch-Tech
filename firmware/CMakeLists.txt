#-----------------------------------------------------------------------------
# NanoSoC Firmware - CMake top-level
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.21)
project(NanoSoCFirmware C ASM)

# --- User-facing cache options -----------------------------------------------
set(NANOSOC_CPU_VARIANT "CORTEX_M0" CACHE STRING
    "Cortex-M variant: CORTEX_M0 | CORTEX_M0PLUS")
set_property(CACHE NANOSOC_CPU_VARIANT PROPERTY STRINGS CORTEX_M0 CORTEX_M0PLUS)

option(NANOSOC_BIGEND       "Build firmware big-endian" OFF)
option(NANOSOC_USE_MICROLIB "Use ARM microlib (armclang only)" OFF)
option(NANOSOC_BUILD_TESTS  "Build testcode executables" ON)

# NanoSoC_FIRMWARE_CONFIG_DIR must be set by the consumer (either cache or
# CLI) before including nanosoc_memmap.cmake. Default to sibling project dir.
if(NOT DEFINED NanoSoC_FIRMWARE_CONFIG_DIR)
    set(NanoSoC_FIRMWARE_CONFIG_DIR ""
        CACHE PATH "Directory containing generated nanosoc_memmap.cmake/.h/.ld")
endif()

# --- Directory layout --------------------------------------------------------
set(_FW_ROOT      "${CMAKE_CURRENT_SOURCE_DIR}")
set(_SW_ROOT      "${_FW_ROOT}/software")
set(_CMSIS_ROOT   "${_SW_ROOT}/cmsis")
set(_CMSIS_CORE   "${_CMSIS_ROOT}/CMSIS/Include")
set(_DRIVERS_ROOT "${_SW_ROOT}/drivers")
set(_RETARGET    "${_SW_ROOT}/common/retarget")

if(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0PLUS")
    set(_DEVICE_DIR   "${_CMSIS_ROOT}/Device/ARM/CMSDK_CM0plus")
    set(_STARTUP_STEM "startup_CMSDK_CM0plus")
    set(_SYSTEM_STEM  "system_CMSDK_CM0plus")
else()
    set(_DEVICE_DIR   "${_CMSIS_ROOT}/Device/ARM/CMSDK_CM0")
    set(_STARTUP_STEM "startup_CMSDK_CM0")
    set(_SYSTEM_STEM  "system_CMSDK_CM0")
endif()

if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
    set(_STARTUP_SUBDIR "GCC")
else()
    set(_STARTUP_SUBDIR "ARM")
endif()

set(NanoSoC_LINKER_SCRIPT_DIR "${_SW_ROOT}/common/scripts" CACHE INTERNAL "")

# --- Common compile flags (matches testcode.mk GCC path) ---------------------
set(_common_cpu_flags -mthumb)
if(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0PLUS")
    list(APPEND _common_cpu_flags -mcpu=cortex-m0plus)
else()
    list(APPEND _common_cpu_flags -mcpu=cortex-m0)
endif()
if(NANOSOC_BIGEND)
    list(APPEND _common_cpu_flags -mbig-endian)
endif()

# ============================================================================
# Target: NanoSoCFirmware::cmsis - CMSIS + device headers, CPU define
# ============================================================================
add_library(nanosoc_cmsis INTERFACE)
add_library(NanoSoCFirmware::cmsis ALIAS nanosoc_cmsis)

target_include_directories(nanosoc_cmsis INTERFACE
    "${_DEVICE_DIR}/Include"
    "${_CMSIS_CORE}")
target_compile_definitions(nanosoc_cmsis INTERFACE -D${NANOSOC_CPU_VARIANT})

if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
    target_compile_options(nanosoc_cmsis INTERFACE ${_common_cpu_flags})
elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armclang")
    # ds6.mk:25 — armclang/armasm CPU flag uses capital "Cortex-M0".
    if(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0PLUS")
        set(_ac6_cpu "-mcpu=Cortex-M0plus")
    else()
        set(_ac6_cpu "-mcpu=Cortex-M0")
    endif()
    target_compile_options(nanosoc_cmsis INTERFACE ${_ac6_cpu})
elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armcc")
    # ds5.mk-equivalent — armcc/armasm use --cpu Cortex-M0.
    if(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0PLUS")
        set(_ac5_cpu "--cpu" "Cortex-M0plus")
    else()
        set(_ac5_cpu "--cpu" "Cortex-M0")
    endif()
    target_compile_options(nanosoc_cmsis INTERFACE ${_ac5_cpu})
endif()

# ============================================================================
# Target: NanoSoCFirmware::memmap - generated memmap header include path
# ============================================================================
add_library(nanosoc_memmap INTERFACE)
add_library(NanoSoCFirmware::memmap ALIAS nanosoc_memmap)
if(NanoSoC_FIRMWARE_CONFIG_DIR)
    target_include_directories(nanosoc_memmap INTERFACE "${NanoSoC_FIRMWARE_CONFIG_DIR}")
endif()

# ============================================================================
# Source-list exports (NOT libraries)
#
# Bit-equality with the Make build requires source files to appear in the
# executable in the exact order the testcode.mk gcc rule passes them:
#     startup.s  testname.c  system.c  retarget.c  uart_stdout.c  drivers...
#
# CMake's OBJECT-library link-time ordering doesn't preserve this. We work
# around by injecting source paths directly into add_executable() inside
# nanosoc_add_test, in the canonical order.
# ============================================================================
set(NanoSoC_STARTUP_ASM
    "${_DEVICE_DIR}/Source/${_STARTUP_SUBDIR}/${_STARTUP_STEM}.s"
    CACHE INTERNAL "")
set(NanoSoC_SYSTEM_C
    "${_DEVICE_DIR}/Source/${_SYSTEM_STEM}.c"
    CACHE INTERNAL "")
set(NanoSoC_RETARGET_SOURCES
    "${_RETARGET}/retarget.c"
    "${_RETARGET}/uart_stdout.c"
    CACHE INTERNAL "")

# ============================================================================
# NanoSoCFirmware::retarget - INTERFACE target carrying retarget include path
# (sources are injected via NanoSoC_RETARGET_SOURCES; this target only adds
# the include directory so consumers can find uart_stdout.h)
# ============================================================================
add_library(nanosoc_retarget INTERFACE)
add_library(NanoSoCFirmware::retarget ALIAS nanosoc_retarget)
target_include_directories(nanosoc_retarget INTERFACE "${_RETARGET}")
target_link_libraries(nanosoc_retarget INTERFACE nanosoc_memmap)

# ============================================================================
# Exported path helpers — for use inside testcode CMakeLists.txt SOURCES/INCLUDES
# ============================================================================
set(NanoSoC_SOFTWARE_DIR          "${_SW_ROOT}"                 CACHE INTERNAL "")
set(NanoSoC_SOFTWARE_COMMON_DIR   "${_SW_ROOT}/common"          CACHE INTERNAL "")
set(NanoSoC_DRIVERS_DIR           "${_DRIVERS_ROOT}"            CACHE INTERNAL "")
set(NanoSoC_DEBUG_TESTER_DIR      "${_SW_ROOT}/debug_tester"    CACHE INTERNAL "")
set(NanoSoC_TESTCODES_GENERIC_DIR "${_FW_ROOT}/testcodes/generic" CACHE INTERNAL "")
set(NanoSoC_CMSDK_DRIVER_C        "${_DEVICE_DIR}/Source/CMSDK_driver.c" CACHE INTERNAL "")

# ============================================================================
# Pull in the common helper function
# ============================================================================
include("${CMAKE_CURRENT_LIST_DIR}/cmake/NanoSoCFirmwareFunctions.cmake")

# ============================================================================
# Testcode subdirectories
# ============================================================================
if(NANOSOC_BUILD_TESTS)
    if(NOT NanoSoC_FIRMWARE_CONFIG_DIR)
        message(FATAL_ERROR
            "NanoSoC_FIRMWARE_CONFIG_DIR not set — required to build testcodes. "
            "Pass via -D on the command line or set in a CMakePresets.json entry.")
    endif()
    if(NOT EXISTS "${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake")
        message(FATAL_ERROR
            "nanosoc_memmap.cmake not found in ${NanoSoC_FIRMWARE_CONFIG_DIR}. "
            "Run the nanosoc_gen firmware backend (or hand-copy the spike version).")
    endif()
    include("${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake")

    # Read excluded_tests.txt (mirrors the Make flow's skip list).
    set(_excluded_tests "")
    if(EXISTS "${_FW_ROOT}/testcodes/excluded_tests.txt")
        file(STRINGS "${_FW_ROOT}/testcodes/excluded_tests.txt" _excluded_tests)
    endif()

    # Auto-discover every testcode with a CMakeLists.txt in testcodes/<dir>/.
    file(GLOB _test_candidates RELATIVE "${_FW_ROOT}/testcodes"
         "${_FW_ROOT}/testcodes/*")
    foreach(_entry IN LISTS _test_candidates)
        set(_cmakelists "${_FW_ROOT}/testcodes/${_entry}/CMakeLists.txt")
        if(NOT IS_DIRECTORY "${_FW_ROOT}/testcodes/${_entry}")
            continue()
        endif()
        if(NOT EXISTS "${_cmakelists}")
            continue()
        endif()
        if(_entry IN_LIST _excluded_tests)
            message(STATUS "NanoSoC: skipping excluded test '${_entry}'")
            continue()
        endif()
        add_subdirectory("testcodes/${_entry}")
    endforeach()
endif()
