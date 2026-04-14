#-----------------------------------------------------------------------------
# NanoSoC Firmware - CMake Functions
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# nanosoc_add_test(<name>
#   [SOURCE_DIR <path>]        # base dir for default MAIN_SOURCE
#   [MAIN_SOURCE <file>]       # override default main source; default: ${SOURCE_DIR}/${name}.c
#   [SOURCES <files>...]       # extra sources (= testcode.mk SOURCE_FILES), appended after retarget
#   [DRIVERS <files>...]       # driver .c files (also puts drivers/ on include path)
#   [LINKER_PROFILE <name>]    # default: cmsdk_cm0
#   [INCLUDES <dirs>...]
#   [DEFINES <-DFOO=1>...]
#   [NO_RETARGET]              # inverse of testcode.mk USE_RETARGET default
#   [USE_GENERIC]              # adds testcodes/generic/ to include path
#   [CC_FLAGS_ARMCLANG <...>]  # extra flags when toolchain is armclang (AC6)
#   [CC_FLAGS_ARMCC <...>]     # extra flags when toolchain is armcc (AC5)
#   [CC_FLAGS_GCC <...>]       # extra flags when toolchain is gcc (e.g. -flto)
#   [C_LIBRARY <name>]         # per-target C lib variant override (cmake/libraries/<name>.cmake).
#                              # Empty/unset = use the package-level NanoSoCFirmware::clib.
#   [HEX_ADJUST_VMA <name>]    # key into NanoSoC_HEX_ADJUST_<name>
#   [STACK_SIZE <hex>]         # default: 0x200
#   [HEAP_SIZE <hex>]          # default: 0x1000
# )
#
# Exported path variables (usable inside SOURCES / INCLUDES):
#   NanoSoC_SOFTWARE_DIR           — firmware/software/
#   NanoSoC_SOFTWARE_COMMON_DIR    — firmware/software/common/
#   NanoSoC_DRIVERS_DIR            — firmware/software/drivers/
#   NanoSoC_DEBUG_TESTER_DIR       — firmware/software/debug_tester/
#   NanoSoC_TESTCODES_GENERIC_DIR  — firmware/testcodes/generic/
#   NanoSoC_CMSDK_DRIVER_C         — CMSDK_driver.c under the active device dir
#
# Linker-profile info (RO/RW base, .ld fragment) is read from variables set by
# ${NanoSoC_FIRMWARE_CONFIG_DIR}/nanosoc_memmap.cmake, which must be included
# in the consumer's top-level CMakeLists.txt before invoking this function.
#-----------------------------------------------------------------------------

