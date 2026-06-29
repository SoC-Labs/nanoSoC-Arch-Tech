# nanosoc SoC family CMake glue.
#
# No SoC-specific C startup is required for hello-world; the generic Cortex-M
# linker script and arch startup are used. Modeled on soc/arm/beetle and
# soc/arm/designstart.
#
# Copyright 2026, SoC Labs.
# SPDX-License-Identifier: Apache-2.0

zephyr_include_directories(.)

set(SOC_LINKER_SCRIPT ${ZEPHYR_BASE}/include/zephyr/arch/arm/cortex_m/scripts/linker.ld CACHE INTERNAL "")
