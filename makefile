#-----------------------------------------------------------------------------
# NanoSoC-Redux Top-Level Makefile
# - Includes other Makefiles in flow directory
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Flynn (d.w.flynn@soton.ac.uk)
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

#-------------------------------------
# - Shell
#-------------------------------------
# Several recipes pipe a tool through tee (vcs ... | tee compile_vcs.log,
# ./simv ... | tee logs/run_x.log). Under /bin/sh a pipeline's status is the
# LAST stage's, so a failed compile or simulation returned 0 and the target
# reported success. bash -o pipefail fails the recipe when any stage fails.
# Every recipe in this file and flows/* is plain POSIX sh, so bash runs them
# unchanged. Sub-makes (Makefile.bootrom, the firmware makefiles) are separate
# invocations and keep their own shell; none of their recipes pipe.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

include $(SOCLABS_PROJECT_DIR)/nanosoc.config

#-------------------------------------
# - IP Submodule Paths
#-------------------------------------
# IP submodules nested inside rtl/ directory of nanosoc_arch_tech.
SOCLABS_HOSTIO4_TECH_DIR   ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/hostio4
SOCLABS_SOCDEBUG_TECH_DIR  ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/socdebug_tech
SOCLABS_SLCOREM0_TECH_DIR  ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/slcorem0_tech
SOCLABS_SLDMA230_TECH_DIR  ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sldma230_tech
SOCLABS_SLDMA350_TECH_DIR  ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sldma350_tech

# NanoSoC Generation Tool (soc_model, glue logic RTL, component library)
SOCLABS_NANOSOC_GEN_DIR    ?= $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/nanosoc_gen

export SOCLABS_HOSTIO4_TECH_DIR
export SOCLABS_SOCDEBUG_TECH_DIR
export SOCLABS_SLCOREM0_TECH_DIR
export SOCLABS_SLDMA230_TECH_DIR
export SOCLABS_SLDMA350_TECH_DIR
export SOCLABS_NANOSOC_GEN_DIR

#-------------------------------------
# - Commonly Overloaded Variables
#-------------------------------------
# Name of test directory - Default Test is Hello World
TESTNAME   ?= hello

# Is an accelerator subsystem present in the design?
ACCELERATOR ?= no

# IS this for an ASIC Flow?
ASIC ?= no

# IS this for an Gate level simulations?
GATE ?= no

# Are simulations to be run in fast mode? (i.e. RAMs preloaded)
FAST_SIM ?= yes
VCD_SIM ?= no

#-------------------------------------
# - AutoConfig Overloaded Variables
#-------------------------------------
include $(SOCLABS_PROJECT_DIR)/autoconfig
export TOOL_CHAIN
export SIMULATOR

#-------------------------------------
# - Directory Setups
#-------------------------------------
# Directory of Testcodes
TESTCODES_DIR    := $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/testcodes

# Project System Directory
FPGA_IMP_DIR     := $(SOCLABS_PROJECT_DIR)/imp/fpga
PROJ_SYS_DIR     := $(SOCLABS_PROJECT_DIR)/system
PROJ_SW_DIR      ?= $(PROJ_SYS_DIR)/testcodes

# Directory to put simulation files
SIM_TOP_DIR ?= $(SOCLABS_PROJECT_DIR)/simulate/sim
SIM_DIR      = $(SIM_TOP_DIR)/$(TESTNAME)

#-------------------------------------
# - Test List Variables
#-------------------------------------
# List of all tests (this is used when running 'make all/clean')
TEST_LIST_FILE   ?= $(TESTCODES_DIR)/software_list.txt
TEST_LIST         = $(shell cat $(TEST_LIST_FILE) | while read line || [ -n "$$line" ]; do echo $$line; done)

# List of Tests to Exclude from Regression
EXCLUDE_LIST_FILE = $(TESTCODES_DIR)/excluded_tests.txt

#-------------------------------------
# - Verilog Defines and Filelists
#-------------------------------------
# Simulator/Lint Defines
DEFINES_VC  += +define+CORTEX_M0 +define+USE_TARMAC

# Set Variables depending on whether Accelerator is in System
ifeq ($(ACCELERATOR),yes)
	DEFINES_VC += +define+ACCELERATOR_SUBSYSTEM
	NANOSOC_DEFINES += ACCELERATOR_SUBSYSTEM
endif

# Set variables for tesbench if fast simulation
ifeq ($(GATE), no)
	ifeq ($(FAST_SIM),yes)
		DEFINES_VC += +define+FAST_SIM
		NANOSOC_DEFINES += FAST_SIM
	endif
endif

