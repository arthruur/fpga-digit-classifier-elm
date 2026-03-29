# Documentação Técnica: Módulo elm_accel (elm_accel.v)

**Top-Level do Co-processador ELM em FPGA**

## 1. Visão Geral

O módulo `elm_accel.v` é o topo da hierarquia do co-processador. Sua
responsabilidade é instanciar e interconectar todos os submódulos —
`reg_bank`, `fsm_ctrl`, `mac_unit`, `pwl_activation`, `argmax_block`,
`ram_img`, `rom_pesos`, `rom_bias`, `rom_beta` e `ram_hidden` — expondo
apenas o barramento MMIO de 32 bits para o HPS (Marco 2).

**Características principais:**

- Interface única com o exterior: barramento MMIO de 32 bits com 5
  registradores (CTRL, STATUS, IMG, RESULT, CYCLES).
- Todo o roteamento interno de dados é combinacional (muxes de fios),
  sem lógica sequencial adicional além dos submódulos.
- A conversão de pixel 8-bit para Q4.12 é realizada no top-level
  mediante deslocamento de bits, sem nenhum recurso lógico extra.

## 2. Interface do Módulo

| Porta | Direção | Largura | Descrição |
|:---|:---|:---|:---|
| clk | Entrada | 1 bit | Relógio do sistema |
| rst_n | Entrada | 1 bit | Reset assíncrono ativo-baixo |
| addr | Entrada | 32 bits | Endereço do registrador MMIO |
| write_en | Entrada | 1 bit | Habilitação de escrita do ARM |
| read_en | Entrada | 1 bit | Habilitação de leitura do ARM |
| data_in | Entrada | 32 bits | Dado escrito pelo ARM |
| data_out | Saída | 32 bits | Dado lido pelo ARM |

## 3. Mapa de Registradores MMIO

| Offset | Nome | Acesso | Campos | Semântica |
|:---|:---|:---|:---|:---|
| 0x00 | CTRL | W | bit[0]=start, bit[1]=reset | start pulsa 1 ciclo para iniciar inferência; reset aborta a FSM |
| 0x04 | STATUS | R | bits[1:0]=estado, bits[5:2]=pred | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR |
| 0x08 | IMG | W | bits[9:0]=pixel_addr, bits[17:10]=pixel_data | Carrega um pixel por escrita; we_img pulsa 1 ciclo |
| 0x0C | RESULT | R | bits[3:0]=pred | Dígito predito (0..9); válido quando STATUS=DONE |
| 0x10 | CYCLES | R | 32 bits | Ciclos de clock de LOAD_IMG até DONE; congela em DONE |

## 4. Arquitetura Interna

### 4.1. Conversão de Pixel para Q4.12

Os pixels armazenados em `ram_img` são inteiros de 8 bits (0..255). A
MAC opera em Q4.12 signed de 16 bits. A conversão é feita por
deslocamento:
```
pixel_q412 = {4'b0000, img_data, 4'b0000}
```

Isso equivale a `pixel × 16`, aproximando `pixel / 255 × 4096` com
erro máximo de 16 LSBs. Para os neurônios da ELM — cujos acumuladores
já saturam com pesos de magnitude elevada — esse desvio é irrelevante
para o argmax final.

| pixel | pixel_q412 | float equivalente |
|:---|:---|:---|
| 0 | 0x0000 | 0.000 |
| 128 | 0x0800 | 0.500 |
| 255 | 0x0FF0 | 0.996 |

### 4.2. Roteamento dos Muxes da MAC

A unidade MAC possui dois operandos (`mac_a`, `mac_b`) cujas fontes
variam conforme o estágio de cálculo. O roteamento é puramente
combinacional, controlado por dois sinais da FSM:

| Condição | mac_a | mac_b | Estágio |
|:---|:---|:---|:---|
| `bias_cycle = 1` | `bias_data` (b[i]) | `0x1000` (+1.0) | Ciclo de bias (CALC_HIDDEN) |
| `calc_output_active = 1`, `bias_cycle = 0` | `h_rdata` (h[i]) | `beta_data` (β[i][k]) | CALC_OUTPUT |
| default | `pixel_q412` (x[j]) | `weight_data` (W[i][j]) | CALC_HIDDEN (normal) |

O sinal `bias_cycle` tem prioridade sobre `calc_output_active`. A
invariante `mac_clr` e `mac_en` nunca simultâneos é garantida pela FSM
e não depende do top-level.

### 4.3. Endereçamento da ram_img

A `ram_img` é single-port e suas fases de escrita (ARM carrega pixels)
e leitura (FSM lê durante CALC_HIDDEN) são mutuamente exclusivas no
tempo. O mux de endereço é:
```
ram_img_addr = we_img_rb ? pixel_addr : addr_img
```

Escrita: controlada pelo ARM via `pixel_addr` (bits[9:0] do registrador
IMG). Leitura: controlada pela FSM via `addr_img` (contador j).

### 4.4. Buffer de Scores y[0..9]

A camada de saída calcula um score `y[k]` por vez durante CALC_OUTPUT.
Como o argmax precisa comparar todos os 10 scores, o top-level mantém
um banco de 10 registradores de 16 bits (`y_buf`) que captura cada
`acc_out` ao fim do cálculo de cada classe.

