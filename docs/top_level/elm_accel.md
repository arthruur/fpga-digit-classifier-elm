# Documentação Técnica: Módulo elm_accel (elm_accel.v)

**Top-Level do Co-processador ELM**

**Projeto:** elm_accel — Co-processador ELM em FPGA  
**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1  
**Marco:** 1 / Fase 5

---

## 1. Visão Geral

O módulo `elm_accel.v` é o top-level do co-processador. Sua
responsabilidade é instanciar e interconectar todos os submódulos —
`reg_bank`, `fsm_ctrl`, `mac_unit`, `pwl_activation`, `argmax_block`,
`ram_img`, `rom_pesos`, `rom_bias`, `rom_beta` e `ram_hidden` — expondo
apenas o barramento MMIO de 32 bits para o agente externo (HPS ou
`top_demo`).

**Características principais:**

- Interface única com o exterior: barramento MMIO de 32 bits com 5
  registradores (CTRL, STATUS, IMG, RESULT, CYCLES).
- Todo o roteamento interno de dados é combinacional (muxes de fios),
  sem lógica sequencial adicional além dos submódulos.
- A conversão de pixel 8-bit para Q4.12 é realizada por deslocamento de
  bits, sem nenhum recurso lógico extra.
- Dois parâmetros configuram o comportamento para o modo demo standalone
  (`INIT_FILE` e `PRELOADED_IMG`).

---

## 2. Interface do Módulo

### 2.1. Parâmetros

| Parâmetro      | Padrão | Descrição |
|:---------------|:-------|:----------|
| INIT_FILE      | `""`   | Arquivo HEX/MIF para pré-inicializar a `ram_img` em síntese. Passado diretamente para `ram_img`. `""` = sem pré-carregamento (modo normal). |
| PRELOADED_IMG  | 0      | Quando 1, a FSM pula o estado LOAD_IMG e vai direto a CALC_HIDDEN. Passado diretamente para `fsm_ctrl`. Usar junto com `INIT_FILE` quando a imagem já está na `ram_img` desde o boot. |

No uso atual pelo `top_demo`, ambos os parâmetros ficam no valor padrão
— o `top_demo` carrega os pixels via MMIO antes de disparar o START.

### 2.2. Portas

| Porta    | Direção | Largura  | Descrição                        |
|:---------|:--------|:---------|:---------------------------------|
| clk      | Entrada | 1 bit    | Relógio do sistema               |
| rst_n    | Entrada | 1 bit    | Reset assíncrono ativo-baixo     |
| addr     | Entrada | 32 bits  | Endereço do registrador MMIO     |
| write_en | Entrada | 1 bit    | Habilitação de escrita           |
| read_en  | Entrada | 1 bit    | Habilitação de leitura           |
| data_in  | Entrada | 32 bits  | Dado escrito pelo agente externo |
| data_out | Saída   | 32 bits  | Dado lido pelo agente externo    |

---

## 3. Mapa de Registradores MMIO

| Offset | Nome   | Acesso | Campos                           | Semântica                                    |
|:-------|:-------|:-------|:---------------------------------|:---------------------------------------------|
| 0x00   | CTRL   | W      | bit[0]=start, bit[1]=reset       | start=1 inicia inferência; reset=1 aborta    |
| 0x04   | STATUS | R      | bits[1:0]=estado, bits[5:2]=pred | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR          |
| 0x08   | IMG    | W      | bits[9:0]=addr, bits[17:10]=dado | Carrega um pixel por escrita                 |
| 0x0C   | RESULT | R      | bits[3:0]=pred                   | Dígito predito (0..9); válido quando DONE    |
| 0x10   | CYCLES | R      | bits[31:0]                       | Ciclos de LOAD_IMG até DONE; congela em DONE |

---

## 4. Arquitetura Interna

