#------------------------------------------------------------------------------------
# Cadence Innovus: Floorplan
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# Daniel Newbrook (d.newbrook@soton.ac.uk)
# Copyright (c) 2025, SoC Labs (www.soclabs.org)
#------------------------------------------------------------------------------------

floorPlan -coreMarginsBy die -flip s -site sc12_cln65lp -d 1000.0 1500.0 140.0 140.0 140.0 140.0

deleteIoFiller

addIoFiller -cell PCORNER -prefix CORNER -side top -from 880 -to 1000
addIoFiller -cell PCORNER -prefix CORNER -side right -from 0 -to 120
addIoFiller -cell PCORNER -prefix CORNER -side bottom -from 0 -to 120
addIoFiller -cell PCORNER -prefix CORNER -side left -from 1380 -to 1500

addIoFiller -cell PFILLER20
addIoFiller -cell PFILLER10
addIoFiller -cell PFILLER5
addIoFiller -cell PFILLER1
addIoFiller -cell PFILLER05
addIoFiller -cell PFILLER0005

# relative floorplan
delete_relative_floorplan -all

create_relative_floorplan -ref_type core_boundary -horizontal_edge_separate {1  -4.8  1} -vertical_edge_separate {2  -2.4 2} -place u_nanosoc_chip_u_system_u_ss_cpu_u_region_dmem_0_u_dmem_0_u_sram_genblk1.u_rf_sp_hdf
create_relative_floorplan -ref_type object -horizontal_edge_separate {3  -12  1} -vertical_edge_separate {3  0  3} -place u_nanosoc_chip_u_system_u_ss_cpu_u_region_imem_0_u_imem_0_u_sram_genblk1.u_rf_sp_hdf -ref u_nanosoc_chip_u_system_u_ss_cpu_u_region_dmem_0_u_dmem_0_u_sram_genblk1.u_rf_sp_hdf
create_relative_floorplan -ref_type object -horizontal_edge_separate {3  -12  1} -vertical_edge_separate {3  0  3} -place u_nanosoc_chip_u_system_u_ss_expansion_u_region_sram_0_u_sram_0_u_sram_genblk1.u_rf_sp_hdf -ref u_nanosoc_chip_u_system_u_ss_cpu_u_region_imem_0_u_imem_0_u_sram_genblk1.u_rf_sp_hdf
create_relative_floorplan -ref_type object -orient R0 -horizontal_edge_separate {3  -12  1} -vertical_edge_separate {3  0  3} -place u_nanosoc_chip_u_system_u_ss_expansion_u_region_sram_1_u_sram_1_u_sram_genblk1.u_rf_sp_hdf -ref u_nanosoc_chip_u_system_u_ss_expansion_u_region_sram_0_u_sram_0_u_sram_genblk1.u_rf_sp_hdf
create_relative_floorplan -ref_type core_boundary -orient R0 -horizontal_edge_separate {1  -4.8  1} -vertical_edge_separate {0  2.4  0} -place u_nanosoc_chip_u_system_u_ss_cpu_u_region_bootrom_0_u_bootrom_cpu_0_u_bootrom_u_sl_rom

addHaloToBlock {4.8 4.8 2.4 4.8} u_nanosoc_chip_u_system_u_ss_expansion_u_region_sram_0_u_sram_0_u_sram_genblk1.u_rf_sp_hdf
addHaloToBlock {4.8 4.8 2.4 4.8} u_nanosoc_chip_u_system_u_ss_expansion_u_region_sram_1_u_sram_1_u_sram_genblk1.u_rf_sp_hdf
addHaloToBlock {4.8 4.8 2.4 4.8} u_nanosoc_chip_u_system_u_ss_cpu_u_region_imem_0_u_imem_0_u_sram_genblk1.u_rf_sp_hdf
addHaloToBlock {4.8 4.8 2.4 4.8} u_nanosoc_chip_u_system_u_ss_cpu_u_region_dmem_0_u_dmem_0_u_sram_genblk1.u_rf_sp_hdf
addHaloToBlock {4.8 4.8 2.4 4.8} u_nanosoc_chip_u_system_u_ss_cpu_u_region_bootrom_0_u_bootrom_cpu_0_u_bootrom_u_sl_rom


# Power Plan

# DBG
deselectAll
selectGroup PD_CPU_DBG
setAddRingMode -ring_target default -extend_over_row 0 -ignore_rows 0 -avoid_short 0 -skip_crossing_trunks none -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size 1 -orthogonal_only true -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape }
addRing -nets {VDD VSS} -type block_rings -around power_domain -layer {top M5 bottom M5 left M6 right M6} -width {top 1.8 bottom 1.8 left 1.8 right 1.8} -spacing {top 0.5 bottom 0.5 left 0.5 right 0.5} -offset {top 1.8 bottom 1.8 left 1.8 right 1.8} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid None

