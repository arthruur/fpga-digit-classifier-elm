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
| RF-06 | Expor interface MMIO com registradores de controle, status e carga de parâmetros |
| RF-07 | Especificar a ISA completa: STORE_IMG, STORE_WEIGHTS, STORE_BIAS, STORE_BETA, START e leitura de STATUS/RESULT |
| RF-08 | Demonstrar inferência standalone na DE1-SoC via botões e displays de 7 segmentos |

### 1.2 Requisitos Não Funcionais

| ID | Requisito |
|----|-----------|
| RNF-01 | Aritmética em ponto fixo Q4.12 (16 bits, signed) |
| RNF-02 | Arquitetura sequencial com FSM de controle e MAC compartilhada |
| RNF-03 | Função de ativação implementada sem ROM (lógica combinacional PWL) |
| RNF-04 | Parâmetros da rede armazenados em RAMs inicializadas no bitstream via `init_file`; reescrita em runtime via MMIO disponível para o Marco 2 |
| RNF-05 | Simulação RTL validada com golden model Python antes da síntese |
| RNF-06 | Código RTL sintetizável no Quartus Prime Lite para Cyclone V (DE1-SoC) |
| RNF-07 | Tempo de inferência inferior a 1 minuto |
| RNF-08 | Timing fechado a 50 MHz (slack positivo após correção do reg_bank) |

### 1.3 ISA — Conjunto de Instruções MMIO

Endereço base: `0xFF200000` (Lightweight HPS-to-FPGA bridge)

| Offset | Registrador | Acesso | Campos | Semântica |
|--------|-------------|--------|--------|-----------|
| 0x00 | CTRL | W | bit[0]=start, bit[1]=reset | start=1 inicia inferência; reset=1 aborta e reseta ponteiros |
| 0x04 | STATUS | R | bits[1:0]=estado, bits[5:2]=pred | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR |
| 0x08 | STORE_IMG | W | bits[9:0]=addr, bits[17:10]=dado | Carrega um pixel por escrita (endereço explícito) |
| 0x0C | RESULT | R | bits[3:0]=pred | Dígito predito (0..9), válido quando STATUS=DONE |
| 0x10 | CYCLES | R | 32 bits | Ciclos de clock de START até DONE |
| 0x14 | STORE_WEIGHTS | W | bits[15:0]=peso Q4.12 | Ponteiro auto-incremental W[0][0]..W[127][783] |
| 0x18 | STORE_BIAS | W | bits[15:0]=bias Q4.12 | Ponteiro auto-incremental b[0]..b[127] |
| 0x1C | STORE_BETA | W | bits[15:0]=peso β Q4.12 | Ponteiro auto-incremental β[0][0]..β[9][127] |

As instruções STORE_WEIGHTS, STORE_BIAS e STORE_BETA utilizam ponteiros auto-incrementais mantidos no `reg_bank`. O ARM não precisa especificar endereços — escreve os dados em sequência e o ponteiro avança automaticamente a cada write. Todos os ponteiros resetam com CTRL bit[1]=1.

**Estado por marco:**

| Instrução | Marco 1 | Marco 2 |
|-----------|---------|---------|
| STORE_IMG | Implementada e funcional em hardware | Mantida |
| START / STATUS / RESULT / CYCLES | Implementadas e funcionais em hardware | Mantidas |
| STORE_WEIGHTS / STORE_BIAS / STORE_BETA | Projetadas no `reg_bank.v` e validadas em simulação | Conectadas ao driver ARM |

---

## 2. Softwares Utilizados