ifeq ($(GATE),no)
ifdef DMA_DMA350_INCLUDE
	DMA_INCLUDE:=yes
	ifdef DMA350_SMALL
		DMA_TYPE:=350S
		NANOSOC_DEFINES += DMAC_DMA350
		FLIST_INCLUDES += $(SOCLABS_SLDMA350_TECH_DIR)/flist/sldma350_ahb_small.flist
	endif
	ifdef DMA350_DEFAULT
		DMA_TYPE:=350
		NANOSOC_DEFINES += DMAC_DMA350 DMA350_STREAM_2
		FLIST_INCLUDES += $(SOCLABS_SLDMA350_TECH_DIR)/flist/sldma350_ahb.flist
	endif
	ifdef DMA350_BIG
		DMA_TYPE:=350L
		NANOSOC_DEFINES += DMAC_DMA350 DMA350_STREAM_2 DMA350_STREAM_3
		FLIST_INCLUDES += $(SOCLABS_SLDMA350_TECH_DIR)/flist/sldma350_ahb_big.flist
	endif
else
	ifdef DMA_0_PL230_INCLUDE
		DMA_INCLUDE:=yes
		DMA_TYPE:=230
		NANOSOC_DEFINES += DMAC_0_PL230
		FLIST_INCLUDES +=$(SOCLABS_SLDMA230_TECH_DIR)/flist/sldma230_ip.flist
	endif
	ifdef DMA_1_PL230_INCLUDE
		DMA_INCLUDE:=yes
		DMA_TYPE:=230
		NANOSOC_DEFINES += DMAC_1_PL230
		FLIST_INCLUDES +=$(SOCLABS_SLDMA230_TECH_DIR)/flist/sldma230_ip.flist
	endif
endif
endif

export DMA_INCLUDE
export DMA_TYPE

ifdef ADC_0_INCLUDE
	AMS = yes
	NANOSOC_DEFINES += AMS_PERIPHERALS ADC_0_INCLUDE
	FLIST_INCLUDES += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sl_ams_tech/SL_ADC_8bits/flist/sl_adc_8bits_ip.flist
endif

ifdef ADC_1_INCLUDE
	AMS = yes
	NANOSOC_DEFINES += AMS_PERIPHERALS ADC_1_INCLUDE
	FLIST_INCLUDES += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sl_ams_tech/SL_ADC_8bits/flist/sl_adc_8bits_ip.flist
endif

ifdef ADC_2_INCLUDE
	AMS = yes
	NANOSOC_DEFINES += AMS_PERIPHERALS ADC_2_INCLUDE
	FLIST_INCLUDES += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sl_ams_tech/SL_ADC_8bits/flist/sl_adc_8bits_ip.flist
endif

ifdef ADC_3_INCLUDE
	AMS = yes
	NANOSOC_DEFINES += AMS_PERIPHERALS ADC_3_INCLUDE
	FLIST_INCLUDES += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/sl_ams_tech/SL_ADC_8bits/flist/sl_adc_8bits_ip.flist
endif

ifdef_any_of = $(filter-out yes,$(foreach v,$(1),$(origin $(v))))

ifeq ($(GATE),no)
ifneq ($(call ifdef_any_of,$(SNPS_PVT_VM_0_INCLUDE) $(SNPS_PVT_PD_0_INCLUDE) $(SNPS_PVT_TS_0_INCLUDE) $(SNPS_PVT_TS_1_INCLUDE) $(SNPS_PVT_TS_2_INCLUDE) $(SNPS_PVT_TS_3_INCLUDE) $(SNPS_PVT_TS_4_INCLUDE) $(SNPS_PVT_TS_5_INCLUDE)),)
	SNPS_PVT_INC:=yes
	FLIST_INCLUDES  += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/synopsys_28nm_slm_integration/flist/synopsys_pvt_ip.flist
	ifeq ($(ASIC),no)
		FLIST_INCLUDES += $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/rtl/synopsys_28nm_slm_integration/flist/synopsys_pvt_VIP.flist
	endif
endif
ifdef SNPS_PVT_TS_0_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_0_INCLUDE
endif

ifdef SNPS_PVT_TS_1_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_1_INCLUDE
endif

ifdef SNPS_PVT_TS_2_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_2_INCLUDE
endif

ifdef SNPS_PVT_TS_3_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_3_INCLUDE
endif

ifdef SNPS_PVT_TS_4_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_4_INCLUDE
endif

ifdef SNPS_PVT_TS_5_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_TS_5_INCLUDE
endif

ifdef SNPS_PVT_PD_0_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_PD_0_INCLUDE
endif

ifdef SNPS_PVT_VM_0_INCLUDE
	NANOSOC_DEFINES += SNPS_PVT_MONITORING SNPS_PVT_VM_0_INCLUDE
endif
endif

export SNPS_PVT_INC


