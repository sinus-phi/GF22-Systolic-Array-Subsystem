######################################
# STM32 Nucleo-F411RE UART bridge
#
# Bridges:
#   USART1 PA9/PA10  <-> PYNQ-Z2 fabric UART
#   USART2 PA2/PA3   <-> ST-LINK Virtual COM Port
######################################

SHELL := bash

TOOLCHAIN ?= /home/sinus-phi/Xilinx/2025.2/gnu/aarch32/lin/gcc-arm-none-eabi/bin
CC := $(TOOLCHAIN)/arm-none-eabi-gcc
OBJCOPY := $(TOOLCHAIN)/arm-none-eabi-objcopy
SIZE := $(TOOLCHAIN)/arm-none-eabi-size

BUILD_DIR ?= ../../build/nucleo_uart_bridge
TARGET := nucleo_f411re_uart_bridge

CFLAGS := -mcpu=cortex-m4 -mthumb -O2 -g3 -ffunction-sections -fdata-sections -fno-builtin
CFLAGS += -Wall -Wextra -Werror -std=c11
LDFLAGS := -T linker.ld -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--build-id=none

.PHONY: all clean flash

all: $(BUILD_DIR)/$(TARGET).elf $(BUILD_DIR)/$(TARGET).bin

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/$(TARGET).elf: src/main.c linker.ld | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@
	$(SIZE) $@

$(BUILD_DIR)/$(TARGET).bin: $(BUILD_DIR)/$(TARGET).elf
	$(OBJCOPY) -O binary $< $@

flash: $(BUILD_DIR)/$(TARGET).elf
	openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
		-c "program $(BUILD_DIR)/$(TARGET).elf verify reset exit"

clean:
	rm -rf $(BUILD_DIR)
