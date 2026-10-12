# SPDX-License-Identifier: MIT
# Arty A7 Rev D/E board pins verified against Digilent/digilent-xdc commit
# 00a3404901f35aa9567b01ecb3f2c233b6efe9f4, Arty-A7-35-Master.xdc.
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk_100mhz]
create_clock -name board_100 -period 10.000 [get_ports clk_100mhz]
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports reset_button]
set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports test_switch]
set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# Fixed onboard DP83848J MII wiring.
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports eth_ref_clk]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports eth_reset_n]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports eth_tx_clk]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports eth_rx_clk]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports eth_tx_en]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports eth_rx_dv]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports eth_rx_er]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports eth_mdc]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports eth_mdio]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {eth_txd[3]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[3]}]
set_property PULLUP TRUE [get_ports eth_mdio]
create_clock -name mii_tx -period 40.000 [get_ports eth_tx_clk]
create_clock -name mii_rx -period 40.000 [get_ports eth_rx_clk]
# TI SNLS250E: 100M TX setup 10 ns, hold 0 ns; RX delay 10..30 ns.
set_output_delay -clock mii_tx -max 10.0 [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock mii_tx -min 0.0 [get_ports {eth_txd[*] eth_tx_en}]
set_input_delay -clock mii_rx -max 30.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rx_er}]
set_input_delay -clock mii_rx -min 10.0 [get_ports {eth_rxd[*] eth_rx_dv eth_rx_er}]

# Placeholder external ADC mapping: D[7:0] on JA, D[11:8] on JB pins 1..4,
# OTR on JB pin 7, clock output on JB pin 8. Change this section for your cable.
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports {adc_data[0]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {adc_data[1]}]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports {adc_data[2]}]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports {adc_data[3]}]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports {adc_data[4]}]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports {adc_data[5]}]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports {adc_data[6]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {adc_data[7]}]
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports {adc_data[8]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {adc_data[9]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {adc_data[10]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {adc_data[11]}]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports adc_otr]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports adc_clk]
create_generated_clock -name adc_external -source [get_pins adc_clock_output/C] -divide_by 1 [get_ports adc_clk]
# AD9226 Rev B: 3.5..7 ns output delay. Provisional PCB/cable round-trip
# budget is 0.5..1.5 ns. Replace these assumptions with measured/layout values.
set_input_delay -clock adc_external -max 8.5 [get_ports {adc_data[*] adc_otr}]
set_input_delay -clock adc_external -min 4.0 [get_ports {adc_data[*] adc_otr}]

# PHY reference is a forwarded clock, not an unconstrained data output.
create_generated_clock -name phy_external -source [get_pins phy_clock_output/C] -divide_by 1 [get_ports eth_ref_clk]
# MDC pauses between transactions: it is not a continuously divided clock.
# The FSM changes MDIO on falling MDC and the PHY samples 500 ns later.
# Bound both management output datapaths to 40 ns (including tristate enable);
# worst-case relative output delay 40 ns leaves >=460 ns for the PHY's
# 10 ns setup/hold requirements. Keep minimum-delay checks as well.
set_output_delay -clock board_100 -max 0.0 [get_ports {eth_mdc eth_mdio}]
set_output_delay -clock board_100 -min 0.0 [get_ports {eth_mdc eth_mdio}]
# The datapath limit is applied in cdc.tcl after MMCM clocks are available.
set_output_delay -clock board_100 -max 0.0 [get_ports {eth_reset_n led[*]}]
set_output_delay -clock board_100 -min 0.0 [get_ports {eth_reset_n led[*]}]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
