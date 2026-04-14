#-----------------------------------------------------------------------------
# NanoSoC Bootrom helpers — CMake wrappers for bootrom_gen.py / flash_pack.py
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Mirrors the flows/Makefile.bootrom Make target. Both helpers locate their
# Python scripts under testcodes/bootloader/ (the same location the Make flow
# uses) via NanoSoC_BOOTROM_SCRIPTS_DIR.
#-----------------------------------------------------------------------------

if(NOT DEFINED NanoSoC_BOOTROM_SCRIPTS_DIR)
    set(NanoSoC_BOOTROM_SCRIPTS_DIR
        "${NanoSoC_FIRMWARE_ROOT}/testcodes/bootloader"
        CACHE INTERNAL "Location of bootrom_gen.py / flash_pack.py")
endif()

# find_program with CMAKE_FIND_ROOT_PATH_BOTH ensures we find host python3
# even though the toolchain file targets a bare-metal system.
find_program(NanoSoC_PYTHON3 NAMES python3 python
             HINTS ENV PYTHON_EXECUTABLE
             CMAKE_FIND_ROOT_PATH_BOTH)

#-----------------------------------------------------------------------------
# nanosoc_add_bootrom(NAME <bootrom-name> TARGET <exe>
#     [ADDRESS_WIDTH <n>]         # word-address width (default: 8 → 256 × 32-bit words)
#     [MODULE_NAME <name>]        # Verilog module name (default: bootrom)
#     [REGION_MODULE_NAME <name>] # Region-wrapper module name (default: <NAME>_region_bootrom)
#     [TOOLCHAIN_TAG <tag>]       # passed as -t to bootrom_gen.py (default: gcc)
#     [OUTPUT_DIR <path>]         # default: $<TARGET_FILE_DIR:<TARGET>>
# )
#
# Adds a target `<NAME>_bootrom` that, after <TARGET> is linked, runs
# bootrom_gen.py to produce:
#   <OUTPUT_DIR>/<MODULE_NAME>.sv        — synthesisable Verilog ROM
#   <OUTPUT_DIR>/<MODULE_NAME>.bintxt    — binary text (one 32-bit word per line)
#   <OUTPUT_DIR>/<REGION_MODULE_NAME>.v  — AHB region wrapper
#-----------------------------------------------------------------------------
function(nanosoc_add_bootrom)
    set(options)
    set(oneValueArgs NAME TARGET ADDRESS_WIDTH MODULE_NAME REGION_MODULE_NAME
                     TOOLCHAIN_TAG OUTPUT_DIR)
    set(multiValueArgs)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT ARG_NAME OR NOT ARG_TARGET)
        message(FATAL_ERROR "nanosoc_add_bootrom: NAME and TARGET are required.")
    endif()
    if(NOT TARGET ${ARG_TARGET})
        message(FATAL_ERROR "nanosoc_add_bootrom: '${ARG_TARGET}' is not a target.")
    endif()
    if(NOT NanoSoC_PYTHON3)
        message(FATAL_ERROR "nanosoc_add_bootrom: python3 not found.")
    endif()

    if(NOT ARG_ADDRESS_WIDTH)
        set(ARG_ADDRESS_WIDTH 8)
    endif()
    if(NOT ARG_MODULE_NAME)
        set(ARG_MODULE_NAME "bootrom")
    endif()
    if(NOT ARG_REGION_MODULE_NAME)
        set(ARG_REGION_MODULE_NAME "${ARG_NAME}_region_bootrom")
    endif()
    if(NOT ARG_TOOLCHAIN_TAG)
        # Default tag matches the bootrom_gen.py expectation. The script's only
        # toolchain-specific branch is `if tool_chain=='gcc'` (handles @addr
        # lines in GCC objcopy verilog output); everything else uses the
        # plain-hex branch.
        if(NANOSOC_TOOLCHAIN_ID STREQUAL "gcc")
            set(ARG_TOOLCHAIN_TAG "gcc")
        else()
            set(ARG_TOOLCHAIN_TAG "${NANOSOC_TOOLCHAIN_ID}")
        endif()
    endif()
    # Resolve output dir at configure time. The target's binary dir is where
    # add_executable puts its output by default; we must resolve it here so
    # OUTPUT paths in add_custom_command don't contain un-evaluated genexes
    # (the Unix Makefiles generator doesn't handle $<TARGET_FILE_DIR:...> in
    # OUTPUT cleanly).
    if(NOT ARG_OUTPUT_DIR)
        get_target_property(_tgt_dir ${ARG_TARGET} BINARY_DIR)
        if(NOT _tgt_dir)
            set(_tgt_dir "${CMAKE_CURRENT_BINARY_DIR}")
        endif()
        set(ARG_OUTPUT_DIR "${_tgt_dir}")
    endif()

    set(_hex      "${ARG_OUTPUT_DIR}/${ARG_TARGET}.hex")
    set(_sv       "${ARG_OUTPUT_DIR}/${ARG_MODULE_NAME}.sv")
    set(_bintxt   "${ARG_OUTPUT_DIR}/${ARG_MODULE_NAME}.bintxt")
    set(_region_v "${ARG_OUTPUT_DIR}/${ARG_REGION_MODULE_NAME}.v")
    set(_script   "${NanoSoC_BOOTROM_SCRIPTS_DIR}/bootrom_gen.py")

    add_custom_command(
        OUTPUT  ${_sv} ${_bintxt} ${_region_v}
        COMMAND ${NanoSoC_PYTHON3} ${_script}
                -a ${ARG_ADDRESS_WIDTH}
                -i ${_hex}
                -t ${ARG_TOOLCHAIN_TAG}
                -m ${ARG_MODULE_NAME}
                -v ${_sv}
                -b ${_bintxt}
                -R ${ARG_REGION_MODULE_NAME}
                -r ${_region_v}
        DEPENDS ${ARG_TARGET} ${_script}
        COMMENT "Generating ${ARG_MODULE_NAME}.sv / .bintxt + ${ARG_REGION_MODULE_NAME}.v from ${ARG_TARGET}"
        VERBATIM
    )

    add_custom_target(${ARG_NAME}_bootrom ALL
        DEPENDS ${_sv} ${_bintxt} ${_region_v})
