#-----------------------------------------------------------------------------
# NanoSoC firmware system clock -- one value for the application AND the boot ROM
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Included by flows/makefile.software and by the standalone flows/Makefile.bootrom,
# so both firmware images see the same rule.
#
# THE PROBLEM. Every UART divisor and timer the firmware computes comes from
# NANOSOC_SYS_CLK_FREQ_HZ in the generated build_soc/firmware/nanosoc_memmap.h,
# which states the clock the SoC was DESIGNED for (the sys_desc YAML: 100 MHz).
# An FPGA board runs the same SoC at its own clock -- 25 MHz on PYNQ-Z2 and KR260,
# 50 MHz on MPS3 -- so firmware built from the header prints at a quarter or half
# of 38,400 baud, and nothing fails.
#
# THE RULE. SYS_CLK_FREQ_HZ, when set (a design.mk, nanosoc.config, the command
# line or the environment), is passed to the application and boot ROM builds,
# and testcode.mk turns it into -DNANOSOC_SYS_CLK_FREQ_HZ=<Hz>UL. The generated
# header wraps its default in #ifndef (nanosoc_gen, firmware_memmap.h.j2), so
# the build's value wins. UNSET, NOTHING IS PASSED: every command line is the
# one it was before this file existed, and the images are byte-identical.
#
# FW_CLK_ARG carries its own leading space and is appended with no separator,
# for exactly that reason: `$(MAKE) ... $(SW_MAKE_OPTIONS)$(FW_CLK_ARG)` expands
# to the old text, to the byte, when the variable is unset.
#-----------------------------------------------------------------------------

ifneq ($(strip $(SYS_CLK_FREQ_HZ)),)
  ifneq ($(shell echo '$(strip $(SYS_CLK_FREQ_HZ))' | grep -Ex '[1-9][0-9]{0,9}'),$(strip $(SYS_CLK_FREQ_HZ)))
    $(error SYS_CLK_FREQ_HZ='$(SYS_CLK_FREQ_HZ)' is not a clock in Hz. Give a plain decimal integer such as 25000000, with no suffix: it is compiled into the firmware as -DNANOSOC_SYS_CLK_FREQ_HZ=<value>UL)
  endif
endif

FW_CLK_ARG = $(if $(strip $(SYS_CLK_FREQ_HZ)), SYS_CLK_FREQ_HZ=$(strip $(SYS_CLK_FREQ_HZ)))

# A CHANGED CLOCK MUST REBUILD. Setting SYS_CLK_FREQ_HZ changes no file, so a hex
# built at another clock would otherwise be reused in silence -- the same defect
# class as a hex target with no prerequisites. This stamp holds the value the
# firmware is being built for and is rewritten only when that value changes, so
# it is newer than the images exactly when they are stale. Both image rules
# list it as a prerequisite. (Measured with GNU make 4.2.1: an unchanged value
# rebuilds nothing.)
FW_CLK_STAMP := $(SOCLABS_PROJECT_DIR)/build/firmware/sys_clk_freq_hz.stamp

# This file is included before the includer's first target, and a rule here
# would otherwise become the includer's default goal. Put it back.
fw_clk_saved_default_goal := $(.DEFAULT_GOAL)

.PHONY: fw_clk_force
$(FW_CLK_STAMP): fw_clk_force
	@mkdir -p $(@D); v='SYS_CLK_FREQ_HZ=$(strip $(SYS_CLK_FREQ_HZ))'; \
	 [ "$$(cat $@ 2>/dev/null)" = "$$v" ] || echo "$$v" > $@

.DEFAULT_GOAL := $(fw_clk_saved_default_goal)
