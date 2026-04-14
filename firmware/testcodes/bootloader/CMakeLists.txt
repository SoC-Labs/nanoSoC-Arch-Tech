#-----------------------------------------------------------------------------
# NanoSoC Test: bootloader (CMake)
# Mirrors firmware/testcodes/bootloader/makefile
#
# Note: bootrom_gen.py + flash_pack.py post-processing are deliberately out of
# scope for the Phase 0 spike — they belong to the separate bootrom flow
# (flows/Makefile.bootrom). The spike only proves the bootloader .hex builds
# and is bit-identical to the Make-built equivalent.
#-----------------------------------------------------------------------------

nanosoc_add_test(bootloader
    SOURCE_DIR "${NanoSoC_SOFTWARE_COMMON_DIR}/bootloader"
    LINKER_PROFILE cmsdk_bootloader
    NO_RETARGET
    OPT_LEVEL -O1
    CC_FLAGS_GCC -Os -flto -mthumb-interwork
    # NB: HEX_ADJUST_VMA is intentionally NOT set here — the basic testcode
    # build emits the hex at the bootloader's RO base (0x08000000). The
    # downstream bootrom flow (flows/Makefile.bootrom) handles --adjust-vma
    # via NanoSoC_HEX_ADJUST_bootloader when packaging into bootrom.sv.
)

# Note: --no_scatterload_enabled (legacy AC5 option) intentionally not added
# here — see the rationale in firmware/testcodes/bootloader/makefile.
