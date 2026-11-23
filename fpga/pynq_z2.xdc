## pynq_z2.xdc - pin constraints for top_kws on the PYNQ-Z2.
##
## Taken from the official PYNQ-Z2 master XDC, "PYNQ-Z2 v1.0.xdc", in TUL's archive
## pynq-z2_v1.0.xdc.zip (https://dpoauwgwqsy2x.cloudfront.net/Download/pynq-z2_v1.0.xdc.zip,
## linked from the PYNQ v3.1 documentation, "Board settings"; downloaded 2026-11-03,
## zip SHA-256 60e6d72e3fd9d8771da60567e038be2e69baf9a95290b627a4955aa89c3048f3).
## Only the pins top_kws uses are here, uncommented, with the port names of top_kws:
## btn[0] is called btn0. Everything else is as in the master file.

## Clock signal 125 MHz
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { sysclk }]; #IO_L13P_T2_MRCC_35 Sch=sysclk
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }];

## RGB LEDs: LD4 green = done, LD5 red = illegal instruction
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { led4_g }]; #IO_L16P_T2_35 Sch=led4_g
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led5_r }]; #IO_L23N_T3_35 Sch=led5_r

## LEDs: the KWS label, 0..11 in binary
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L6N_T0_VREF_34 Sch=led[0]
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L6P_T0_34 Sch=led[1]
set_property -dict { PACKAGE_PIN N16   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L21N_T3_DQS_AD14N_35 Sch=led[2]
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L23P_T3_35 Sch=led[3]

## Buttons: BTN0 = reset
set_property -dict { PACKAGE_PIN D19   IOSTANDARD LVCMOS33 } [get_ports { btn0 }]; #IO_L4P_T0_35 Sch=btn[0]

## Not in the master file. The core clock is the MMCM's output; Vivado derives it from
## sys_clk_pin. The button and the LEDs are slow and asynchronous: no timing on them.
set_false_path -from [get_ports btn0]
set_false_path -to [get_ports {led[*] led4_g led5_r}]