| Software | Versão | Finalidade |
|----------|--------|------------|
| Quartus Prime Lite | 25.1std.0 Build 1129 (21/10/2025) | Síntese, place-and-route, análise de timing, ISMCE |
| Icarus Verilog | 12.0 (devel) s20150603-1539-g2693dd32b | Compilação e simulação RTL |
| GTKWave | — | Visualização de waveforms (.vcd) |
| Python | 3.13.7 | Golden model e scripts de apoio |
| Pillow (PIL) | — | Leitura de imagens PNG |
| NumPy | — | Geração dos arquivos de pesos |
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
│   │   └── reg_bank.v           # Banco de registradores MMIO (ISA completa)
│   ├── datapath/
│   │   ├── mac_unit.v           # Multiplicador-acumulador Q4.12
│   │   ├── pwl_activation.v     # PWL tanh — lógica combinacional, 5 segmentos
│   │   ├── pwl_sigmoid.v        # PWL sigmóide — lógica combinacional, 4 segmentos
│   │   └── argmax_block.v       # Comparador sequencial de 10 scores
│   ├── memory/
│   │   ├── ram_image.v          # Imagem — gerado pelo MegaWizard (ISMCE: IMG)
│   │   ├── ram_pesos_ip.v       # W_in — gerado pelo MegaWizard (ISMCE: PESOS)
│   │   ├── ram_bias_ip.v        # b   — gerado pelo MegaWizard (ISMCE: BIAS)
│   │   ├── ram_beta_ip.v        # β   — gerado pelo MegaWizard (ISMCE: BETA)
│   │   └── ram_hidden.v         # Ativações h[0..127]
│   └── tb/
│       ├── tb_store_instructions.v  # Validação isolada das instruções STORE_*
│       └── tb_full_flow.v           # Fluxo completo: STORE_* via MMIO + inferência
├── model/
│   ├── model_elm_q.npz          # Pesos treinados em Q4.12
│   ├── elm_golden.py            # Golden model Python (Q4.12 RTL-exact)
│   ├── conv.py                  # Conversor PNG → HEX
│   ├── conv_mif.py              # Conversor HEX/PNG → MIF (para ISMCE e init_file)
│   ├── gen_hex.py               # Gera w_in.hex, bias.hex, beta.hex dos pesos
│   ├── gen_mif_weights.py       # Gera bias.mif, beta.mif, w_in.mif para síntese
│   └── test/                    # Imagens MNIST por dígito (0..9)
├── sim/                         # Arquivos para simulação e síntese
│   ├── w_in.hex / w_in.mif
│   ├── bias.hex / bias.mif
│   ├── beta.hex / beta.mif
│   └── img_test.hex / digit_N.mif
├── quartus/
│   ├── elm_accel.qpf
│   ├── elm_accel.qsf
│   └── elm_accel.sdc
└── docs/
```

### 4.3 Gerar os arquivos de pesos

```bash
# Gera os .hex para simulação
cd model
python gen_hex.py --model model_elm_q.npz --outdir ../sim

# Gera os .mif para síntese (init_file das RAMs MegaWizard)
python gen_mif_weights.py --indir ../sim --outdir ../sim
```

Os `.mif` devem estar no diretório do projeto Quartus para que o `init_file` dos módulos MegaWizard seja encontrado em tempo de síntese.

### 4.4 Programar o bitstream e usar o ISMCE

Após compilar e programar o bitstream na DE1-SoC:

1. **Tools → In-System Memory Content Editor → Scan Chain**
2. Quatro instâncias aparecem: `IMG`, `PESOS`, `BIAS`, `BETA`
3. Para carregar uma nova imagem: selecione `IMG` → Import → `digit_N.mif` → Write
4. Para inspecionar os pesos: selecione `PESOS`/`BIAS`/`BETA` → Read

---

## 5. Arquitetura da Solução

### 5.1 Visão Geral

O sistema possui dois top-levels, selecionáveis no projeto Quartus:

**`elm_accel.v`** — expõe o barramento MMIO de 32 bits para o HPS. O ARM carrega parâmetros e imagem via instruções STORE_*, dispara com START e lê o resultado via STATUS/RESULT.

**`top_demo.v`** — encapsula o `elm_accel` e opera standalone na DE1-SoC. Demonstra as instruções STORE_* via chaves físicas e exibe o resultado da inferência nos displays de 7 segmentos.

O fluxo de inferência é idêntico nos dois casos:

```
Parâmetros (init_file no bitstream — Marco 1)
           (STORE_WEIGHTS/BIAS/BETA via MMIO — Marco 2)
       │
       ▼
  ram_pesos_ip (W_in) · ram_bias_ip (b) · ram_beta_ip (β)

Imagem (STORE_IMG → 784 pixels → ram_image)
       │
       ▼
CALC_HIDDEN → h[i] = tanh(W_in[i]·x + b[i])   para i=0..127
       │    MAC + ram_pesos_ip + ram_bias_ip + pwl_activation → ram_hidden
       ▼
