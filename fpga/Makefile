######################################
# Didactic SoC 
# FPGA flow makefile
# Contributor(s):
#   -Matti Käyrä (matti.kayra@tuni.fi)
######################################

SHELL = bash
VIVADO ?= vivado

TEST ?= blink
NUCLEO_BRIDGE_DIR ?= nucleo_uart_bridge
UART_DEV ?= /dev/ttyACM0
XLEN ?= 64
PREFIX ?= riscv$(XLEN)-unknown-elf
GDB ?= $(PREFIX)-gdb

export BUILD_DIR ?= ../build
export PROJECT ?= z1

check_env:
	mkdir -p $(BUILD_DIR)

all_xilinx: check_env
	cd $(BUILD_DIR)
	$(VIVADO) -mode batch -notrace -source ../fpga/scripts/run_xilinx.tcl  

all_xilinx_gui: check_env
	cd $(BUILD_DIR)
	$(VIVADO) -mode gui -source ../fpga/scripts/run_xilinx.tcl &

z2_course_io_ft232h_nucleo: PROJECT=z2_course_io_ft232h_nucleo
z2_course_io_ft232h_nucleo: all_xilinx

z2_course_io_ft232h_nucleo_gui: PROJECT=z2_course_io_ft232h_nucleo
z2_course_io_ft232h_nucleo_gui: all_xilinx_gui

z2_course_io_ft232h_nucleo_group2: PROJECT=z2_course_io_ft232h_nucleo_group2
z2_course_io_ft232h_nucleo_group2: all_xilinx

z2_course_io_ft232h_nucleo_group2_gui: PROJECT=z2_course_io_ft232h_nucleo_group2
z2_course_io_ft232h_nucleo_group2_gui: all_xilinx_gui

load_elf: check_env
	$(GDB) $(BUILD_DIR)/fpga/sw/$(TEST).elf -x ../fpga/utils/connect-and-load.gdb

openocd_z2:
	openocd -f utils/openocd-didactic-ft232h-z2.cfg

nucleo_bridge:
	$(MAKE) -C $(NUCLEO_BRIDGE_DIR) BUILD_DIR=../../build/nucleo_uart_bridge

flash_nucleo_bridge:
	$(MAKE) -C $(NUCLEO_BRIDGE_DIR) BUILD_DIR=../../build/nucleo_uart_bridge flash

uart_monitor:
	stty -F $(UART_DEV) 9600 cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo
	cat -v $(UART_DEV)
