####
# Didactic SoC 
# Baremetal controller SW flow makefile
# Contributor(s):
#   -Matti Käyrä (matti.kayra@tuni.fi)
###

TESTCASE ?= blinky
START_TIME=`date +%F_%H:%M`
SHELL = bash
BUILD_DIR ?= ../../build/fpga
CC=riscv64-unknown-elf-gcc
RISCV_ARCH ?= rv32imc_zicsr
OPT ?= -Os
CFLAGS=-mabi=ilp32 $(OPT) -g -ffunction-sections -fdata-sections -Icommon/
LDFLAGS ?= -Wl,--build-id=none
ELF2HEX_BIN ?= riscv32-unknown-elf-elf2hex

test: env build_test

env:
	mkdir -p $(BUILD_DIR)/sw
	echo "prerequisite: local install of RISCV32 toolchain + elf2hex"

build_test:
	$(CC) -march=$(RISCV_ARCH) -D__riscv__ $(CFLAGS) -c $(TESTCASE)/$(TESTCASE).c -o $(BUILD_DIR)/sw/$(TESTCASE).o 
	$(CC) -march=$(RISCV_ARCH) -D__riscv__ $(CFLAGS) -DLANGUAGE_ASSEBMLY -c common/crt0.S -o $(BUILD_DIR)/sw/crt0.o
	$(CC) -march=$(RISCV_ARCH) -Tcommon/link.ld $(BUILD_DIR)/sw/$(TESTCASE).o $(BUILD_DIR)/sw/crt0.o -nostartfiles -nostdlib -Wl,--gc-sections $(LDFLAGS) -o $(BUILD_DIR)/sw/$(TESTCASE).elf

#hex_test:
#	$(ELF2HEX_BIN) --bit-width 32 --input $(BUILD_DIR)/sw/$(TESTCASE).elf --output $(BUILD_DIR)/sw/$(TESTCASE).hex