CALC_OUTPUT → y[k] = β[:,k]·h                   para k=0..9
       │    MAC + ram_beta_ip + ram_hidden → y_buf[10]
       ▼
   ARGMAX  → pred = argmax(y[0..9])
       │
       ▼
    RESULT (0..9)
```

### 5.2 Blocos do Sistema

| Módulo | Tipo | Função |
|--------|------|--------|
| `top_demo` | Demo | Interface física da DE1-SoC |
| `elm_accel` | Top-level | Interconexão de todos os submódulos |
| `reg_bank` | Controle | ISA MMIO completa; ponteiros auto-incrementais para STORE_* |
| `fsm_ctrl` | Controle | FSM de 7 estados; suporta `PRELOADED_IMG` |
| `mac_unit` | Datapath | Multiplicador-acumulador Q4.12 signed com saturação sticky |
| `pwl_activation` | Datapath | PWL tanh — 5 segmentos, latência zero |
| `pwl_sigmoid` | Datapath | PWL sigmóide — 4 segmentos, latência zero |
| `argmax_block` | Datapath | Comparador sequencial de 10 scores signed |
| `ram_image` | Memória | 1.024 × 8 bits — pixels da imagem; ISMCE habilitado (ID: IMG) |
| `ram_pesos_ip` | Memória | 131.072 × 16 bits — W_in Q4.12; ISMCE habilitado (ID: PESOS) |
| `ram_bias_ip` | Memória | 128 × 16 bits — biases b Q4.12; ISMCE habilitado (ID: BIAS) |
| `ram_beta_ip` | Memória | 1.280 × 16 bits — pesos β Q4.12; ISMCE habilitado (ID: BETA) |
| `ram_hidden` | Memória | 128 × 16 bits — ativações h[i] |

Todos os módulos de memória de parâmetros são gerados pelo **MegaWizard (RAM: 1-PORT)** com `ENABLE_RUNTIME_MOD=YES`, o que os torna visíveis e modificáveis pelo In-System Memory Content Editor via JTAG em tempo de execução, sem interromper o clock do sistema.

### 5.3 Formato de Ponto Fixo Q4.12

| Bit | Significado |
|-----|-------------|
| 15 | Sinal (complemento de 2) |
| 14:12 | Parte inteira (3 bits) |
| 11:0 | Parte fracionária (12 bits, resolução 1/4096 ≈ 0.000244) |

Intervalo: [−8,0 ; +7,999755...]

### 5.4 Aproximação PWL do tanh (pwl_activation.v)

5 segmentos lineares, saturação em ±1, latência zero. Slopes via shifts aritméticos — sem multiplicadores.

| Segmento | Intervalo \|x\| | Slope (shifts) | Intercepto |
|----------|-----------------|----------------|------------|
| 1 | 0 ≤ \|x\| < 0,25 | identidade | 0 |
| 2 | 0,25 ≤ \|x\| < 0,5 | `x - x>>3` | 0,029 |
| 3 | 0,5 ≤ \|x\| < 1,0 | `x>>1 + x>>3` | 0,156 |
| 4 | 1,0 ≤ \|x\| < 1,5 | `x>>2 + x>>4` | 0,453 |
| 5 | 1,5 ≤ \|x\| < 2,0 | `x>>3` | 0,717 |
| sat. | \|x\| ≥ 2,0 | — | ±1,0 |

Simetria: tanh(-x) = -tanh(x). Apenas o semiplano positivo é computado; o sinal é invertido para x < 0.

### 5.5 Aproximação PWL da Sigmóide (pwl_sigmoid.v)

4 segmentos, saturação em 1, latência zero. Baseado em Oliveira (UNIFEI, 2017).

| Segmento | Intervalo \|x\| | Slope (shifts) | Intercepto Q4.12 |
|----------|-----------------|----------------|------------------|
| 1 | 0,0 ≤ \|x\| < 1,0 | `x>>2` | 0x0800 |
| 2 | 1,0 ≤ \|x\| < 2,5 | `x>>3` | 0x0A00 |
| 3 | 2,5 ≤ \|x\| < 4,5 | `x>>5` | 0x0DC0 |
| sat. | \|x\| ≥ 4,5 | — | 0x1000 |

Simetria: σ(-x) = 1 - σ(x). Saída em [0,0; 1,0] em Q4.12. Implementado como alternativa configurável em tempo de síntese; o hardware usa `pwl_activation` (tanh) na camada oculta.

### 5.6 Latência de Inferência

| Estado | Ciclos |
|--------|--------|
| LOAD_IMG | 784 (0 quando PRELOADED_IMG=1) |
| CALC_HIDDEN | 100.736 (128 neurônios × 787 ciclos) |
| CALC_OUTPUT | 1.300 (10 classes × 130 ciclos) |
| ARGMAX | 10 |
| **Total** | **≈ 102.830** |

A 50 MHz: **≈ 2,06 ms por inferência**.

### 5.7 Demo Standalone (top_demo)

| Periférico | Função |
|------------|--------|
| SW[9:8] | Modo: 00=STORE_BIAS · 01=STORE_BETA · 10=STORE_WEIGHTS · 11=RUN |
| SW[7:0] | Dado a escrever (8 bits) nos modos STORE_* |
| KEY[0] | Nos modos STORE_*: escreve 1 valor e avança ponteiro. No modo RUN: dispara inferência |
| KEY[1] | Reset do sistema |
| HEX1 | Nibble alto do dado escrito (SW[7:4]) |
| HEX0 | Nibble baixo do dado / dígito predito no modo RUN |
| LEDR[0] | BUSY |
| LEDR[1] | DONE |
| LEDR[2] | ERROR |

A demonstração das instruções STORE_* na placa consiste em selecionar o modo, definir um padrão em SW[7:0] e pressionar KEY[0] repetidamente. Cada press envia um write MMIO à instrução correspondente. O ISMCE confirma os valores gravados nas instâncias BIAS, BETA ou PESOS em tempo real.

---

## 6. Testes de Funcionamento

### 6.1 Estratégia de Validação

Validação em dois níveis: simulação RTL com golden model como oráculo, e validação funcional na placa. A métrica de corretude é `pred_hardware == pred_golden`.

### 6.2 Compilação e execução (Icarus Verilog)

```bash
# Testbench STORE_* isolado (não requer arquivos HEX)
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

