# Visão Geral do Sistema

O elm_accel é um co-processador dedicado à inferência de uma rede neural Extreme Learning Machine (ELM) para classificação de dígitos manuscritos MNIST (0--9). O sistema é implementado em Verilog RTL e sintetizado para a FPGA Cyclone V da placa DE1-SoC.

A rede ELM recebe como entrada uma imagem 28×28 pixels em escala de cinza e retorna o dígito previsto (0..9). O processamento é sequencial --- um único bloco MAC reutilizado em loop --- o que minimiza o uso de recursos da FPGA às custas de latência (\~2 ms por imagem a 50 MHz).

## Hierarquia de Módulos

O sistema é composto por 10 módulos Verilog organizados em três camadas:

| **Camada** | **Módulo**                | **Função**                                                    |
|------------|---------------------------|---------------------------------------------------------------|
| Top-level  | top_demo.v                | Interface com a placa DE1-SoC (switches, LEDs, display 7-seg) |
| Top-level  | elm_accel.v               | Instancia e interconecta todos os submódulos                  |
| Controle   | reg_bank.v                | Decodifica MMIO --- interface ARM ↔ co-processador            |
| Controle   | fsm_ctrl.v                | Máquina de estados --- orquestra o cálculo                    |
| Datapath   | mac_unit.v                | Multiplicador-acumulador em Q4.12                             |
| Datapath   | pwl_activation.v          | Aproximação piecewise linear do tanh                          |
| Datapath   | argmax_block.v            | Comparador sequencial dos 10 scores                           |
| Memória    | ram_img.v                 | BRAM 784×8 bits --- pixels da imagem                          |
| Memória    | rom_pesos.v / rom_bias.v  | ROM dos pesos W_in e biases b                                 |
| Memória    | rom_beta.v / ram_hidden.v | ROM dos pesos β e RAM das ativações h[i]                    |

## Estimativa de Latência

Com arquitetura sequencial (1 MAC, pipeline de leitura+cálculo) a 50 MHz:

| **Estado**   | **Ciclos** | **Cálculo**                                                    |
|--------------|------------|----------------------------------------------------------------|
| LOAD_IMG     | 784        | 1 pixel por ciclo                                              |
| CALC_HIDDEN  | 100.736    | 128 neurônios × 787 ciclos (1 warmup + 784 MACs + 1 bias + 1 captura) |
| CALC_OUTPUT  | 1.300      | 10 classes × 130 ciclos (1 warmup + 128 MACs + 1 acumulação/captura) |
| ARGMAX       | 10         | 1 score por ciclo                                              |
| Overhead FSM | \~10       | Transições entre estados                                       |
| TOTAL        | \~102.840  |                                                                |

Tempo estimado a 50 MHz: 102.840 / 50.000.000 ≈ 2,06 ms por imagem.

Nota: cada MAC custa 1 ciclo efetivo graças ao pipeline --- enquanto a MAC processa o pixel atual, a FSM já apresenta o endereço do próximo pixel às BRAMs. O custo sem pipeline seria 2 ciclos por MAC, totalizando \~200k ciclos por imagem.

## Mapa de Registradores MMIO

Todos os registradores têm largura de 32 bits. O endereço base depende do Marco 2 (ponte HPS↔FPGA). No Marco 1, apenas os offsets são relevantes para o testbench.

| **Offset** | **Nome** | **Acesso** | **Bits relevantes** | **Semântica**                              |
|------------|----------|------------|---------------------|--------------------------------------------|
| 0x00       | CTRL     | W          | \[0\]=start         | Escrever 0x01: inicia inferência           |
| 0x00       | CTRL     | W          | \[1\]=reset         | Escrever 0x02: aborta e reinicia           |
| 0x04       | STATUS   | R          | \[1:0\]=estado      | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR        |
| 0x04       | STATUS   | R          | \[5:2\]=pred        | Dígito previsto (válido quando \[1:0\]=10) |
| 0x08       | IMG      | W          | \[9:0\]=addr        | Endereço do pixel (0..783)                 |
| 0x08       | IMG      | W          | \[17:10\]=dado      | Valor do pixel (0..255)                    |
| 0x0C       | RESULT   | R          | \[3:0\]=pred        | Dígito previsto em bits separados          |
| 0x10       | CYCLES   | R          | \[31:0\]=n          | Ciclos de clock da inferência              |
