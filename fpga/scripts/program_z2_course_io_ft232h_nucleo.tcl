set bitstream_path [file normalize [file join [pwd] "../build/fpga/z2_course_io_ft232h_nucleo/didactic-z2_course_io_ft232h_nucleo.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit"]]

if {![file exists $bitstream_path]} {
  error "Bitstream not found: $bitstream_path"
}

open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] == 0} {
  error "No Vivado hardware target found"
}

open_hw_target [lindex $targets 0]
set devices [get_hw_devices xc7z020*]
if {[llength $devices] == 0} {
  error "No xc7z020 device found"
}

set dev [lindex $devices 0]
set_property PROGRAM.FILE $bitstream_path $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "PROGRAMMED_DEVICE=$dev"
puts "DONE=[get_property REGISTER.IR.BIT5_DONE $dev]"
if {[lsearch -exact [list_property $dev] "REGISTER.CONFIG_STATUS.BIT2_DONE_PIN"] >= 0} {
  puts "DONE_PIN=[get_property REGISTER.CONFIG_STATUS.BIT2_DONE_PIN $dev]"
}

close_hw_manager
