# PYNQ-Z2 constraints for the local FT232H + Nucleo F411RE setup.
#
# This PMOD-free variant maps the Didactic SoC fabric JTAG and UART to the
# PYNQ-Z2 Arduino/Raspberry-Pi style general IO headers, matching the physical
# style of the course PYNQ-Z1 guide more closely than the PMOD-based variant.

##############
# Timing
##############

## PYNQ-Z2 PL reference clock: 125 MHz on H16.
create_clock -period 8.000 -name global_clk -waveform {0.000 4.000} -add [get_ports clk_in]

## External FT232H JTAG clock.
create_clock -period 125.000 -name jtag_clk -waveform {0.000 62.500} -add [get_ports jtag_tck]
set_input_jitter jtag_clk 1.000

## JTAG specifics
set_input_delay -clock jtag_clk -clock_fall 5.000 [get_ports jtag_tdi]
set_input_delay -clock jtag_clk -clock_fall 5.000 [get_ports jtag_tms]
set_output_delay -clock jtag_clk 5.000 [get_ports jtag_tdo]

set_max_delay -to [get_ports jtag_tdo] 20.000
set_max_delay -from [get_ports jtag_tms] 20.000
set_max_delay -from [get_ports jtag_tdi] 20.000

## Reset and asynchronous external IO
set_false_path -from [get_ports reset]
set_false_path -from [get_ports jtag_trst]
set_false_path -from [get_ports uart_rx]
set_false_path -from [get_ports gpio]
set_false_path -to [get_ports uart_tx]

## Clock crossing characteristics
set_clock_groups -logically_exclusive -group [get_clocks -include_generated_clocks global_clk] -group [get_clocks jtag_clk]

##################
# Board IO
##################

## CLK
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_in]

## RESET: PYNQ-Z2 SW0
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports reset]
## v2 routes the external reset through a BUFG-based reset tree. SW0 is not a
## clock-capable IO, so demote the dedicated clock-route DRC for this reset net.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets didactic/i_system_control/i_io_cell_frame/i_io_cell_rst/TO_CORE]

## JTAG: PYNQ-Z2 general IO headers for FT232H MPSSE.
## Raspberry Pi header pin labeled Y7 in the PYNQ-Z2 layout <- FT232H AD0 / ADBUS0 / TCK
## TCK must use a clock-capable IO path because the Didactic JTAG TAP feeds BUFGs.
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports jtag_tck]
## Arduino D1 / AR1 / U12 <- FT232H AD1 / ADBUS1 / TDI
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports jtag_tdi]
## Arduino D2 / AR2 / U13 -> FT232H AD2 / ADBUS2 / TDO input
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports jtag_tdo]
## Arduino D3 / AR3 / V13 <- FT232H AD3 / ADBUS3 / TMS
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports jtag_tms]
## Arduino D4 / AR4 / V15 <- FT232H AD7 / ADBUS7, held high by layout_init.
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports jtag_trst]
set_property PULLUP true [get_ports jtag_trst]

## UART: PYNQ-Z2 Arduino digital header for the Nucleo UART bridge.
## Arduino D5 / AR5 / T15 -> Nucleo Arduino D2 / USART1_RX
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports uart_tx]
## Arduino D6 / AR6 / R16 <- Nucleo Arduino D8 / USART1_TX
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports uart_rx]

## SPI: Arduino SPI header plus adjacent Arduino digital pins.
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports spi_sck]
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports {spi_data[0]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {spi_data[1]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {spi_data[2]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {spi_data[3]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {spi_csn[0]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {spi_csn[1]}]

## GPIO: remaining Arduino digital pins plus Raspberry-Pi header pins.
## The mapping is only to satisfy top-level IO constraints during bring-up.
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {gpio[0]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {gpio[1]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {gpio[2]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {gpio[3]}]
set_property -dict {PACKAGE_PIN Y11 IOSTANDARD LVCMOS33} [get_ports {gpio[4]}]
set_property -dict {PACKAGE_PIN Y12 IOSTANDARD LVCMOS33} [get_ports {gpio[5]}]
set_property -dict {PACKAGE_PIN W11 IOSTANDARD LVCMOS33} [get_ports {gpio[6]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {gpio[7]}]
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33} [get_ports {gpio[8]}]
set_property -dict {PACKAGE_PIN U10 IOSTANDARD LVCMOS33} [get_ports {gpio[9]}]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports {gpio[10]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports {gpio[11]}]
set_property -dict {PACKAGE_PIN V8  IOSTANDARD LVCMOS33} [get_ports {gpio[12]}]
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS33} [get_ports {gpio[13]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports {gpio[14]}]
set_property -dict {PACKAGE_PIN W8  IOSTANDARD LVCMOS33} [get_ports {gpio[15]}]