function(nanosoc_add_test name)
    set(options NO_RETARGET USE_GENERIC)
    set(oneValueArgs SOURCE_DIR MAIN_SOURCE LINKER_PROFILE HEX_ADJUST_VMA STACK_SIZE HEAP_SIZE C_LIBRARY)
    set(multiValueArgs SOURCES DRIVERS INCLUDES DEFINES CC_FLAGS_ARMCLANG CC_FLAGS_ARMCC CC_FLAGS_GCC)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    # --- Defaults -----------------------------------------------------------
    if(NOT ARG_SOURCE_DIR)
        set(ARG_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
    if(NOT ARG_MAIN_SOURCE)
        set(ARG_MAIN_SOURCE "${ARG_SOURCE_DIR}/${name}.c")
    endif()
    if(NOT ARG_LINKER_PROFILE)
        set(ARG_LINKER_PROFILE "cmsdk_cm0")
    endif()
    if(NOT ARG_STACK_SIZE)
        set(ARG_STACK_SIZE "0x200")
    endif()
    if(NOT ARG_HEAP_SIZE)
        set(ARG_HEAP_SIZE "0x1000")
    endif()

    # --- Validate profile ---------------------------------------------------
    set(_ro_base_var "NanoSoC_PROFILE_${ARG_LINKER_PROFILE}_RO_BASE")
    if(NOT DEFINED ${_ro_base_var})
        message(FATAL_ERROR
            "nanosoc_add_test(${name}): unknown LINKER_PROFILE '${ARG_LINKER_PROFILE}'. "
            "Ensure nanosoc_memmap.cmake has been included and defines "
            "NanoSoC_PROFILE_${ARG_LINKER_PROFILE}_{RO_BASE,RW_BASE,LD_FRAGMENT}.")
    endif()

    # --- Source ordering for bit-equality with Make ------------------------
    # testcode.mk ALL_C_SOURCES order (line 134-144):
    #   MAIN_SOURCE (testname.c), SYSTEM_FILE.c, retarget.c, uart_stdout.c, SOURCE_FILES
    # Drivers are appended AFTER C sources (see COMPILE_OBJECTS line 190).
    # GCC and AC5/AC6 use opposite startup positions:
    #   gcc (single-shot):       ASM first, then C
    #   ds5/ds6 (linker input):  C first, then ASM
    set(_c_sources
        ${ARG_MAIN_SOURCE}
        ${NanoSoC_SYSTEM_C})
    if(NOT ARG_NO_RETARGET)
        list(APPEND _c_sources ${NanoSoC_RETARGET_SOURCES})
    endif()
    if(ARG_SOURCES)
        list(APPEND _c_sources ${ARG_SOURCES})
    endif()
    if(ARG_DRIVERS)
        list(APPEND _c_sources ${ARG_DRIVERS})
    endif()
    if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
        set(_all_sources ${NanoSoC_STARTUP_ASM} ${_c_sources})
    else()
        set(_all_sources ${_c_sources} ${NanoSoC_STARTUP_ASM})
    endif()

    add_executable(${name} ${_all_sources})
    set_target_properties(${name} PROPERTIES SUFFIX ".elf")

    # Common definitions (matches testcode.mk gcc path lines 272-273)
    target_compile_definitions(${name} PRIVATE
        __STACK_SIZE=${ARG_STACK_SIZE}
        __HEAP_SIZE=${ARG_HEAP_SIZE}
    )
    if(ARG_DEFINES)
        target_compile_definitions(${name} PRIVATE ${ARG_DEFINES})
    endif()

    if(ARG_INCLUDES)
        target_include_directories(${name} PRIVATE ${ARG_INCLUDES})
    endif()
    if(ARG_USE_GENERIC)
        target_include_directories(${name} PRIVATE "${NanoSoC_TESTCODES_GENERIC_DIR}")
    endif()
    if(ARG_DRIVERS)
        target_include_directories(${name} PRIVATE "${NanoSoC_DRIVERS_DIR}")
    endif()

    # Toolchain-specific extra flags
    if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc" AND ARG_CC_FLAGS_GCC)
        target_compile_options(${name} PRIVATE ${ARG_CC_FLAGS_GCC})
    elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armclang" AND ARG_CC_FLAGS_ARMCLANG)
        target_compile_options(${name} PRIVATE ${ARG_CC_FLAGS_ARMCLANG})
    elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armcc" AND ARG_CC_FLAGS_ARMCC)
        target_compile_options(${name} PRIVATE ${ARG_CC_FLAGS_ARMCC})
    endif()

    # --- Library linkage (INTERFACE only — sources are injected directly) --
    target_link_libraries(${name} PRIVATE
        NanoSoCFirmware::cmsis
        NanoSoCFirmware::memmap
    )
    if(NOT ARG_NO_RETARGET)
        target_link_libraries(${name} PRIVATE NanoSoCFirmware::retarget)
    endif()

    # --- C library variant ------------------------------------------------
    _nanosoc_apply_clib(${name} "${ARG_C_LIBRARY}")

    # --- Linker invocation --------------------------------------------------
    _nanosoc_apply_linker(${name} ${ARG_LINKER_PROFILE})

    # --- Post-build: .hex .bin .lst -----------------------------------------
    _nanosoc_post_build(${name} "${ARG_HEX_ADJUST_VMA}")
endfunction()


# Applies toolchain-appropriate linker flags for a given profile.
#
# Linker script resolution order (first match wins):
#   1. Per-profile override:  NanoSoC_PROFILE_${profile}_LD_SCRIPT
#   2. Consumer-extra dirs:   NanoSoC_EXTRA_LINKER_SCRIPT_DIRS (list)
#   3. Upstream default:      ${NanoSoC_LINKER_SCRIPT_DIR}/${profile}.ld
#
# Consumer projects (e.g. ethernet-subsystem-ahb) typically append their own
# scripts dir to NanoSoC_EXTRA_LINKER_SCRIPT_DIRS and add custom profile
# variables to their nanosoc_memmap.cmake.
function(_nanosoc_apply_linker target profile)
    set(_ro_base      "${NanoSoC_PROFILE_${profile}_RO_BASE}")
    set(_rw_base      "${NanoSoC_PROFILE_${profile}_RW_BASE}")
    set(_ld_fragment  "${NanoSoC_PROFILE_${profile}_LD_FRAGMENT}")

    # --- Linker script resolution (GCC only — AC6 uses --rw_base/--ro_base) --
    set(_linker_script "")
    if(DEFINED NanoSoC_PROFILE_${profile}_LD_SCRIPT)
        set(_linker_script "${NanoSoC_PROFILE_${profile}_LD_SCRIPT}")
    else()
        foreach(_dir IN LISTS NanoSoC_EXTRA_LINKER_SCRIPT_DIRS)
            if(EXISTS "${_dir}/${profile}.ld")
                set(_linker_script "${_dir}/${profile}.ld")
                break()
            endif()
        endforeach()
        if(NOT _linker_script AND EXISTS "${NanoSoC_LINKER_SCRIPT_DIR}/${profile}.ld")
            set(_linker_script "${NanoSoC_LINKER_SCRIPT_DIR}/${profile}.ld")
        endif()
    endif()

    if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
        if(NOT _linker_script OR NOT EXISTS "${_linker_script}")
            message(FATAL_ERROR
                "nanosoc: linker script for profile '${profile}' not found. "
                "Searched: NanoSoC_PROFILE_${profile}_LD_SCRIPT, "
                "NanoSoC_EXTRA_LINKER_SCRIPT_DIRS (${NanoSoC_EXTRA_LINKER_SCRIPT_DIRS}), "
                "${NanoSoC_LINKER_SCRIPT_DIR}.")
        endif()
        # Build search path: consumer dirs first, then upstream, then firmware config.
        set(_search_args "")
        foreach(_dir IN LISTS NanoSoC_EXTRA_LINKER_SCRIPT_DIRS)
            list(APPEND _search_args "-L${_dir}")
        endforeach()
        list(APPEND _search_args
            "-L${NanoSoC_LINKER_SCRIPT_DIR}"
            "-L${NanoSoC_FIRMWARE_CONFIG_DIR}")
        # CPU flags + C library link flags come from nanosoc_cpu_flags and
        # nanosoc_clib (transitively via target_link_libraries). Only the
        # linker script + search paths are specified here.
        target_link_options(${target} PRIVATE
            "-T${_linker_script}"
            ${_search_args}
        )
        set_target_properties(${target} PROPERTIES
            LINK_DEPENDS "${_ld_fragment};${_linker_script}")
    elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armclang")
        target_link_options(${target} PRIVATE
            "SHELL:--keep=startup_CMSDK_CM0.o(RESET)"
            "SHELL:--first=startup_CMSDK_CM0.o(RESET)"
            "SHELL:--rw_base ${_rw_base}"
            "SHELL:--ro_base ${_ro_base}"
            "--map"
        )
    endif()
endfunction()


# Applies C library variant flags to a target. `override` is either empty
# (use the package-level NANOSOC_C_LIBRARY defaults) or a variant name whose
# descriptor will be loaded into the function's local scope.
function(_nanosoc_apply_clib target override)
    if(override)
        set(_variant "${override}")
        set(_file "${NanoSoC_FIRMWARE_ROOT}/cmake/libraries/${_variant}.cmake")
        if(NOT EXISTS "${_file}")
            message(FATAL_ERROR
                "nanosoc_add_test(${target}): C_LIBRARY='${_variant}' has no "
                "descriptor. Expected: ${_file}.")
        endif()
        include("${_file}")  # populates NanoSoC_CLIB_* in this function's scope
        if(NOT NANOSOC_TOOLCHAIN_ID IN_LIST NanoSoC_CLIB_SUPPORTED)
            message(FATAL_ERROR
                "nanosoc_add_test(${target}): C_LIBRARY='${_variant}' does not "
                "support toolchain '${NANOSOC_TOOLCHAIN_ID}'. "
                "Supported: ${NanoSoC_CLIB_SUPPORTED}.")
        endif()
        # Apply override flags directly on the target (ASM/C separated).
        target_compile_options(${target} PRIVATE
            $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:GNU>>:${NanoSoC_CLIB_FLAGS_GCC}>
            $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:ARMClang>>:${NanoSoC_CLIB_FLAGS_ARMCLANG}>
            $<$<AND:$<COMPILE_LANGUAGE:C>,$<C_COMPILER_ID:ARMCC>>:${NanoSoC_CLIB_FLAGS_ARMCC}>
            $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:GNU>>:${NanoSoC_CLIB_ASM_GCC}>
            $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:ARMClang>>:${NanoSoC_CLIB_ASM_ARMCLANG}>
            $<$<AND:$<COMPILE_LANGUAGE:ASM>,$<C_COMPILER_ID:ARMCC>>:${NanoSoC_CLIB_ASM_ARMCC}>)
        target_link_options(${target} PRIVATE
            $<$<C_COMPILER_ID:GNU>:${NanoSoC_CLIB_LINK_GCC}>
            $<$<C_COMPILER_ID:ARMClang>:${NanoSoC_CLIB_LINK_ARMCLANG}>
            $<$<C_COMPILER_ID:ARMCC>:${NanoSoC_CLIB_LINK_ARMCC}>)
        if(NanoSoC_CLIB_DEFINES)
            target_compile_definitions(${target} PRIVATE ${NanoSoC_CLIB_DEFINES})
        endif()
    else()
        # Default path — link the package-level nanosoc_clib INTERFACE target.
        target_link_libraries(${target} PRIVATE NanoSoCFirmware::clib)
    endif()
endfunction()


# Emits .hex, .bin, .lst alongside the .elf using toolchain-appropriate tools.
function(_nanosoc_post_build target hex_adjust_key)
    # Resolve at configure time. add_executable defaults to CMAKE_CURRENT_BINARY_DIR.
    set(_outdir "${CMAKE_CURRENT_BINARY_DIR}")
    set(_elf "${_outdir}/${target}.elf")
    set(_hex "${_outdir}/${target}.hex")
    set(_bin "${_outdir}/${target}.bin")
    set(_lst "${_outdir}/${target}.lst")

    if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
        set(_objcopy_hex_extra "")
        if(hex_adjust_key AND DEFINED NanoSoC_HEX_ADJUST_${hex_adjust_key})
            list(APPEND _objcopy_hex_extra
                --adjust-vma ${NanoSoC_HEX_ADJUST_${hex_adjust_key}})
        endif()
        # objdump writes to stdout — generate via a CMake script for portable redirection.
        set(_lst_script "${CMAKE_CURRENT_BINARY_DIR}/${target}_genlst.cmake")
        file(WRITE "${_lst_script}"
            "execute_process(\n"
            "    COMMAND \"${CMAKE_OBJDUMP}\" -S \"${_elf}\"\n"
            "    OUTPUT_FILE \"${_lst}\"\n"
            "    RESULT_VARIABLE _rc)\n"
            "if(NOT _rc EQUAL 0)\n"
            "    message(FATAL_ERROR \"objdump failed: \${_rc}\")\n"
            "endif()\n")
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -P "${_lst_script}"
            COMMAND ${CMAKE_OBJCOPY} -S ${_elf} -O binary  ${_bin}
            COMMAND ${CMAKE_OBJCOPY} -S ${_elf} ${_objcopy_hex_extra} -O verilog ${_hex}
            BYPRODUCTS ${_hex} ${_bin} ${_lst}
            COMMENT "Generating ${target}.hex / .bin / .lst")
    elseif(NANOSOC_TOOLCHAIN_ID STREQUAL "armclang")
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${NANOSOC_FROMELF} --vhx --8x1 ${_elf} --output ${_hex}
            COMMAND ${NANOSOC_FROMELF} --bin ${_elf} --output ${_bin}
            COMMAND ${NANOSOC_FROMELF} -c -d -e -s -z -v ${_elf} --output ${_lst}
            BYPRODUCTS ${_hex} ${_bin} ${_lst}
            COMMENT "Generating ${target}.hex / .bin / .lst (fromelf)")
    endif()
endfunction()