O `elm_accel` não contém lógica de controle própria além de três
elementos sequenciais locais: o buffer de scores `y_buf`, o registrador
de detecção de borda `argmax_en_prev` e o contador `argmax_k`. Toda a
orquestração é feita pela `fsm_ctrl`.

### 4.1. Conversão de Pixel para Q4.12

Os pixels armazenados em `ram_img` são inteiros de 8 bits (0..255). A
conversão para Q4.12 é feita por concatenação de bits — equivalente a
um shift de 4 posições à esquerda, implementado apenas com roteamento
de fios (zero lógica, zero ciclos):

```verilog
wire [15:0] pixel_q412 = {4'b0000, img_data, 4'b0000};
```

| pixel | pixel_q412 | Valor float |
|:------|:-----------|:------------|
| 0     | 0x0000     | 0.000       |
| 128   | 0x0800     | 0.500       |
| 255   | 0x0FF0     | 0.996       |

### 4.2. Mux de Entradas da MAC

A MAC compartilhada recebe operandos de fontes diferentes dependendo do
estado da FSM. O roteamento é puramente combinacional, controlado por
dois sinais da FSM com a seguinte prioridade:

| Condição                          | mac_a      | mac_b      | Fase              |
|:----------------------------------|:-----------|:-----------|:------------------|
| `bias_cycle=1`                    | bias_data  | 0x1000     | Bias (CALC_HIDDEN)|
| `calc_output_active=1`, bias=0    | h_rdata    | beta_data  | CALC_OUTPUT       |
| default                           | pixel_q412 | weight_data| CALC_HIDDEN normal|

`bias_cycle` tem prioridade porque dentro de CALC_HIDDEN ele precisa
sobrepor o roteamento padrão no ciclo j=N_PIXELS+1.

### 4.3. Mux de Endereço da ram_img

A `ram_img` é single-port — leitura e escrita compartilham o mesmo
barramento de endereço. O mux seleciona a fonte com base em `we_img_rb`:

```verilog
wire [9:0] ram_img_addr = we_img_rb ? pixel_addr : addr_img;
```

Quando `we_img_rb=1` o agente externo controla o endereço para escrita.
Quando `we_img_rb=0` a FSM controla o endereço para leitura durante
CALC_HIDDEN. As duas fases são mutuamente exclusivas no tempo.

### 4.4. Buffer de Scores y_buf

Durante CALC_OUTPUT, cada score `y[k]` calculado pela MAC precisa ser
retido para que o argmax_block possa comparar todos os 10 valores. O
top-level mantém um banco de 10 registradores de 16 bits que captura
`acc_out` ao fim de cada classe:

```verilog
wire y_capture = mac_clr && !we_hidden;
// mac_clr=1 marca fim de cálculo (hidden ou output)
// we_hidden=0 distingue CALC_OUTPUT de CALC_HIDDEN
```

Quando `y_capture` está ativo, `acc_out` é copiado para `y_buf[k_out]`,
onde `k_out` é o índice de classe fornecido pela FSM. O acc_out ainda
reflete o valor correto nesse ciclo porque o `mac_clr` só efetiva o
zero no acumulador na borda de clock seguinte.

### 4.5. Controle do argmax_block

O `argmax_block` recebe um score por ciclo durante o estado ARGMAX. O
top-level gerencia a sequência de 11 ciclos:

```
Ciclo 1 (argmax_en sobe): argmax_start_pulse=1, argmax_enable=0
                           → bloco reseta, argmax_k=0
Ciclos 2..11:              argmax_start_pulse=0, argmax_enable=1
                           → y_buf[0..9] comparados em sequência
Ciclo 11:                  done pulsa → max_idx válido
```

A detecção da borda de subida de `argmax_en` é feita com um registrador
de delay de 1 ciclo (`argmax_en_prev`), garantindo que o pulso de start
seja gerado automaticamente na transição para o estado ARGMAX.

---

## 5. Hierarquia de Módulos

