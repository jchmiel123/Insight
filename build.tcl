# Insight Display System - Gowin Build Script
# Tang Nano 20K (GW2AR-18C)
#
# Usage: gw_sh build.tcl
# Or run from Gowin EDA IDE

set_device -name GW2AR-18C GW2AR-LV18QN88C8/I7

# Add source files
add_file -type verilog "src/insight_top.v"
add_file -type verilog "src/lib/video_timing.v"
add_file -type verilog "src/lib/mode_controller.v"
add_file -type verilog "src/lib/watermark_overlay.v"
add_file -type verilog "src/modes/slots_screensaver.v"
add_file -type verilog "src/modes/info_screen.v"

# IP cores
add_file -type verilog "src/ip/gowin_rpll/TMDS_rPLL.v"
add_file -type verilog "src/ip/dvi_tx/dvi_tx.v"

# Constraints
add_file -type cst "src/insight.cst"

# Set top module
set_option -top_module insight_top

# Synthesis options
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_reconfign_as_gpio 1
set_option -use_i2c_as_gpio 1

# Place and route options
set_option -timing_driven 1
set_option -looplimit 2000

# Output directory
set_option -output_base_name insight
set_option -gen_text_timing_rpt 1

# Run synthesis
run all
