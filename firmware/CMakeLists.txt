#-----------------------------------------------------------------------------
# NanoSoC Firmware - CMake top-level
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.21)
project(NanoSoCFirmware C ASM)

# --- User-facing cache options -----------------------------------------------
# Target CPU is selected by name; each name maps to a description file under
# cmake/cpus/<name>.cmake (single source of truth for CPU-specific knobs).
#
# Resolution order (first non-empty wins):
#   1. -DNANOSOC_CPU=<name> on the cmake command line / preset cacheVariables
#   2. NanoSoC_DEFAULT_CPU from the generated <project>_memmap.cmake
#      (set by nanosoc_gen from the YAML's `firmware: { cpu: ... }` field)
#   3. Hard-coded fallback "cortex-m0" (with a status message)
set(NANOSOC_CPU "" CACHE STRING
    "Target CPU (cmake/cpus/<name>.cmake); empty = inherit NanoSoC_DEFAULT_CPU from generated memmap")

# Auto-populate the dropdown from available description files.
file(GLOB _cpu_files RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/cmake/cpus"
     "${CMAKE_CURRENT_SOURCE_DIR}/cmake/cpus/*.cmake")
set(_cpu_names "")
foreach(_f IN LISTS _cpu_files)
    string(REGEX REPLACE "\\.cmake$" "" _n "${_f}")
    list(APPEND _cpu_names "${_n}")
endforeach()
set_property(CACHE NANOSOC_CPU PROPERTY STRINGS ${_cpu_names})

option(NANOSOC_BIGEND       "Build firmware big-endian" OFF)
option(NANOSOC_BUILD_TESTS  "Build testcode executables" ON)

# C library variant — data-driven via cmake/libraries/<name>.cmake.
# Default is toolchain-dependent (gcc → nano, armclang/armcc → default).
# Override per-build here, or per-target via nanosoc_add_test(... C_LIBRARY ...).
set(NANOSOC_C_LIBRARY "" CACHE STRING
    "C library variant (cmake/libraries/<name>.cmake). Empty = toolchain default.")

# Backward-compat shim: NANOSOC_USE_MICROLIB=ON translates to NANOSOC_C_LIBRARY=microlib.
option(NANOSOC_USE_MICROLIB "Use ARM microlib (deprecated: prefer NANOSOC_C_LIBRARY=microlib)" OFF)
if(NANOSOC_USE_MICROLIB AND NOT NANOSOC_C_LIBRARY)
    set(NANOSOC_C_LIBRARY "microlib" CACHE STRING "" FORCE)
    message(DEPRECATION
        "NANOSOC_USE_MICROLIB is deprecated; use NANOSOC_C_LIBRARY=microlib instead.")
endif()

