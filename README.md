# elm_accel — Co-processador ELM em FPGA

**TEC 499 · MI Sistemas Digitais · UEFS 2026.1**

Implementação de um acelerador de hardware em FPGA para inferência de uma rede neural
Extreme Learning Machine (ELM) aplicada à classificação de dígitos manuscritos do conjunto
MNIST. O co-processador é descrito em Verilog RTL e sintetizado para a plataforma DE1-SoC
(Cyclone V FPGA).

**Repositório:** https://github.com/arthruur/fpga-digit-classifier-elm

**Equipe:** Arthur Teles de Oliveira Freitas · Davi Zardo Motté · Gustavo Silva Ribeiro

---

## Sumário

1. [Levantamento de Requisitos](#1-levantamento-de-requisitos)
2. [Softwares Utilizados](#2-softwares-utilizados)
3. [Hardware Utilizado](#3-hardware-utilizado)
4. [Instalação e Configuração do Ambiente](#4-instalação-e-configuração-do-ambiente)
5. [Arquitetura da Solução](#5-arquitetura-da-solução)
6. [Testes de Funcionamento](#6-testes-de-funcionamento)
7. [Análise dos Resultados](#7-análise-dos-resultados)
8. [Uso de Recursos FPGA](#8-uso-de-recursos-fpga)

---

## 1. Levantamento de Requisitos

### 1.1 Requisitos Funcionais

| ID | Requisito |
|----|-----------|
| RF-01 | Implementar inferência ELM com os pesos fornecidos pelo professor |
| RF-02 | Processar imagens MNIST 28×28 pixels em escala de cinza (784 bytes) |
| RF-03 | Executar camada oculta com 128 neurônios e ativação aproximada do tanh |
| RF-04 | Executar camada de saída linear com 10 classes (dígitos 0–9) |
| RF-05 | Retornar a predição via argmax dos 10 scores de saída |
| RF-06 | Expor interface MMIO com 8 registradores de 32 bits (CTRL, STATUS, IMG, RESULT, CYCLES, WEIGHTS_DATA, BIAS_DATA, BETA_DATA) |
| RF-07 | Suportar a ISA completa: STORE_IMG, STORE_WEIGHTS, STORE_BIAS, STORE_BETA, START e leitura de STATUS/RESULT |
| RF-08 | Demonstrar inferência standalone na DE1-SoC via switches, botões e displays de 7 segmentos |

### 1.2 Requisitos Não Funcionais

| ID | Requisito |
|----|-----------|
| RNF-01 | Aritmética em ponto fixo Q4.12 (16 bits, signed) |
| RNF-02 | Arquitetura sequencial com FSM de controle e MAC compartilhada |
| RNF-03 | Função de ativação implementada sem ROM (lógica combinacional PWL) |
| RNF-04 | Parâmetros da rede armazenados em RAMs inicializadas via `$readmemh` para o Marco 1; reescrita em runtime via MMIO disponível para o Marco 2 |
| RNF-05 | Simulação RTL validada com golden model Python antes da síntese |
| RNF-06 | Código RTL sintetizável no Quartus Prime Lite para Cyclone V (DE1-SoC) |
| RNF-07 | Tempo de inferência inferior a 1 minuto |
| RNF-08 | Timing fechado a 50 MHz (slack positivo após correção do reg_bank) |

### 1.3 Mapa de Registradores MMIO

Endereço base: `0xFF200000` (Lightweight HPS-to-FPGA bridge)

| Offset | Registrador | Acesso | Campos | Semântica |
|--------|-------------|--------|--------|-----------|
| 0x00 | CTRL | W | bit[0]=start, bit[1]=reset | start=1 inicia inferência; reset=1 aborta e reseta ponteiros |
| 0x04 | STATUS | R | bits[1:0]=estado, bits[5:2]=pred | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR |
| 0x08 | IMG | W | bits[9:0]=addr, bits[17:10]=dado | STORE_IMG: carrega um pixel por escrita |
| 0x0C | RESULT | R | bits[3:0]=pred | Dígito predito (0..9), válido em DONE |
| 0x10 | CYCLES | R | 32 bits | Ciclos de LOAD_IMG até DONE |
| 0x14 | WEIGHTS_DATA | W | bits[15:0]=peso Q4.12 | STORE_WEIGHTS: ponteiro auto-incremental W[0][0]..W[127][783] |
| 0x18 | BIAS_DATA | W | bits[15:0]=bias Q4.12 | STORE_BIAS: ponteiro auto-incremental b[0]..b[127] |
| 0x1C | BETA_DATA | W | bits[15:0]=peso Q4.12 | STORE_BETA: ponteiro auto-incremental β[0][0]..β[127][9] |

#### Ponteiros auto-incrementais (STORE_*)

O ARM não precisa especificar endereços — escreve os dados em sequência e o `reg_bank` mantém ponteiros internos que avançam automaticamente a cada write.

| Instrução | Ponteiro | Total de writes | Saturação | Reset |
|-----------|----------|-----------------|-----------|-------|
| STORE_WEIGHTS | dual-counter {neuron[6:0], pixel[9:0]} | 100.352 | Após W[127][783] | CTRL bit[1]=1 |
| STORE_BIAS | linear b_ptr[6:0] | 128 | Após b[127] | CTRL bit[1]=1 |
| STORE_BETA | linear beta_ptr[10:0] | 1.280 | Após β[127][9] | CTRL bit[1]=1 |

---

## 2. Softwares Utilizados

| Software | Versão | Finalidade |
|----------|--------|------------|
| Quartus Prime Lite | 25.1std.0 Build 1129 (21/10/2025) | Síntese, place-and-route, análise de timing |
| Icarus Verilog | 12.0 (devel) s20150603-1539-g2693dd32b | Compilação e simulação RTL |
| GTKWave | — | Visualização de waveforms (.vcd) |
| Python | 3.13.7 | Golden model, scripts de conversão e geração de HEX |
| Pillow (PIL) | — | Leitura e redimensionamento de imagens PNG |
| NumPy | — | Geração dos arquivos HEX de pesos a partir do modelo treinado |
| Git | — | Controle de versão |

### Dependências Python

```bash
pip install numpy pillow
```

---

## 3. Hardware Utilizado

| Hardware | Especificação |
|----------|---------------|
| Plataforma | Terasic DE1-SoC |
| FPGA | Intel Cyclone V SoC — 5CSEMA5F31C6 |
| Processador | ARM Cortex-A9 dual-core (HPS) @ 800 MHz |
| Memória FPGA | 4.065.280 bits M10K (397 blocos) |
| Lógica FPGA | 32.070 ALMs |
| DSP blocks | 87 |
| Clock FPGA | 50 MHz (oscilador de placa) |
| Conexão HPS↔FPGA | Lightweight AXI bridge @ 0xFF200000 |

---

## 4. Instalação e Configuração do Ambiente

### 4.1 Clonar o repositório

```bash
git clone https://github.com/arthruur/fpga-digit-classifier-elm.git
cd fpga-digit-classifier-elm
```

### 4.2 Estrutura de pastas

```
fpga-digit-classifier-elm/
├── rtl/
│   ├── top_demo.v               # Top-level demo standalone (DE1-SoC)
│   ├── elm_accel.v              # Top-level do co-processador (MMIO)
│   ├── fsm_regbank/
│   │   ├── fsm_ctrl.v           # FSM de controle (7 estados)
│   │   ├── reg_bank.v           # Banco de registradores MMIO (8 registradores)
│   │   ├── tb_fsm_ctrl.v
│   │   └── tb_reg_bank.v
│   ├── datapath/
│   │   ├── mac_unit.v           # Multiplicador-acumulador Q4.12 com saturação
│   │   ├── pwl_activation.v     # PWL tanh — lógica combinacional, 5 segmentos
│   │   ├── pwl_sigmoid.v        # PWL sigmóide — lógica combinacional, 4 segmentos
│   │   ├── argmax_block.v
│   │   ├── tb_mac.v
│   │   ├── tb_pwl_activation.v
│   │   ├── tb_argmax_block.v
│   │   └── tb_datapath.v
│   ├── memory/
│   │   ├── ram_img.v            # BRAM de imagem (behavioral e altsyncram)
│   │   ├── ram_pesos.v          # RAM W_in — $readmemh (Marco 1) + STORE_WEIGHTS (Marco 2)
│   │   ├── ram_bias.v           # RAM b   — $readmemh (Marco 1) + STORE_BIAS (Marco 2)
│   │   ├── ram_beta.v           # RAM β   — $readmemh (Marco 1) + STORE_BETA (Marco 2)
│   │   ├── ram_hidden.v
│   │   └── tb_ram_*.v
│   └── tb/
│       ├── tb_elm_accel.v           # Integração end-to-end ($readmemh direto)
│       ├── tb_store_instructions.v  # Validação isolada das instruções STORE_*
│       └── tb_full_flow.v           # Fluxo completo: STORE_* via MMIO + inferência
├── model/
│   ├── model_elm_q.npz          # Pesos treinados em Q4.12
│   ├── elm_golden.py            # Golden model Python (Q4.12 RTL-exact)
│   ├── conv.py                  # Conversor PNG → HEX ($readmemh)
│   ├── gen_hex.py               # Gera w_in.hex, bias.hex, beta.hex dos pesos
│   ├── gen_all_digits.py        # Gera digit_0.hex..digit_9.hex para o top_demo
│   └── test/                    # Imagens MNIST por dígito (0..9)
├── sim/                         # Arquivos HEX para simulação e síntese
│   ├── w_in.hex
│   ├── bias.hex
│   ├── beta.hex
│   ├── img_test.hex
│   ├── pred_ref.hex
│   └── digit_0.hex .. digit_9.hex
├── quartus/
│   ├── elm_accel.qpf
│   ├── elm_accel.qsf
│   └── elm_accel.sdc
└── docs/
    ├── top_level/
    ├── datapath/
    ├── memory/
    ├── fsm_regbank/
    └── tests/
```

### 4.3 Gerar os arquivos HEX dos pesos

```bash
cd model
python gen_hex.py --model model_elm_q.npz --outdir ../sim
```

Arquivos gerados em `sim/`:

| Arquivo | Linhas | Conteúdo |
|---------|--------|----------|
| `w_in.hex` | 131.072 | Pesos W_in em Q4.12, layout padded (neuron×1024+pixel) |
| `bias.hex` | 128 | Biases b em Q4.12 |
| `beta.hex` | 1.280 | Pesos β em Q4.12, layout hidden-major (hidden×10+class) |

Os arquivos `sim/*.hex` servem para dois fins:

- **Síntese (Marco 1):** o Quartus lê os arquivos via `$readmemh` no bloco `initial` das RAMs, gravando os parâmetros no bitstream. O sistema funciona desde a energização sem software.
- **Simulação e runtime (Marco 2):** os testbenches leem os arquivos para arrays temporários e enviam via MMIO. O driver Linux faz o mesmo para carregar um modelo diferente sem reprogramar o FPGA.

### 4.4 Golden model Python

O `elm_golden.py` replica a aritmética Q4.12 e as PWL do RTL, servindo como oráculo para todos os testbenches.

```bash
# A partir de arquivo HEX
python model/elm_golden.py --img sim/img_test.hex --weights-dir sim/

# A partir de PNG (redimensiona para 28×28 automaticamente)
python model/elm_golden.py --png model/test/3/1278.png --weights-dir sim/

# PNG com fundo branco (papel)
python model/elm_golden.py --png foto.png --weights-dir sim/ --invert

# Ativação sigmóide em vez de tanh
python model/elm_golden.py --img sim/img_test.hex --weights-dir sim/ --activation sigmoid

# Exibir ativações h[0..127] e scores y[0..9]
python model/elm_golden.py --img sim/img_test.hex --weights-dir sim/ --verbose

# Salvar arquivos intermediários para depuração
python model/elm_golden.py --img sim/img_test.hex --weights-dir sim/ --outdir sim/
```

Arquivos intermediários gerados com `--outdir`:

| Arquivo | Conteúdo |
|---------|----------|
| `img_test.hex` | 784 pixels (8-bit por linha) |
| `h_ref.hex` | 128 ativações Q4.12 da camada oculta |
| `z_output.hex` | 10 scores Q4.12 da camada de saída |
| `pred_ref.hex` | Dígito predito (1 linha) |

### 4.5 Converter imagem PNG para HEX

O `conv.py` converte qualquer imagem PNG para o formato HEX de 784 bytes do co-processador.

```bash
# Imagem MNIST padrão (fundo preto, dígito branco)
python model/conv.py model/test/3/1278.png sim/img_test.hex

# Foto em papel (fundo branco, dígito escuro) — inverte pixels
python model/conv.py foto_digito.png sim/img_test.hex --invert
```

Fluxo interno: PNG → escala de cinza → redimensiona 28×28 (LANCZOS) → \[inverte\] → 784 linhas `XX\n`. O arquivo é compatível com `$readmemh`, com `elm_golden.py --img` e com STORE_IMG do driver.

**Nota sobre inversão:** o MNIST usa fundo preto (pixel=0) e dígito branco (pixel=255). Imagens capturadas em papel têm a polaridade oposta e precisam de `--invert`. O hardware não normaliza a polaridade — isso é responsabilidade do pré-processamento.

### 4.6 Gerar imagens para o top_demo

```bash
cd model
python gen_all_digits.py --testdir test --outdir ../sim
```

Gera `digit_0.hex`..`digit_9.hex` em `sim/`. Após gerar, re-sintetize o projeto Quartus para gravar as imagens nas ROMs internas do `top_demo`.

---

## 5. Arquitetura da Solução

### 5.1 Visão Geral

O sistema possui dois top-levels, selecionáveis no projeto Quartus:

**`elm_accel.v`** — expõe o barramento MMIO de 32 bits para o HPS. O ARM carrega parâmetros e imagem via instruções STORE_*, dispara com START e lê o resultado via STATUS/RESULT.

**`top_demo.v`** — encapsula o `elm_accel` e opera standalone na DE1-SoC. Armazena 10 imagens MNIST em ROMs internas (uma por dígito), emula o protocolo MMIO em hardware e expõe a interface física da placa.

O fluxo de inferência é idêntico nos dois casos:

```
Parâmetros (via $readmemh no bitstream — Marco 1)
           (via STORE_WEIGHTS/BIAS/BETA — Marco 2)
       │
       ▼
  ram_pesos (W_in) · ram_bias (b) · ram_beta (β)

Imagem (STORE_IMG → 784 pixels)
       │
       ▼
  LOAD_IMG  → ram_img (784 × 8 bits)
       │
       ▼
CALC_HIDDEN → h[i] = PWL(W_in[i]·x + b[i])   para i=0..127
       │         MAC + ram_pesos + ram_bias + pwl_activation → ram_hidden
       ▼
CALC_OUTPUT → y[k] = β[:,k]·h                  para k=0..9
       │         MAC + ram_beta + ram_hidden → y_buf[10]
       ▼
   ARGMAX   → pred = argmax(y[0..9])
       │
       ▼
    RESULT  (0..9)
```

### 5.2 Blocos do Sistema

| Módulo | Tipo | Função |
|--------|------|--------|
| `top_demo` | Demo | Interface física da DE1-SoC; emula o HPS em hardware |
| `elm_accel` | Top-level | Interconexão de todos os submódulos do co-processador |
| `reg_bank` | Controle | Interface MMIO (8 registradores); ponteiros auto-incrementais para STORE_* |
| `fsm_ctrl` | Controle | FSM de 7 estados; suporta parâmetro `PRELOADED_IMG` |
| `mac_unit` | Datapath | Multiplicador-acumulador Q4.12 signed com saturação sticky |
| `pwl_activation` | Datapath | PWL tanh — lógica combinacional, 5 segmentos, 0 ciclos |
| `pwl_sigmoid` | Datapath | PWL sigmóide — lógica combinacional, 4 segmentos, 0 ciclos |
| `argmax_block` | Datapath | Comparador sequencial de 10 scores (signed) |
| `ram_img` | Memória | 784 × 8 bits — pixels da imagem |
| `ram_pesos` | Memória | 131.072 × 16 bits — W_in Q4.12 (layout padded) |
| `ram_bias` | Memória | 128 × 16 bits — biases b Q4.12 |
| `ram_beta` | Memória | 1.280 × 16 bits — pesos β Q4.12 |
| `ram_hidden` | Memória | 128 × 16 bits — ativações h[i] |

### 5.3 Formato de Ponto Fixo Q4.12

| Bit | Significado |
|-----|-------------|
| 15 | Sinal (complemento de 2) |
| 14:12 | Parte inteira (3 bits) |
| 11:0 | Parte fracionária (12 bits, resolução 1/4096 ≈ 0.000244) |

Intervalo: [−8,0 ; +7,999755...]

### 5.4 Aproximação PWL do tanh (pwl_activation.v)

Replica tanh(x) com 5 segmentos lineares e saturação em ±1. Lógica combinacional pura — zero ciclos de latência. Slopes implementados via shifts aritméticos, sem multiplicadores.

| Segmento | Intervalo \|x\| | Slope | Slope (shifts) | Intercepto |
|----------|-----------------|-------|----------------|------------|
| 1 | 0 ≤ \|x\| < 0,25 | 1 | identidade | 0 |
| 2 | 0,25 ≤ \|x\| < 0,5 | 7/8 | `x - x>>3` | 0,029 |
| 3 | 0,5 ≤ \|x\| < 1,0 | 5/8 | `x>>1 + x>>3` | 0,156 |
| 4 | 1,0 ≤ \|x\| < 1,5 | 5/16 | `x>>2 + x>>4` | 0,453 |
| 5 | 1,5 ≤ \|x\| < 2,0 | 1/8 | `x>>3` | 0,717 |
| sat. | \|x\| ≥ 2,0 | — | — | ±1,0 |

Simetria: tanh(-x) = -tanh(x). O módulo computa apenas o semiplano positivo e inverte o sinal para x < 0.

### 5.5 Aproximação PWL da Sigmóide (pwl_sigmoid.v)

Replica σ(x) = 1/(1+e⁻ˣ) com 4 segmentos e saturação em 1. Baseado em Oliveira (2017), Apêndice A. Lógica combinacional pura — zero ciclos de latência.

| Segmento | Intervalo \|x\| | Fórmula | Slope (shifts) | Intercepto (Q4.12) |
|----------|-----------------|---------|----------------|-------------------|
| 1 | 0,0 ≤ \|x\| < 1,0 | σ = 0,25·\|x\| + 0,5 | `x>>2` | 0x0800 (2048) |
| 2 | 1,0 ≤ \|x\| < 2,5 | σ = 0,125·\|x\| + 0,625 | `x>>3` | 0x0A00 (2560) |
| 3 | 2,5 ≤ \|x\| < 4,5 | σ = 0,03125·\|x\| + 0,859375 | `x>>5` | 0x0DC0 (3520) |
| sat. | \|x\| ≥ 4,5 | σ = 1,0 | — | 0x1000 (4096) |

Simetria: σ(-x) = 1 - σ(x). Para x < 0, retorna `ONE - y_pos`. Saída em [0x0000, 0x1000] = [0,0; 1,0] em Q4.12.

**Diferença fundamental:** tanh é função ímpar centrada em zero, saída em [−1,+1]. A sigmóide é simétrica em 0,5, saída em [0,+1]. O hardware usa `pwl_activation` (tanh) na camada oculta. `pwl_sigmoid` foi implementado como alternativa configurável em tempo de síntese.

### 5.6 Latência de Inferência

| Estado | Ciclos |
|--------|--------|
| LOAD_IMG | 784 (0 quando PRELOADED_IMG=1) |
| CALC_HIDDEN | 100.736 (128 × 787 ciclos) |
| CALC_OUTPUT | 1.300 (10 × 130 ciclos) |
| ARGMAX | 10 |
| **Total** | **≈ 102.830** |

A 50 MHz: **≈ 2,06 ms por inferência**.

### 5.7 Demo Standalone (top_demo)

| Periférico | Função |
|------------|--------|
| SW[9:0] | Seleciona o dígito a classificar (SW[i] ativo = dígito i) |
| KEY[0] | Dispara a inferência (ativo baixo, com debounce de 20 ms) |
| KEY[1] | Reset do sistema |
| HEX0 | Dígito **predito** pelo co-processador |
| HEX1 | Dígito **selecionado** pelas chaves |
| LEDR0 | BUSY — acende durante a inferência |
| LEDR1 | DONE — acende e permanece após a inferência |
| LEDR2 | ERROR — overflow detectado pela MAC |

---

## 6. Testes de Funcionamento

### 6.1 Estratégia de Validação

Validação em três níveis: módulo unitário, instrução STORE_* isolada e integração end-to-end. O `elm_golden.py` serve como oráculo — a validação do hardware é `pred_hardware == pred_golden`, não `pred == true_label`.

### 6.2 Compilação e execução (Icarus Verilog)

```bash
# Testbench unitário (exemplo: MAC)
iverilog -o sim_mac.vvp rtl/datapath/mac_unit.v rtl/datapath/tb_mac.v
vvp sim_mac.vvp

# Testbench STORE_* (não requer arquivos HEX)
iverilog -o sim_store.vvp \
    rtl/fsm_regbank/reg_bank.v \
    rtl/memory/ram_pesos.v \
    rtl/memory/ram_bias.v \
    rtl/memory/ram_beta.v \
    rtl/tb/tb_store_instructions.v
vvp sim_store.vvp

# Fluxo completo (requer w_in.hex, bias.hex, beta.hex, img_test.hex no CWD)
iverilog -o sim_full.vvp \
    rtl/fsm_regbank/reg_bank.v \
    rtl/fsm_regbank/fsm_ctrl.v \
    rtl/datapath/mac_unit.v \
    rtl/datapath/pwl_activation.v \
    rtl/datapath/argmax_block.v \
    rtl/memory/ram_img.v \
    rtl/memory/ram_pesos.v \
    rtl/memory/ram_bias.v \
    rtl/memory/ram_beta.v \
    rtl/memory/ram_hidden.v \
    rtl/elm_accel.v \
    rtl/tb/tb_full_flow.v
vvp sim_full.vvp
```

Waveforms `.vcd` visualizáveis com GTKWave:

```bash
gtkwave tb_store_instructions.vcd
gtkwave tb_full_flow.vcd
```

### 6.3 Testbenches Unitários

| Testbench | Módulo | Casos | Resultado |
|-----------|--------|-------|-----------|
| `tb_mac.v` | `mac_unit` | 14 | 14/14 PASS |
| `tb_pwl_activation.v` | `pwl_activation` | 17 | 17/17 PASS |
| `tb_argmax_block.v` | `argmax_block` | 11 | 11/11 PASS |
| `tb_datapath.v` | PWL + argmax integrados | 2 | 2/2 PASS |
| `tb_ram_img.v` | `ram_img` | 6 | 6/6 PASS |
| `tb_ram_pesos.v` | `ram_pesos` | 6 | 6/6 PASS |
| `tb_ram_bias.v` | `ram_bias` | 3 | 3/3 PASS |
| `tb_ram_beta.v` | `ram_beta` | 4 | 4/4 PASS |
| `tb_ram_hidden.v` | `ram_hidden` | 6 | 6/6 PASS |
| `tb_reg_bank.v` | `reg_bank` | 10 | 10/10 PASS |
| `tb_fsm_ctrl.v` | `fsm_ctrl` | 18 (63 pontos) | 63/63 PASS |

### 6.4 Testbench das Instruções STORE_*

O `tb_store_instructions.v` valida `reg_bank` e as três RAMs de parâmetros de forma isolada, sem instanciar FSM ou datapath. Não requer arquivos HEX.

| Caso | Descrição | Resultado |
|------|-----------|-----------|
| TC-STR-01 | STORE_WEIGHTS — primeiros 2 writes (W[0][0] e W[0][1]) | PASS |
| TC-STR-02 | STORE_WEIGHTS — rollover pixel→neurônio (W[0][783]→W[1][0]) | PASS |
| TC-STR-03 | STORE_WEIGHTS — saturação após W[127][783] | PASS |
| TC-STR-04 | STORE_BIAS — primeiros 2 writes (b[0] e b[1]) | PASS |
| TC-STR-05 | STORE_BIAS — saturação após b[127] | PASS |
| TC-STR-06 | STORE_BETA — primeiros 2 writes (β[0][0] e β[0][1]) | PASS |
| TC-STR-07 | STORE_BETA — rollover classe (β[0][127]→β[1][0]) | PASS |
| TC-STR-08 | STORE_BETA — saturação após β[127][9] | PASS |
| TC-STR-09 | Reset de ponteiros via CTRL bit[1]=1 | PASS |
| TC-STR-10 | Write após reset recarrega posição 0 de cada memória | PASS |

### 6.5 Testbench de Integração End-to-End

**`tb_elm_accel.v`** — carrega pesos via `$readmemh` direto nas memórias internas e executa inferência via MMIO. Útil para validar a inferência isolada dos mecanismos de carga.

**`tb_full_flow.v`** — exercita o fluxo completo como o driver fará no Marco 2.

| Fase | Ciclos aprox. |
|------|---------------|
| STORE_WEIGHTS (100.352 writes via MMIO) | 100.352 |
| STORE_BIAS (128 writes) | 128 |
| STORE_BETA (1.280 writes) | 1.280 |
| STORE_IMG (784 writes) | 784 |
| Inferência (START + polling + RESULT) | ~102.048 |
| **Total** | **~205.000 ciclos ≈ 4 ms simulado** |

**Imagens validadas:**

| Imagem | Dígito | Golden model | Hardware | CYCLES | Status |
|--------|--------|--------------|----------|--------|--------|
| `test/3/1278.png` | 3 | 3 | 3 | 102.832 | PASS |
| `test/7/...png` | 7 | 7 | 7 | 102.832 | PASS |
| `test/0/10.png` | 0 | 0 | 0 | 102.832 | PASS |

### 6.6 Validação na Placa (top_demo)

| Entrada | Golden model | Hardware (HEX0) | Status |
|---------|--------------|-----------------|--------|
| 784 pixels = 0xFF | 5 | 5 | PASS |

---

## 7. Análise dos Resultados

### 7.1 Corretude Funcional

O co-processador produziu resultados corretos em todas as imagens de teste validadas, com concordância total entre hardware simulado e golden model Python.

### 7.2 Saturação da MAC

Os pesos W_in possuem magnitude elevada (range [−16.305, +18.023] em Q4.12), causando saturação em 30–45 neurônios por imagem durante CALC_HIDDEN. O comportamento sticky da `mac_unit` congela o acumulador no valor saturado e ignora operandos posteriores — replicado exatamente no `elm_golden.py`. Como tanh(±∞) = ±1, a ativação retorna ±1,0 para todos os neurônios saturados, preservando a semântica matemática da rede.

### 7.3 Divergência Float vs. Q4.12

Em algumas imagens, o golden model Q4.12 e o modelo float com tanh exato produzem predições diferentes. Isso é esperado: a aritmética quantizada é o domínio correto de operação. A divergência indica apenas que a quantização alterou ligeiramente a fronteira de decisão.

### 7.4 Timing e Frequência

A lógica de leitura do `reg_bank` foi originalmente combinacional, produzindo caminho crítico de ~30 ns (> período de 20 ns a 50 MHz). A correção foi converter para lógica síncrona com registrador de pipeline.

| Métrica | Antes | Após correção |
|---------|-------|---------------|
| Fmax | 32,53 MHz | **58,22 MHz** |
| Slack a 50 MHz | −10,740 ns | **+2,823 ns** |

### 7.5 Estratégia de Memória — Híbrido $readmemh + MMIO

As RAMs de parâmetros (`ram_pesos`, `ram_bias`, `ram_beta`) são inicializadas em dois momentos:

**Marco 1 — $readmemh:** bloco `initial` inicializa as RAMs durante a síntese. O Quartus grava os pesos nos blocos M10K, tornando o sistema funcional desde a energização sem software. Permite demonstração imediata na placa com o `top_demo`.

**Marco 2 — STORE_* via MMIO:** as instruções STORE_WEIGHTS, STORE_BIAS e STORE_BETA permitem ao driver sobrescrever o conteúdo das RAMs em runtime, trocando de modelo sem reprogramar o FPGA. O conteúdo do `$readmemh` é simplesmente sobrescrito.

A separação temporal garante ausência de hazards: os STORE_* ocorrem antes do START; a FSM só lê as memórias de pesos após o START.

### 7.6 Inicialização de RAM em Síntese

O Quartus respeita `$readmemh` em bloco `initial` para RAMs, mas o comportamento pode variar conforme versão e configurações. Recomenda-se verificar o conteúdo via **In-System Memory Content Editor** após programar o bitstream. Em caso de falha, a alternativa é usar a primitiva `altsyncram` com parâmetro `init_file` nativo.

---

## 8. Uso de Recursos FPGA

Dispositivo: Cyclone V SoC — 5CSEMA5F31C6

### Top-level elm_accel (barramento MMIO)

| Recurso | Utilizado | Disponível | Utilização |
|---------|-----------|------------|------------|
| ALMs (lógica) | 468 | 32.070 | 1% |
| Registradores | 364 | — | — |
| DSP blocks | 1 | 87 | 1% |
| Bits de memória M10K | 2.125.952 | 4.065.280 | 52% |
| Pinos de I/O | 100 | 457 | 22% |

### Top-level top_demo (demo standalone DE1-SoC)

| Recurso | Utilizado | Disponível | Utilização |
|---------|-----------|------------|------------|
| ALMs (lógica) | 1.463 | 32.070 | 5% |
| Registradores | 386 | — | — |
| DSP blocks | 1 | 87 | 1% |
| Bits de memória M10K | 2.125.952 | 4.065.280 | 52% |
| Pinos de I/O | 30 | 457 | 7% |

### Breakdown de memória M10K

| Memória | Profundidade × Largura | Bits | M10K aprox. |
|---------|------------------------|------|-------------|
| `ram_pesos` (W_in, padded) | 131.072 × 16 | 2.097.152 | ≈ 205 |
| `ram_beta` (β) | 1.280 × 16 | 20.480 | ≈ 2 |
| `ram_img` | 784 × 8 | 6.272 | ≈ 1 |
| `ram_hidden` | 128 × 16 | 2.048 | ≈ 1 |
| `ram_bias` | 128 × 16 | 2.048 | ≈ 1 |
| **Total** | — | **≈ 2.128.000** | **≈ 207** |

A conversão ROM → RAM não altera o uso de M10K: os mesmos blocos físicos são reutilizados com a adição de write enable. O multiplicador da MAC foi inferido pelo Quartus como 1 DSP dedicado (signed 16×16), confirmando que a implementação foi reconhecida corretamente pelo sintetizador.