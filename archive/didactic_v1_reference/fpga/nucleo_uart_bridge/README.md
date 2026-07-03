# Nucleo F411RE UART Bridge

This firmware turns the STM32 Nucleo-F411RE into a simple UART bridge for the
local PYNQ-Z2 bring-up setup.

## Wiring

- PYNQ-Z2 Arduino `D5` / RTL `uart_tx` -> Nucleo Arduino `D2` / PA10 / USART1_RX
- Nucleo Arduino `D8` / PA9 / USART1_TX -> PYNQ-Z2 Arduino `D6` / RTL `uart_rx`
- PYNQ-Z2 `GND` -> Nucleo `GND`
- Nucleo ST-LINK USB -> PC. This exposes `/dev/ttyACM0`.

No extra jumper wire is needed between Nucleo USART2 and ST-LINK VCP; it is
handled on the board by the default ST-LINK connection.

## Build

```bash
cd /home/sinus-phi/Documents/LAB_AI_SS26/fpga/nucleo_uart_bridge
make
```

## Flash

```bash
make flash
```

## Monitor

```bash
stty -F /dev/ttyACM0 9600 cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo
cat /dev/ttyACM0
```

Expected startup banner:

```text
NUCLEO-F411RE UART bridge ready @9600 8N1
USART1 PA10(D2)=PYNQ_TX, PA9(D8)=PYNQ_RX
```