# Backward compatibility shim: accept the old NANOSOC_CPU_VARIANT cache var.
# Translate CORTEX_M0 → cortex-m0, CORTEX_M0PLUS → cortex-m0plus.
if(DEFINED NANOSOC_CPU_VARIANT AND NOT _NANOSOC_CPU_FROM_VARIANT)
    if(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0PLUS")
        set(NANOSOC_CPU "cortex-m0plus" CACHE STRING "" FORCE)
    elseif(NANOSOC_CPU_VARIANT STREQUAL "CORTEX_M0")
        set(NANOSOC_CPU "cortex-m0" CACHE STRING "" FORCE)
    endif()
    set(_NANOSOC_CPU_FROM_VARIANT 1 CACHE INTERNAL "")
    message(DEPRECATION
        "NANOSOC_CPU_VARIANT is deprecated; use NANOSOC_CPU=${NANOSOC_CPU} instead.")
endif()

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

# --- Resolve NANOSOC_CPU (early) --------------------------------------------
# Read the generated memmap to pick up NanoSoC_DEFAULT_CPU, then resolve.
# Done before the CPU description file is loaded so the inherited default
# can drive the actual CPU selection.
if(NOT NANOSOC_CPU AND NanoSoC_FIRMWARE_CONFIG_DIR
   AND EXISTS "${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake")
    include("${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake")
    if(NanoSoC_DEFAULT_CPU)
        set(NANOSOC_CPU "${NanoSoC_DEFAULT_CPU}")
        message(STATUS
            "NanoSoC: NANOSOC_CPU not set; using NanoSoC_DEFAULT_CPU="
            "'${NanoSoC_DEFAULT_CPU}' from generated memmap.")
        set(_NANOSOC_MEMMAP_PRELOADED 1)
    endif()
endif()
if(NOT NANOSOC_CPU)
    set(NANOSOC_CPU "cortex-m0")
    message(STATUS
        "NanoSoC: no NANOSOC_CPU and no NanoSoC_DEFAULT_CPU; "
        "falling back to 'cortex-m0'.")
endif()

# --- Load CPU description (single source of truth for CPU-specific knobs) ---
set(_cpu_file "${CMAKE_CURRENT_SOURCE_DIR}/cmake/cpus/${NANOSOC_CPU}.cmake")
if(NOT EXISTS "${_cpu_file}")
    message(FATAL_ERROR
        "NANOSOC_CPU='${NANOSOC_CPU}' has no description file. "
        "Expected: ${_cpu_file}. Available: ${_cpu_names}.")
endif()
include("${_cpu_file}")

set(_DEVICE_DIR "${_CMSIS_ROOT}/Device/ARM/${NanoSoC_CPU_DEVICE_DIR_NAME}")
if(NOT EXISTS "${_DEVICE_DIR}/Include")
    message(FATAL_ERROR
        "CPU '${NANOSOC_CPU}' (device '${NanoSoC_CPU_DEVICE_DIR_NAME}') is "
        "selected but its CMSIS files are not vendored at: ${_DEVICE_DIR}. "
        "Drop the device tree there or pick a different NANOSOC_CPU.")
endif()
set(_STARTUP_STEM "${NanoSoC_CPU_STARTUP_STEM}")
set(_SYSTEM_STEM  "${NanoSoC_CPU_SYSTEM_STEM}")

if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
    set(_STARTUP_SUBDIR "GCC")
else()
    set(_STARTUP_SUBDIR "ARM")
endif()

set(NanoSoC_LINKER_SCRIPT_DIR "${_SW_ROOT}/common/scripts" CACHE INTERNAL "")
# Firmware package root — used by nanosoc_add_test() to locate cmake/libraries/*.
set(NanoSoC_FIRMWARE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}" CACHE INTERNAL "")

# --- Resolve NANOSOC_C_LIBRARY ----------------------------------------------
# If not set explicitly, pick a sensible toolchain-appropriate default:
#   gcc      → nano (matches historical --specs=nano.specs default)
#   armclang → default (AC6's standardlib, matches COMPILE_MICROLIB=0 default)
#   armcc    → default
if(NOT NANOSOC_C_LIBRARY)
    if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
        set(NANOSOC_C_LIBRARY "nano")
    else()
        set(NANOSOC_C_LIBRARY "default")
    endif()
endif()

set(_clib_file "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libraries/${NANOSOC_C_LIBRARY}.cmake")
if(NOT EXISTS "${_clib_file}")
    file(GLOB _clib_available RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libraries"
         "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libraries/*.cmake")
    message(FATAL_ERROR
        "NANOSOC_C_LIBRARY='${NANOSOC_C_LIBRARY}' has no descriptor. "
        "Expected: ${_clib_file}. Available: ${_clib_available}.")
endif()
include("${_clib_file}")

if(NOT NANOSOC_TOOLCHAIN_ID IN_LIST NanoSoC_CLIB_SUPPORTED)
    message(FATAL_ERROR
        "NANOSOC_C_LIBRARY='${NANOSOC_C_LIBRARY}' (${NanoSoC_CLIB_DISPLAY_NAME}) "
        "does not support toolchain '${NANOSOC_TOOLCHAIN_ID}'. "
        "Supported: ${NanoSoC_CLIB_SUPPORTED}.")
endif()

# ============================================================================
# Target: NanoSoCFirmware::cpu_flags - per-toolchain CPU + endianness flags
#
# Single INTERFACE target carrying the CPU compile/asm flags. The values come
# from the active CPU description file (cmake/cpus/<NANOSOC_CPU>.cmake);
# toolchain selection is via generator expressions on CMAKE_C_COMPILER_ID.
# ============================================================================
add_library(nanosoc_cpu_flags INTERFACE)
add_library(NanoSoCFirmware::cpu_flags ALIAS nanosoc_cpu_flags)
target_compile_options(nanosoc_cpu_flags INTERFACE
    $<$<C_COMPILER_ID:GNU>:${NanoSoC_CPU_FLAGS_GCC}>
    $<$<C_COMPILER_ID:ARMClang>:${NanoSoC_CPU_FLAGS_ARMCLANG}>
    $<$<C_COMPILER_ID:ARMCC>:${NanoSoC_CPU_FLAGS_ARMCC}>
    $<$<BOOL:${NANOSOC_BIGEND}>:$<$<C_COMPILER_ID:GNU>:-mbig-endian>>
)
# GCC links via the driver, which needs the CPU flags to pick the right
# multilib. Propagate only the GCC CPU flags to link; armlink doesn't accept
# compiler-style -mcpu on its command line.
target_link_options(nanosoc_cpu_flags INTERFACE
    $<$<C_COMPILER_ID:GNU>:${NanoSoC_CPU_FLAGS_GCC}>
)

# ============================================================================
# Target: NanoSoCFirmware::clib - C library variant compile / link flags
#
# Data comes from cmake/libraries/<NANOSOC_C_LIBRARY>.cmake. Linked into the
# cmsis target (for transitive compile flags) and applied on the link line
# by nanosoc_add_test (for link flags).
# ============================================================================
add_library(nanosoc_clib INTERFACE)
add_library(NanoSoCFirmware::clib ALIAS nanosoc_clib)
# C-source compile flags (only applied to C files, not asm).
target_compile_options(nanosoc_clib INTERFACE
    $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:GNU>>:${NanoSoC_CLIB_FLAGS_GCC}>
    $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:ARMClang>>:${NanoSoC_CLIB_FLAGS_ARMCLANG}>
    $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:ARMCC>>:${NanoSoC_CLIB_FLAGS_ARMCC}>
)
# ASM-source flags (e.g. armasm --pd predefines). Scoped to ASM language.
target_compile_options(nanosoc_clib INTERFACE
    $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:GNU>>:${NanoSoC_CLIB_ASM_GCC}>
    $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:ARMClang>>:${NanoSoC_CLIB_ASM_ARMCLANG}>
    $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:ARMCC>>:${NanoSoC_CLIB_ASM_ARMCC}>
)
target_link_options(nanosoc_clib INTERFACE
    $<$<C_COMPILER_ID:GNU>:${NanoSoC_CLIB_LINK_GCC}>
    $<$<C_COMPILER_ID:ARMClang>:${NanoSoC_CLIB_LINK_ARMCLANG}>
    $<$<C_COMPILER_ID:ARMCC>:${NanoSoC_CLIB_LINK_ARMCC}>
)
if(NanoSoC_CLIB_DEFINES)
    target_compile_definitions(nanosoc_clib INTERFACE ${NanoSoC_CLIB_DEFINES})
endif()

# ============================================================================
# Target: NanoSoCFirmware::cmsis - CMSIS + device headers, CPU define
# ============================================================================
add_library(nanosoc_cmsis INTERFACE)
add_library(NanoSoCFirmware::cmsis ALIAS nanosoc_cmsis)
target_include_directories(nanosoc_cmsis INTERFACE
    "${_DEVICE_DIR}/Include"
    "${_CMSIS_CORE}")
target_compile_definitions(nanosoc_cmsis INTERFACE -D${NanoSoC_CPU_DEFINE})
target_link_libraries(nanosoc_cmsis INTERFACE nanosoc_cpu_flags)
# Note: nanosoc_clib is NOT linked into cmsis — applied per-test in
# nanosoc_add_test() to allow per-target C_LIBRARY overrides.

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
include("${CMAKE_CURRENT_LIST_DIR}/cmake/NanoSoCBootromFunctions.cmake")

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
    # The memmap may already have been preloaded by the early CPU-default
    # resolution above. Skip the re-include in that case (CMake would tolerate
    # it, but it's cleaner to include exactly once).
    if(NOT _NANOSOC_MEMMAP_PRELOADED)
        include("${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake")
    endif()

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