# ASIC MEMORY INCLUSION
ifeq ($(ASIC),yes)
	ifeq ($(NODE),16)
		FLIST_INCLUDES += $(SOCLABS_ASIC_LIB_TECH_DIR)/flist/asic_lib_ip_TSMC16nm.flist
	else ifeq ($(NODE),28)
		FLIST_INCLUDES += $(SOCLABS_ASIC_LIB_TECH_DIR)/flist/asic_lib_ip_TSMC28nm.flist
	else
		FLIST_INCLUDES += $(SOCLABS_ASIC_LIB_TECH_DIR)/flist/asic_lib_ip.flist
	endif
endif


# System Design Filelist
# The Arm IP roots. A project overrides these in its nanosoc.config (the Arm
# Quickstart download nests them differently); everything below the root is
# identical in both releases, so the filelists are shared.
ARM_CORSTONE_101_DIR ?= $(ARM_IP_LIBRARY_PATH)/latest/Corstone-101/logical
ARM_CORTEX_M0_DIR    ?= $(ARM_IP_LIBRARY_PATH)/latest/Cortex-M0/logical

# The directories holding the chip and pad-ring sources named by
# rtl/flist/nanosoc_ip.flist (nanosoc_chip.v) and rtl/flist/nanosoc.flist
# (nanosoc_chip_pads.v). Default to the checked-in copies in nanosoc_m0_soc, so
# every project that does not set them builds exactly as before. A project whose
# generated build_soc/rtl pair is the one that matches its nanosoc_system (e.g.
# one that has removed SPI) overrides both in its nanosoc.config.
# Directories, not file paths: filelist_compile.py classifies a flist line by
# the extension of its UNEXPANDED text, so a bare "$(VAR)" line is dropped.
NANOSOC_CHIP_DIR      ?= $(SOCLABS_NANOSOC_SOC_DIR)/chip/chip/verilog
NANOSOC_CHIP_PADS_DIR ?= $(SOCLABS_NANOSOC_SOC_DIR)/chip/pads/glib/verilog

ifeq ($(ASIC),yes)
	DESIGN_VC            	?= $(SOCLABS_PROJECT_DIR)/flist/project/top_ASIC.flist
	NANOSOC_DEFINES      	+= ASIC_TEST_PORTS
else
	ifeq ($(GATE),yes)
		DESIGN_VC		 	?= $(SOCLABS_PROJECT_DIR)/flist/project/top_GATE.flist
		TBENCH_VC 		 	?= $(SOCLABS_PROJECT_DIR)/flist/project/top_GATE.flist
		TB_TOP 				?= nanosoc_tb
		NANOSOC_DEFINES 	+= GATE_SIM ARM_UD_MODEL INITIALISE_MEMORY ARM_POWER_AWARE POWER_PINS MR74125_GATE_PW_SIM MR74127_GATE_PW_SIM
	else
		DESIGN_VC       	?= $(SOCLABS_PROJECT_DIR)/flist/project/top.flist
		TBENCH_VC       	?= $(SOCLABS_PROJECT_DIR)/flist/project/top.flist
		TB_TOP          	?= nanosoc_tb
	endif
endif

DESIGN_VC_FPGA ?= $(SOCLABS_PROJECT_DIR)/flist/project/top_FPGA.flist
# Make variables visible to target shells
export ARM_CORTEX_M0_DIR
export ARM_CORSTONE_101_DIR
export NANOSOC_CHIP_DIR
export NANOSOC_CHIP_PADS_DIR
export FLIST_INCLUDES
export AMS
export GATE
# Location of Defines File
DEFINES_DIR   := $(SOCLABS_PROJECT_DIR)/system/src/defines/
DEFINES_FILE  := $(DEFINES_DIR)/gen_defines.v

#------------------------------------------
# - Include Makefiles for Specific Flows
#------------------------------------------
# Include Software Compilation Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.software

# Include Linting Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.lint

# Include Simulation Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.simulate

# Include Regression Simulation Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.regression

# Include FPGA Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.fpga

# Include Synthesis Makefile
include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/flows/makefile.asic

#------------------------------------------
# - Common Targets Across Flows
#------------------------------------------
# Generate Defines File for NanoSoC
#
# WARNING, and the reason check_defs below exists: this is a phony rule with no
# prerequisites that rewrites a SHARED file from whatever NANOSOC_DEFINES the
# current goal carries, and make runs a phony rule at most once per invocation.
# A goal list that mixes flows -- `make flist_dc_nanosoc compile_vcs`, or a
# simulation flist goal followed by a compile -- therefore writes the file for
# the FIRST goal and every later goal in the same run silently consumes it.
# That is how a cold build produced a 121-module, 1,016,920-byte simulator that
# stops retiring instructions inside the boot ROM: RAM_PRELOAD was missing and
# nothing said so. Never rely on gen_defs alone to make the file right for the
# goal that reads it; depend on check_defs as well.
.PHONY: gen_defs check_defs
gen_defs:
	@mkdir -p $(DEFINES_DIR)
	@$(SOCLABS_SOCTOOLS_FLOW_DIR)/bin/defines_compile.py -d $(NANOSOC_DEFINES) -o $(DEFINES_FILE)