addPowerSwitch -column -powerDomain PD_CPU_DBG -globalSwitchCellName HEADTIE8_A12TR -leftOffset 10 -rightOffset 10 -horizontalPitch 10

setAddStripeMode -ignore_block_check false -break_at none -route_over_rows_only false -rows_without_stripes_only false -extend_to_closest_target ring -stop_at_last_wire_for_area false -partial_set_thru_domain false -ignore_nondefault_domains false -trim_antenna_back_to_shape none -spacing_type edge_to_edge -spacing_from_block 0 -stripe_min_length stripe_width -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size false -split_vias false -orthogonal_only true -allow_jog { padcore_ring  block_ring } -skip_via_on_pin { } -skip_via_on_wire_shape {  noshape   }
addStripe -nets {VDD VSS} -layer M6 -direction vertical -width 1.8 -spacing 0.5 -set_to_set_distance 10 -over_power_domain 1 -start_from left -start_offset 10 -switch_layer_over_obs false -max_same_layer_jog_length 2 -padcore_ring_top_layer_limit AP -padcore_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid None
addEndCap -preCap ENDCAPTIE2_A12TR -postCap ENDCAPTIE2_A12TR -prefix ENDCAP -powerDomain PD_CPU_DBG

setSrouteMode -viaConnectToShape { ring stripe corewire }
sroute -connect { blockPin padPin padRing corePin floatingStripe } -layerChangeRange { M1(1) M6(6) } -blockPinTarget { nearestTarget } -padPinPortConnect { allPort oneGeom } -padPinTarget { nearestTarget } -corePinTarget { firstAfterRowEnd } -floatingStripeTarget { blockring padring ring stripe ringpin blockpin followpin } -deleteExistingRoutes -allowJogging 1 -powerDomains { PD_CPU_DBG } -crossoverViaLayerRange { M1(1) AP(10) } -nets { VDD_CPU_DBG VSS } -allowLayerChange 1 -blockPin useLef -targetViaLayerRange { M1(1) AP(10) }

deselectAll
# CPU Sys
selectGroup PC_CPU_SYS
setAddRingMode -ring_target default -extend_over_row 0 -ignore_rows 0 -avoid_short 0 -skip_crossing_trunks none -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size 1 -orthogonal_only true -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape }
addRing -nets {VDD VSS} -type block_rings -around power_domain -layer {top M5 bottom M5 left M6 right M6} -width {top 1.8 bottom 1.8 left 1.8 right 1.8} -spacing {top 0.5 bottom 0.5 left 0.5 right 0.5} -offset {top 1.8 bottom 1.8 left 1.8 right 1.8} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid None

addPowerSwitch -column -powerDomain PD_CPU_SYS -globalSwitchCellName HEADTIE8_A12TR -leftOffset 10 -rightOffset 10 -horizontalPitch 10

setAddStripeMode -ignore_block_check false -break_at none -route_over_rows_only false -rows_without_stripes_only false -extend_to_closest_target ring -stop_at_last_wire_for_area false -partial_set_thru_domain false -ignore_nondefault_domains false -trim_antenna_back_to_shape none -spacing_type edge_to_edge -spacing_from_block 0 -stripe_min_length stripe_width -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size false -split_vias false -orthogonal_only true -allow_jog { padcore_ring  block_ring } -skip_via_on_pin { } -skip_via_on_wire_shape {  noshape   }
addStripe -nets {VDD VSS} -layer M6 -direction vertical -width 1.8 -spacing 0.5 -set_to_set_distance 10 -over_power_domain 1 -start_from left -start_offset 10 -switch_layer_over_obs false -max_same_layer_jog_length 2 -padcore_ring_top_layer_limit AP -padcore_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid None
addEndCap -preCap ENDCAPTIE2_A12TR -postCap ENDCAPTIE2_A12TR -prefix ENDCAP -powerDomain PD_CPU_SYS

setSrouteMode -viaConnectToShape { ring stripe corewire }
sroute -connect { blockPin padPin padRing corePin floatingStripe } -layerChangeRange { M1(1) M6(6) } -blockPinTarget { nearestTarget } -padPinPortConnect { allPort oneGeom } -padPinTarget { nearestTarget } -corePinTarget { firstAfterRowEnd } -floatingStripeTarget { blockring padring ring stripe ringpin blockpin followpin } -deleteExistingRoutes -allowJogging 1 -powerDomains { PD_CPU_SYS } -crossoverViaLayerRange { M1(1) AP(10) } -nets { VDD_CPU_SYS VSS } -allowLayerChange 1 -blockPin useLef -targetViaLayerRange { M1(1) AP(10) }