endfunction()


#-----------------------------------------------------------------------------
# nanosoc_add_flash_image(NAME <image-name>
#     OUTPUT <path>                    # packed flash binary path
#     [YAML <soc.yaml>]                # SoC YAML with flash_layout partitions
#     [FLASH_SIZE <hex>]               # default: 0x400000 (4 MB)
#     [BOOT_TABLE_OFFSET <hex>]        # default: 0x0
#     [STAGE1 <core>:<target>...]      # repeatable; <target> is a CMake exe
#     [APP    <core>:<target>...]      # repeatable; <target> is a CMake exe
# )
#
# Adds a target `<NAME>_flash` that packs the given stage1 + app binaries
# (produced by bootloader / application targets) into a single flash image.
# Each `<core>:<target>` pair must reference a defined CMake target; the
# target's <name>.bin is used as the partition payload.
#-----------------------------------------------------------------------------
function(nanosoc_add_flash_image)
    set(options)
    set(oneValueArgs NAME OUTPUT YAML FLASH_SIZE BOOT_TABLE_OFFSET)
    set(multiValueArgs STAGE1 APP)
    cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT ARG_NAME OR NOT ARG_OUTPUT)
        message(FATAL_ERROR "nanosoc_add_flash_image: NAME and OUTPUT are required.")
    endif()
    if(NOT NanoSoC_PYTHON3)
        message(FATAL_ERROR "nanosoc_add_flash_image: python3 not found.")
    endif()

    set(_script "${NanoSoC_BOOTROM_SCRIPTS_DIR}/flash_pack.py")
    set(_cmd ${NanoSoC_PYTHON3} ${_script} --output ${ARG_OUTPUT})
    set(_deps ${_script})

    if(ARG_YAML)
        list(APPEND _cmd --yaml ${ARG_YAML})
        list(APPEND _deps ${ARG_YAML})
    endif()
    if(ARG_FLASH_SIZE)
        list(APPEND _cmd --flash-size ${ARG_FLASH_SIZE})
    endif()
    if(ARG_BOOT_TABLE_OFFSET)
        list(APPEND _cmd --boot-table-offset ${ARG_BOOT_TABLE_OFFSET})
    endif()

    # Translate "<core>:<target>" entries into "<core>:<path-to-target.bin>"
    # and collect the target deps.
    foreach(_spec IN LISTS ARG_STAGE1)
        string(REGEX MATCH "^([0-9]+):(.+)$" _m "${_spec}")
        if(NOT _m)
            message(FATAL_ERROR "nanosoc_add_flash_image: STAGE1 spec '${_spec}' must be <core>:<target>.")
        endif()
        set(_core "${CMAKE_MATCH_1}")
        set(_tgt  "${CMAKE_MATCH_2}")
        if(NOT TARGET ${_tgt})
            message(FATAL_ERROR "nanosoc_add_flash_image: STAGE1 target '${_tgt}' is not defined.")
        endif()
        list(APPEND _cmd --stage1 "${_core}:$<TARGET_FILE_DIR:${_tgt}>/${_tgt}.bin")
        list(APPEND _deps ${_tgt})
    endforeach()
    foreach(_spec IN LISTS ARG_APP)
        string(REGEX MATCH "^([0-9]+):(.+)$" _m "${_spec}")
        if(NOT _m)
            message(FATAL_ERROR "nanosoc_add_flash_image: APP spec '${_spec}' must be <core>:<target>.")
        endif()
        set(_core "${CMAKE_MATCH_1}")
        set(_tgt  "${CMAKE_MATCH_2}")
        if(NOT TARGET ${_tgt})
            message(FATAL_ERROR "nanosoc_add_flash_image: APP target '${_tgt}' is not defined.")
        endif()
        list(APPEND _cmd --app "${_core}:$<TARGET_FILE_DIR:${_tgt}>/${_tgt}.bin")
        list(APPEND _deps ${_tgt})
    endforeach()

    add_custom_command(
        OUTPUT  ${ARG_OUTPUT}
        COMMAND ${_cmd}
        DEPENDS ${_deps}
        COMMENT "Packing flash image ${ARG_OUTPUT}"
        VERBATIM
    )
    add_custom_target(${ARG_NAME}_flash ALL DEPENDS ${ARG_OUTPUT})
endfunction()