> **Nota:** os testbenches de simulação usam versões comportamentais (`reg []`) das memórias de pesos, distintas dos módulos MegaWizard (`altsyncram`) usados em síntese. Isso permite simulação com Icarus Verilog, que não suporta a primitiva `altsyncram`.

### 6.3 Testbench das Instruções STORE_*

O `tb_store_instructions.v` valida o `reg_bank` e as RAMs de parâmetros de forma isolada. Não requer arquivos HEX.

| Caso | Descrição | Resultado |
|------|-----------|-----------|
| TC-STR-01 | STORE_WEIGHTS — primeiros 2 writes | PASS |
| TC-STR-02 | STORE_WEIGHTS — rollover pixel→neurônio | PASS |
| TC-STR-03 | STORE_WEIGHTS — saturação após W[127][783] | PASS |
| TC-STR-04 | STORE_BIAS — primeiros 2 writes | PASS |
| TC-STR-05 | STORE_BIAS — saturação após b[127] | PASS |
| TC-STR-06 | STORE_BETA — primeiros 2 writes | PASS |
| TC-STR-07 | STORE_BETA — rollover de classe | PASS |
| TC-STR-08 | STORE_BETA — saturação após β[9][127] | PASS |
| TC-STR-09 | Reset de ponteiros via CTRL bit[1]=1 | PASS |
| TC-STR-10 | Write após reset recarrega posição 0 | PASS |

### 6.4 Testbench de Fluxo Completo (tb_full_flow.v)

Exercita o fluxo completo como o driver ARM fará no Marco 2: lê os `.hex` e envia todos os parâmetros via MMIO antes de disparar START.

| Fase | Ciclos aprox. |
|------|---------------|
| STORE_WEIGHTS | 100.352 |
| STORE_BIAS | 128 |
| STORE_BETA | 1.280 |
| STORE_IMG | 784 |
| Inferência | ~102.048 |
| **Total** | **~205.000 ciclos ≈ 4 ms simulado** |

**Imagens validadas:**

| Imagem | Dígito | Golden model | Hardware | CYCLES |
|--------|--------|--------------|----------|--------|
| `test/3/1278.png` | 3 | 3 | 3 | 102.832 |
| `test/7/...png` | 7 | 7 | 7 | 102.832 |
| `test/0/10.png` | 0 | 0 | 0 | 102.832 |

---

## 7. Análise dos Resultados

