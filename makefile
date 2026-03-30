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

# Is the Arm QuickStart being used?
QUICKSTART ?= no

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
ifeq ($(QUICKSTART),yes)
	DESIGN_VC            ?= $(SOCLABS_PROJECT_DIR)/flist/project/top_qs.flist
	TBENCH_VC            ?= $(SOCLABS_PROJECT_DIR)/flist/project/top_qs.flist
	ARM_CORSTONE_101_DIR ?= $(ARM_IP_LIBRARY_PATH)/latest/Cortex-M0-QS/Corstone-101-logical
	ARM_CORTEX_M0_DIR    ?= $(ARM_IP_LIBRARY_PATH)/latest/Cortex-M0-QS/Cortex-M0-logical
	TB_TOP               ?= nanosoc_tb_qs
else
	ifeq ($(ASIC),yes)
		DESIGN_VC            	?= $(SOCLABS_PROJECT_DIR)/flist/project/top_ASIC.flist
		ARM_CORSTONE_101_DIR 	?= $(ARM_IP_LIBRARY_PATH)/latest/Corstone-101/logical
		ARM_CORTEX_M0_DIR    	?= $(ARM_IP_LIBRARY_PATH)/latest/Cortex-M0/logical
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
endif

DESIGN_VC_FPGA ?= $(SOCLABS_PROJECT_DIR)/flist/project/top_FPGA.flist
# Make variables visible to target shells
export ARM_CORTEX_M0_DIR
export ARM_CORSTONE_101_DIR
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
gen_defs:
	@mkdir -p $(DEFINES_DIR)
	@$(SOCLABS_SOCTOOLS_FLOW_DIR)/bin/defines_compile.py -d $(NANOSOC_DEFINES) -o $(DEFINES_FILE)

docs:
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.tex
	pdflatex --output-directory=$(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/ $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.tex
	mv $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_datasheet.pdf $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/nanosoc_datasheet.pdf
	mv $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/tex/nanosoc_configuration_manual.pdf $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/doc/doc/nanosoc_configuration_manual.pdf

# Run SoC model generation tool
soc_model:
	cd $(SOCLABS_NANOSOC_GEN_DIR) && python -m soc_model \
		$(SOCLABS_NANOSOC_SOC_DIR)/sys_desc/nanosoc_m0_soc.yaml \
		--lib-dir $(SOCLABS_NANOSOC_GEN_DIR)/lib \
		--build-dir $(SOCLABS_NANOSOC_SOC_DIR)/build_soc

TEST_AMS:
	$(info AMS is $(AMS))
	$(info VCS OPTIONS is $(VCS_OPTIONS))
# Remove RTL compile files, log files, software compile files
clean : clean_all_code
	@rm -rf $(SIM_TOP_DIR)
