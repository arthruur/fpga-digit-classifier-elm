# elm_accel.sdc — Constraints de timing para DE1-SoC
# Clock alvo: 50 MHz (período 20 ns)

create_clock -name clk -period 20.000 [get_ports CLOCK_50]

# Relaxar entradas/saídas do barramento MMIO
# (interface com HPS via software — sem timing crítico)
set_input_delay  -clock clk -max 5.0 [get_ports {addr[*] data_in[*] write_en read_en rst_n}]
set_output_delay -clock clk -max 5.0 [get_ports {data_out[*]}]

# Corte de caminho para reset assíncrono (padrão)
set_false_path -from [get_ports rst_n]
