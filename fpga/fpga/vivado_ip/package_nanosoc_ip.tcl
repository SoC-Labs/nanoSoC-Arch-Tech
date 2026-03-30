###-----------------------------------------------------------------------------
### NanoSoC Vivado IP Packaging Script
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright 2021-2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### This script packages the nanosoc_chip_vivado_wrapper as a Vivado IP with
### properly defined bus interfaces for use in the Vivado IP Integrator.
###
### Usage:
###   vivado -mode batch -source package_nanosoc_ip.tcl
###
### Required environment variables:
###   FPGA_COMPONENT_FILELIST - Path to TCL filelist for source files
###   FPGA_COMPONENT_LIB     - Output directory for packaged IP
###   FPGA_VENDOR            - IP vendor string (e.g. soclabs.org)
###   FPGA_CORE_REV          - IP core revision number
###-----------------------------------------------------------------------------

set component_lib $env(FPGA_COMPONENT_LIB)

#
# STEP 0: Read in design sources
#
source $env(FPGA_COMPONENT_FILELIST)

# Add the wrapper source file
set wrapper_dir [file dirname [info script]]
read_verilog $wrapper_dir/nanosoc_chip_vivado_wrapper.v

# Set wrapper as top-level
set_property top nanosoc_chip_vivado_wrapper [current_fileset]

update_compile_order -fileset sources_1

#
# STEP 1: Package the project as IP
#
ipx::package_project -root_dir $component_lib \
    -vendor $env(FPGA_VENDOR) \
    -library user \
    -taxonomy /UserIP \
    -import_files \
    -set_current false \
    -force \
    -force_update_compile_order

ipx::unload_core $component_lib/component.xml
ipx::edit_ip_in_project -upgrade true \
    -name tmp_edit_project \
    -directory $component_lib \
    $component_lib/component.xml

update_compile_order -fileset sources_1

#
# STEP 2: Set core metadata
#
set core [ipx::current_core]

set_property display_name    "NanoSoC M0 Processor System" $core
set_property description     "Arm Cortex-M0 based SoC with GPIO, UART, SWD debug, and DMA" $core
set_property vendor_display_name "SoC Labs" $core
set_property company_url     "https://www.soclabs.org" $core
set_property core_revision   $env(FPGA_CORE_REV) $core
set_property supported_families {
    zynq       Production
    zynquplus  Production
    artix7     Production
    kintex7    Production
    virtex7    Production
    spartan7   Production
    virtexu    Production
    kintexu    Production
    virtexuplus Production
    kintexuplus Production
    zynquplus  Production
    versal     Production
} $core

# Ignore frequency DRC (we manage clocking externally)
set_property ipi_drc {ignore_freq_hz true} $core

#
# STEP 3: Remove any auto-inferred bus interfaces (we'll define them manually)
#
foreach bus_if [ipx::get_bus_interfaces -of_objects $core] {
    set bus_name [get_property NAME $bus_if]
    # Keep only what we explicitly define below
    if { $bus_name ne "" } {
        ipx::remove_bus_interface $bus_name $core
    }
}

#
# STEP 4: Define Clock interface
#
ipx::add_bus_interface clk $core
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 [ipx::get_bus_interfaces clk -of_objects $core]
set_property bus_type_vlnv xilinx.com:signal:clock:1.0 [ipx::get_bus_interfaces clk -of_objects $core]
set_property interface_mode slave [ipx::get_bus_interfaces clk -of_objects $core]
set_property display_name "System Clock" [ipx::get_bus_interfaces clk -of_objects $core]
ipx::add_port_map CLK [ipx::get_bus_interfaces clk -of_objects $core]
set_property physical_name clk [ipx::get_port_maps CLK -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]

# Associate reset with this clock
ipx::add_bus_parameter ASSOCIATED_RESET [ipx::get_bus_interfaces clk -of_objects $core]
set_property value nrst [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]

# Associate all bus interfaces with this clock
ipx::add_bus_parameter ASSOCIATED_BUSIF [ipx::get_bus_interfaces clk -of_objects $core]
set_property value {} [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects [ipx::get_bus_interfaces clk -of_objects $core]]

#
# STEP 5: Define Reset interface
#
ipx::add_bus_interface nrst $core
set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 [ipx::get_bus_interfaces nrst -of_objects $core]
set_property bus_type_vlnv xilinx.com:signal:reset:1.0 [ipx::get_bus_interfaces nrst -of_objects $core]
set_property interface_mode slave [ipx::get_bus_interfaces nrst -of_objects $core]
set_property display_name "System Reset (Active Low)" [ipx::get_bus_interfaces nrst -of_objects $core]
ipx::add_port_map RST [ipx::get_bus_interfaces nrst -of_objects $core]
set_property physical_name nrst [ipx::get_port_maps RST -of_objects [ipx::get_bus_interfaces nrst -of_objects $core]]