**Condição de captura:**
```
y_capture = mac_clr AND NOT we_hidden
```

O sinal `mac_clr` marca o fim de qualquer cálculo (HIDDEN ou OUTPUT).
O sinal `we_hidden = 0` distingue CALC_OUTPUT de CALC_HIDDEN, onde
`we_hidden = 1` ocorre no mesmo ciclo. O índice de destino é `k_out`,
fornecido pela FSM.

### 4.5. Controle do argmax_block

O `argmax_block` recebe um score por ciclo durante o estado ARGMAX. O
top-level gerencia dois aspectos:

**Pulso de start:** detectado pela borda de subida de `argmax_en`. O
bloco é resetado no primeiro ciclo de ARGMAX; a comparação começa no
ciclo seguinte.

**Contador argmax_k:** conta 0..9 durante os 10 ciclos de comparação,
endereçando `y_buf[argmax_k]` para apresentar os scores em sequência ao
`argmax_block`.
```
Ciclo 1 (argmax_en sobe): start=1, enable=0 → bloco reseta
Ciclo 2..11:              start=0, enable=1 → y_buf[0..9] comparados
Ciclo 11:                 done pulsa → max_idx válido
```

## 5. Hierarquia de Módulos
```
elm_accel (top-level)
├── reg_bank          — interface MMIO com o ARM
├── fsm_ctrl          — máquina de estados, contadores, sinais de controle
├── ram_img           — 784 × 8 bits, pixels da imagem
├── rom_pesos         — 131.072 × 16 bits, W_in em Q4.12 (layout padded)
├── rom_bias          — 128 × 16 bits, b em Q4.12
├── rom_beta          — 1.280 × 16 bits, β em Q4.12 (layout: n×10+c)
├── ram_hidden        — 128 × 16 bits, ativações h[i]
├── mac_unit          — multiplicador-acumulador Q4.12 signed
├── pwl_activation    — aproximação combinacional do tanh (PWL 5 segmentos)
└── argmax_block      — comparador sequencial, 10 ciclos
```

## 6. Fluxo de Dados por Estado da FSM

### LOAD_IMG (784 ciclos)

O ARM escreve os 784 pixels via registrador IMG antes do START. A FSM
em LOAD_IMG ativa `we_img_fsm` e incrementa `addr_img` a cada ciclo,
indexando a `ram_img` com o endereço correto. Na prática, a imagem já
está completamente carregada antes do START — o estado LOAD_IMG serve
para garantir que a FSM estabilize os sinais de controle das memórias.

### CALC_HIDDEN (128 × 787 = 100.736 ciclos)

Para cada neurônio i (0..127), a FSM percorre a seguinte sequência:

| Ciclo j | Fase | mac_en | mac_clr | bias_cycle | we_hidden |
|:---:|:---|:---:|:---:|:---:|:---:|
| 0 | Warmup (BRAM carregando) | 0 | 0 | 0 | 0 |
| 1..784 | Acumulação W[i][j-1]×x[j-1] | 1 | 0 | 0 | 0 |
| 785 | Bias: acc += b[i]×1.0 | 1 | 0 | 1 | 0 |
| 786 | Captura PWL(acc) em h[i] + Clear | 0 | 1 | 0 | 1 |

A saída combinacional da `pwl_activation` (`pwl_out`) é conectada
diretamente à entrada `data_in` da `ram_hidden`. Quando `we_hidden=1`,
o resultado `h[i]` é gravado em `ram_hidden[i]`.

### CALC_OUTPUT (10 × 130 = 1.300 ciclos)

Para cada classe k (0..9), a FSM percorre:

| Ciclo i | Fase | mac_en | mac_clr |
|:---:|:---|:---:|:---:|
| 0 | Warmup | 0 | 0 |
| 1..128 | Acumulação β[i-1][k]×h[i-1] | 1 | 0 |
| 129 | Captura y[k] em y_buf[k] + Clear | 0 | 1 |

A captura de `y[k]` ocorre no top-level via `y_capture`, não dentro da
FSM. O sinal `k_out` indexa `y_buf` para que o valor correto seja
salvo.

### ARGMAX (10 ciclos)

O top-level apresenta `y_buf[0]` a `y_buf[9]` ao `argmax_block` em 10
ciclos consecutivos. O bloco compara em aritmética signed e retorna
`max_idx` quando `done` pulsa.

### DONE (1 ciclo)

`result_out` e `done_out` são disponibilizados. O registrador RESULT
pode ser lido pelo ARM. A FSM retorna automaticamente a IDLE no ciclo
seguinte.

## 7. Latência Total de Inferência

| Estado | Ciclos |
|:---|:---|
| LOAD_IMG | 784 |
| CALC_HIDDEN | 100.736 |
| CALC_OUTPUT | 1.300 |
| ARGMAX | 10 |
| **Total** | **102.830** |

A 50 MHz: 102.830 × 20 ns ≈ **2,06 ms por inferência**.

Esse valor foi confirmado pelo campo CYCLES lido via MMIO na simulação
end-to-end (`tb_elm_accel.v`).




