# Assert that the defines file on disk is the one THIS goal needs, before any
# tool reads it. Compares both directions: a define this goal requires that is
# absent, and a define present that this goal did not ask for (contamination
# from another flow's goal in the same make run). Names every offending define
# and both define sets, and fails. Costs one grep per define.
check_defs:
	@if [ ! -f $(DEFINES_FILE) ]; then \
	  echo "ERROR: check_defs: $(DEFINES_FILE) does not exist. Run gen_defs first." >&2; exit 1; \
	fi; \
	want="$(strip $(NANOSOC_DEFINES))"; \
	have=$$(sed -n 's/^`define[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' $(DEFINES_FILE) | tr '\n' ' '); \
	missing=""; for d in $$want; do \
	  case " $$have " in *" $$d "*) ;; *) missing="$$missing $$d" ;; esac; done; \
	extra=""; for d in $$have; do \
	  case " $$want " in *" $$d "*) ;; *) extra="$$extra $$d" ;; esac; done; \
	if [ -n "$$missing" ] || [ -n "$$extra" ]; then \
	  echo "ERROR: check_defs: $(DEFINES_FILE) does not match the defines this goal needs." >&2; \
	  [ -n "$$missing" ] && echo "       missing:$$missing" >&2; \
	  [ -n "$$extra" ]   && echo "       unexpected:$$extra" >&2; \
	  echo "       goal needs: $$want" >&2; \
	  echo "       file has:   $$have" >&2; \
	  echo "       Cause: gen_defs is phony and runs once per make invocation, so an" >&2; \
	  echo "       earlier goal in this run (or MAKECMDGOALS='$(MAKECMDGOALS)') wrote it." >&2; \
	  echo "       Fix: run each flow in its own make invocation." >&2; \
	  exit 1; \
	fi

docs:
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.tex
	mv $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.pdf $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/nanosoc_datasheet.pdf
	mv $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.pdf $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/nanosoc_configuration_manual.pdf

# SoC model generation belongs to the SoC repository: the YAML and build_soc/
# live in $(SOCLABS_NANOSOC_SOC_DIR), and its Makefile owns the generator
# invocation. (The target here used to point at a YAML that does not exist.)
# Delegate when that Makefile provides soc_model, otherwise say where to run it.
.PHONY: soc_model
soc_model:
	@if grep -qs '^soc_model:' $(SOCLABS_NANOSOC_SOC_DIR)/Makefile; then \
	  echo "soc_model: delegating to make -C $(SOCLABS_NANOSOC_SOC_DIR) soc_model"; \
	  $(MAKE) -C $(SOCLABS_NANOSOC_SOC_DIR) soc_model; \
	else \
	  echo "soc_model: not provided by nanosoc_arch_tech. run: make -C $(SOCLABS_NANOSOC_SOC_DIR) soc_model" >&2; \
	  exit 2; \
	fi

TEST_AMS:
	$(info AMS is $(AMS))
	$(info VCS OPTIONS is $(VCS_OPTIONS))

#------------------------------------------
# - Environment and health checks
#------------------------------------------
# env: every resolved SOCLABS_*/ARM_*/NANOSOC_*/BOOTROM_* variable the flow
# reads (environment and makefile chain), one per line, sorted. Expanded here
# so what is printed is what the recipes see.
.PHONY: env doctor
ENV_VAR_PATTERNS := SOCLABS_% ARM_% NANOSOC_% BOOTROM_%
env:
	@true $(foreach v,$(sort $(filter $(ENV_VAR_PATTERNS),$(.VARIABLES))),$(info $(v)=$($(v))))

# doctor: tool versions, IP roots, Python packages. The script lives in
# soctools_flow (bin/soclabs_doctor.sh); its exit code is the verdict.
SOCLABS_DOCTOR := $(SOCLABS_SOCTOOLS_FLOW_DIR)/bin/soclabs_doctor.sh
doctor:
	@if [ ! -f "$(SOCLABS_DOCTOR)" ]; then \
	  echo "doctor: $(SOCLABS_DOCTOR) not found." >&2; \
	  echo "        Update the soctools_flow submodule, or check SOCLABS_SOCTOOLS_FLOW_DIR (make env)." >&2; \
	  exit 2; \
	fi
	@if [ -x "$(SOCLABS_DOCTOR)" ]; then "$(SOCLABS_DOCTOR)"; else bash "$(SOCLABS_DOCTOR)"; fi
# Remove RTL compile files, log files, software compile files
clean : clean_all_code
	@rm -rf $(SIM_TOP_DIR)