# Set reset polarity to active-low
ipx::add_bus_parameter POLARITY [ipx::get_bus_interfaces nrst -of_objects $core]
set_property value ACTIVE_LOW [ipx::get_bus_parameters POLARITY -of_objects [ipx::get_bus_interfaces nrst -of_objects $core]]

#
# STEP 6: Define GPIO Port 0 interface
#
ipx::add_bus_interface gpio0 $core
set_property abstraction_type_vlnv xilinx.com:interface:gpio_rtl:1.0 [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property bus_type_vlnv xilinx.com:interface:gpio:1.0 [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property interface_mode master [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property display_name "GPIO Port 0 (16-bit)" [ipx::get_bus_interfaces gpio0 -of_objects $core]

ipx::add_port_map TRI_I [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property physical_name gpio0_tri_i [ipx::get_port_maps TRI_I -of_objects [ipx::get_bus_interfaces gpio0 -of_objects $core]]

ipx::add_port_map TRI_O [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property physical_name gpio0_tri_o [ipx::get_port_maps TRI_O -of_objects [ipx::get_bus_interfaces gpio0 -of_objects $core]]

ipx::add_port_map TRI_T [ipx::get_bus_interfaces gpio0 -of_objects $core]
set_property physical_name gpio0_tri_t [ipx::get_port_maps TRI_T -of_objects [ipx::get_bus_interfaces gpio0 -of_objects $core]]

#
# STEP 7: Define GPIO Port 1 interface
#
ipx::add_bus_interface gpio1 $core
set_property abstraction_type_vlnv xilinx.com:interface:gpio_rtl:1.0 [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property bus_type_vlnv xilinx.com:interface:gpio:1.0 [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property interface_mode master [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property display_name "GPIO Port 1 (16-bit)" [ipx::get_bus_interfaces gpio1 -of_objects $core]

ipx::add_port_map TRI_I [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property physical_name gpio1_tri_i [ipx::get_port_maps TRI_I -of_objects [ipx::get_bus_interfaces gpio1 -of_objects $core]]

ipx::add_port_map TRI_O [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property physical_name gpio1_tri_o [ipx::get_port_maps TRI_O -of_objects [ipx::get_bus_interfaces gpio1 -of_objects $core]]

ipx::add_port_map TRI_T [ipx::get_bus_interfaces gpio1 -of_objects $core]
set_property physical_name gpio1_tri_t [ipx::get_port_maps TRI_T -of_objects [ipx::get_bus_interfaces gpio1 -of_objects $core]]

#
# STEP 8: Define SWD interface (custom bus - individual ports)
# SWD doesn't have a standard Vivado bus definition, so we expose as individual ports
#
# swd_clk - left as standalone port (no bus interface needed)
# swd_dio - tristate, left as standalone ports

#
# STEP 9: Define UART interface
#
ipx::add_bus_interface uart $core
set_property abstraction_type_vlnv xilinx.com:interface:uart_rtl:1.0 [ipx::get_bus_interfaces uart -of_objects $core]
set_property bus_type_vlnv xilinx.com:interface:uart:1.0 [ipx::get_bus_interfaces uart -of_objects $core]
set_property interface_mode master [ipx::get_bus_interfaces uart -of_objects $core]
set_property display_name "UART" [ipx::get_bus_interfaces uart -of_objects $core]

ipx::add_port_map RxD [ipx::get_bus_interfaces uart -of_objects $core]
set_property physical_name uart_rxd [ipx::get_port_maps RxD -of_objects [ipx::get_bus_interfaces uart -of_objects $core]]

ipx::add_port_map TxD [ipx::get_bus_interfaces uart -of_objects $core]
set_property physical_name uart_txd [ipx::get_port_maps TxD -of_objects [ipx::get_bus_interfaces uart -of_objects $core]]

#
# STEP 10: Finalize and save
#
ipx::merge_project_changes -verbose files $core
ipx::update_source_project_archive -component $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core

ipx::save_core $core
ipx::check_integrity -quiet -xrt $core
ipx::move_temp_component_back -component $core
close_project

update_ip_catalog
close_project

puts "==========================================="
puts " NanoSoC IP packaged successfully"
puts " Output: $component_lib"
puts "==========================================="