```
elm_accel (top-level)
├── reg_bank          — interface MMIO com o agente externo (5 registradores)
├── fsm_ctrl          — FSM de 7 estados, contadores i/j/k, sinais de controle
├── ram_img           — 784 × 8 bits, pixels da imagem (single-port)
├── rom_pesos         — 131.072 × 16 bits, W_in em Q4.12 (layout padded)
├── rom_bias          — 128 × 16 bits, b em Q4.12
├── rom_beta          — 1.280 × 16 bits, β em Q4.12 (layout: k×128+i)
├── ram_hidden        — 128 × 16 bits, ativações h[i]
├── mac_unit          — multiplicador-acumulador Q4.12 signed
├── pwl_activation    — aproximação combinacional do tanh (PWL 5 segmentos)
└── argmax_block      — comparador sequencial signed, 10 ciclos
```

---

## 6. Fluxo de Dados por Estado da FSM

### LOAD_IMG (784 ciclos)

O agente externo escreve os 784 pixels via registrador IMG antes do
START. A FSM em LOAD_IMG ativa `we_img_fsm` e incrementa `addr_img` a
cada ciclo. Na prática a imagem já está carregada antes do START —
LOAD_IMG serve para estabilizar os sinais de controle das memórias.

Quando `PRELOADED_IMG=1` este estado é pulado inteiramente.

### CALC_HIDDEN (128 × 787 = 100.736 ciclos)

Para cada neurônio i (0..127):

| Ciclo j      | Fase          | mac_en | mac_clr | bias_cycle | we_hidden |
|:---:         |:---           |:---:   |:---:    |:---:       |:---:      |
| 0            | Warmup        | 0      | 0       | 0          | 0         |
| 1..784       | Acumulação    | 1      | 0       | 0          | 0         |
| 785          | Bias          | 1      | 0       | 1          | 0         |
| 786          | Captura+Clear | 0      | 1       | 0          | 1         |

No ciclo 786, `acc_out` (combinacional) ainda reflete `W[i]·x + b[i]`.
A PWL calcula `pwl_out = tanh_aprox(acc_out)` instantaneamente e a
`ram_hidden` grava `h[i]`. Na borda de clock, o acumulador zera.

### CALC_OUTPUT (10 × 130 = 1.300 ciclos)

Para cada classe k (0..9):

| Ciclo i      | Fase          | mac_en | mac_clr |
|:---:         |:---           |:---:   |:---:    |
| 0            | Warmup        | 0      | 0       |
| 1..128       | Acumulação    | 1      | 0       |
| 129          | Captura+Clear | 0      | 1       |

Não há ciclo de bias — a camada de saída é linear. A captura de `y[k]`
ocorre via `y_capture` no top-level, não dentro da FSM.

### ARGMAX (11 ciclos)

Ciclo 1: `argmax_start_pulse=1` — bloco reseta.
Ciclos 2..11: `argmax_enable=1` — `y_buf[0..9]` apresentados em
sequência. Ao fim, `done` pulsa e `max_idx` contém o resultado.

### DONE (1 ciclo)

`result_out` e `done_out` ficam disponíveis. O registrador RESULT pode
ser lido. A FSM retorna ao IDLE no ciclo seguinte.

---

## 7. Latência Total de Inferência

| Estado      | Ciclos                            |
|:------------|:----------------------------------|
| LOAD_IMG    | 784 (0 quando PRELOADED_IMG=1)    |
| CALC_HIDDEN | 100.736 (128 × 787)               |
| CALC_OUTPUT | 1.300 (10 × 130)                  |
| ARGMAX      | 11                                |
| **Total**   | **≈ 102.831**                     |

A 50 MHz: **≈ 2,06 ms por inferência**.

O valor medido na simulação end-to-end (`tb_elm_accel.v`) foi
**CYCLES = 102.832** — diferença de 1 ciclo relativa ao overhead de
transição entre estados.
