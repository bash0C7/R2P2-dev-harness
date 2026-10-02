# PERIDOT-Air: CLOCK_50 (PIN_23) は 50MHz。osafune/peridot_air の fpga/air_blank_top/peridot_air.sdc から、
# このデザインが使うものだけ。
create_clock -period "50.000 MHz" [get_ports CLOCK_50]
derive_clock_uncertainty
set_false_path -from [get_ports RESET_N]
set_false_path -from [get_ports {D[*]}]
set_false_path -to [get_ports {USER_LED[*]}]
