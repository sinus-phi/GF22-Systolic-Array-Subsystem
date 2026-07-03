####
# Didactic SoC 
# Baremetal controller SW flow makefile
# Contributor(s):
#   -Matti Käyrä (matti.kayra@tuni.fi)
#   -Antti Nurmi
#   -Paul R. Genssler (paul.genssler@tum.de)
###

TESTCASE ?= blink
START_TIME=`date +%F_%H:%M`
SHELL = bash
BUILD_DIR ?= ../build
XLEN ?= 64
PREFIX ?= riscv$(XLEN)-unknown-elf
ARCH_FLAGS ?= -march=rv32imc -mabi=ilp32
CC=$(PREFIX)-gcc
CFLAGS=-O2 -g -ffunction-sections -fdata-sections -Icommon/
OBJDUMP ?= $(PREFIX)-objdump
OBJCOPY ?= $(PREFIX)-objcopy

env:
	mkdir -p $(BUILD_DIR)/sw
	echo "prerequisite: local install of RISCV32 toolchain + elf2hex"

build_test:
	$(CC) $(ARCH_FLAGS) -D__riscv__ $(CFLAGS) -c $(TESTCASE)/$(TESTCASE).c -o $(BUILD_DIR)/sw/$(TESTCASE).o 
	$(CC) $(ARCH_FLAGS) -D__riscv__ $(CFLAGS) -DLANGUAGE_ASSEBMLY -c common/crt0.S -o $(BUILD_DIR)/sw/crt0.o
	$(CC) $(ARCH_FLAGS) -Tcommon/link.ld $(BUILD_DIR)/sw/$(TESTCASE).o $(BUILD_DIR)/sw/crt0.o -nostartfiles -nostdlib -Wl,--gc-sections -o $(BUILD_DIR)/sw/$(TESTCASE).elf

hex_test:
	$(OBJCOPY) --only-section=.text $(BUILD_DIR)/sw/$(TESTCASE).elf -O binary $(BUILD_DIR)/tmp.bin
	$(OBJCOPY) --remove-section=.text $(BUILD_DIR)/sw/$(TESTCASE).elf -O binary $(BUILD_DIR)/tmp_data.bin
	xxd -ps $(BUILD_DIR)/tmp.bin $(BUILD_DIR)/tmp.hex
	tr -d '\n' < $(BUILD_DIR)/tmp.hex > $(BUILD_DIR)/tmp_nl.hex	
	sed -r 's/(.{8})/\1\n/g' < $(BUILD_DIR)/tmp_nl.hex > $(BUILD_DIR)/tmp_be.hex
	sed -E 's/(..)(..)(..)(..)/\4\3\2\1/' < $(BUILD_DIR)/tmp_be.hex > $(BUILD_DIR)/tmp_le.hex
	xxd -ps $(BUILD_DIR)/tmp_data.bin $(BUILD_DIR)/tmp_data.hex
	tr -d '\n' < $(BUILD_DIR)/tmp_data.hex > $(BUILD_DIR)/tmp_data_nl.hex	
	sed -r 's/(.{8})/\1\n/g' < $(BUILD_DIR)/tmp_data_nl.hex > $(BUILD_DIR)/tmp_data_be.hex
	sed -E 's/(..)(..)(..)(..)/\4\3\2\1/' < $(BUILD_DIR)/tmp_data_be.hex > $(BUILD_DIR)/tmp_data_le.hex
	$(OBJDUMP) -h $(BUILD_DIR)/sw/$(TESTCASE).elf | awk 'NR>1 {print $$2 " start address: 0x" $$4}' > $(BUILD_DIR)/sw/$(TESTCASE)_addresses.txt

trim:
	head -$(shell wc -w < $(BUILD_DIR)/tmp_le.hex) $(BUILD_DIR)/tmp_le.hex > $(BUILD_DIR)/sw/$(TESTCASE).imem.hex
	head -$(shell wc -w < $(BUILD_DIR)/tmp_data_le.hex) $(BUILD_DIR)/tmp_data_le.hex > $(BUILD_DIR)/sw/$(TESTCASE).dmem.hex

dump: build_test hex_test trim
	$(OBJDUMP) $(BUILD_DIR)/sw/$(TESTCASE).elf -D > $(BUILD_DIR)/sw/$(TESTCASE).asm

cleanup:
	@rm -fr $(BUILD_DIR)/sw/*.o 
	@rm -fr $(BUILD_DIR)/tmp*
	@rm -fr $(BUILD_DIR)/tmp_data*

test: env build_test hex_test trim dump cleanup