### 7.1 Corretude Funcional

O co-processador produziu resultados corretos em todas as imagens de teste validadas, com concordância total entre hardware simulado e golden model Python.

### 7.2 Saturação da MAC

Os pesos W_in possuem magnitude elevada (range [−16.305, +18.023] em Q4.12), causando saturação em 30–45 neurônios por imagem durante CALC_HIDDEN. O comportamento `is_saturated` sticky da `mac_unit` congela o acumulador e ignora operandos posteriores. Como tanh(±∞) = ±1, a ativação retorna ±1,0 para neurônios saturados, preservando a semântica matemática da rede.

### 7.3 Divergência Float vs. Q4.12

Em algumas imagens, o golden model Q4.12 e o modelo float com tanh exato produzem predições diferentes. Isso é esperado: a aritmética quantizada é o domínio correto de operação. A divergência indica que a quantização alterou ligeiramente a fronteira de decisão — não é um bug.

### 7.4 Timing e Frequência

A lógica de leitura do `reg_bank` foi inicialmente implementada como combinacional, produzindo caminho crítico de ~30 ns incompatível com o período de 20 ns a 50 MHz. A correção foi converter para lógica síncrona com registrador de pipeline na saída.

| Métrica | Antes | Após correção |
|---------|-------|---------------|
| Fmax | 32,53 MHz | **58,22 MHz** |
| Slack a 50 MHz | −10,740 ns | **+2,823 ns** |

O ciclo extra de latência de leitura é imperceptível para o software: o polling em C opera em escala de microssegundos.

### 7.5 Inicialização das Memórias de Parâmetros

As memórias de parâmetros (`ram_pesos_ip`, `ram_bias_ip`, `ram_beta_ip`) são instâncias `altsyncram` geradas pelo MegaWizard com `init_file` apontando para os arquivos `.mif` dos pesos treinados. O Quartus grava o conteúdo nos blocos M10K durante a síntese, tornando o sistema funcional desde a energização sem necessidade de software.

O parâmetro `ENABLE_RUNTIME_MOD=YES` (definido via `lpm_hint`) mantém um scan chain JTAG ativo em paralelo com o barramento do design, permitindo ao ISMCE ler e modificar o conteúdo das RAMs em tempo de execução sem interromper o clock. Isso viabiliza tanto a inspeção dos pesos quanto a demonstração das instruções STORE_* na placa.

No Marco 2, o driver ARM enviará os pesos via MMIO (STORE_WEIGHTS, STORE_BIAS, STORE_BETA), sobrescrevendo o conteúdo gravado pelo bitstream e permitindo trocar o modelo sem reprogramar o FPGA.

---

## 8. Uso de Recursos FPGA

Dispositivo: Cyclone V SoC — 5CSEMA5F31C6 · Compilação: Quartus Prime Lite 25.1std.0

### Top-level top_demo

| Recurso | Utilizado | Disponível | Utilização |
|---------|-----------|------------|------------|
| ALMs (lógica) | 772 | 32.070 | 2% |
| Registradores | 673 | — | — |
| DSP blocks | 1 | 87 | 1% |
| Bits de memória M10K | 2.129.920 | 4.065.280 | 52% |
| Pinos de I/O | 30 | 457 | 7% |

### Breakdown de memória M10K

| Memória | Profundidade × Largura | Bits | M10K aprox. |
|---------|------------------------|------|-------------|
| `ram_pesos_ip` (W_in, padded) | 131.072 × 16 | 2.097.152 | ≈ 205 |
| `ram_beta_ip` (β) | 1.280 × 16 | 20.480 | ≈ 2 |
| `ram_image` (pixels) | 1.024 × 8 | 8.192 | ≈ 1 |
| `ram_hidden` | 128 × 16 | 2.048 | ≈ 1 |
| `ram_bias_ip` | 128 × 16 | 2.048 | ≈ 1 |
| **Total** | — | **≈ 2.129.920** | **≈ 208** |

A dominância de `ram_pesos_ip` (≈98% da memória usada) é consequência do layout padded: 128 neurônios × 1.024 posições × 16 bits = 2 Mbit. O Quartus inferiu o multiplicador da MAC como 1 bloco DSP dedicado (signed 16×16). Os 48% de M10K e os 98% de ALMs restantes estão disponíveis para os Marcos 2 e 3.