ROOT := ../../..
BUILD_DIR ?= $(ROOT)/build/group2_final_tb

RTL := \
	$(ROOT)/src/subsystem_group2/rtl/group2_pkg.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_apb_if.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_addr_decoder.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_regbank.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_sa_ctrl.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_input_frontend.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_pe.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_sa.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_sram_32x128.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_output_buffer.sv \
	$(ROOT)/src/subsystem_group2/rtl/group2_topmodule.sv

.PHONY: test core-test frontend-test wrapper-test lint clean

test: core-test frontend-test wrapper-test

core-test:
	mkdir -p $(BUILD_DIR)
	iverilog -g2012 -s group2_final_tb -o $(BUILD_DIR)/group2_final_tb.vvp \
		$(RTL) group2_final_tb.sv
	vvp $(BUILD_DIR)/group2_final_tb.vvp

frontend-test:
	mkdir -p $(BUILD_DIR)
	iverilog -g2012 -s group2_frontend_tb -o $(BUILD_DIR)/group2_frontend_tb.vvp \
		$(ROOT)/src/subsystem_group2/rtl/group2_pkg.sv \
		$(ROOT)/src/subsystem_group2/rtl/group2_input_frontend.sv \
		group2_frontend_tb.sv
	vvp $(BUILD_DIR)/group2_frontend_tb.vvp

wrapper-test:
	mkdir -p $(BUILD_DIR)
	iverilog -g2012 -s group2_wrapper_tb -o $(BUILD_DIR)/group2_wrapper_tb.vvp \
		$(RTL) $(ROOT)/src/subsystem_group2/fpga/group2_fpga_student_wrappers.sv \
		group2_wrapper_tb.sv
	vvp $(BUILD_DIR)/group2_wrapper_tb.vvp

lint:
	verilator --lint-only -Wall -Wno-fatal --top-module group2_topmodule $(RTL)

clean:
	rm -rf $(BUILD_DIR)
