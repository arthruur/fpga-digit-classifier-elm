# elm_accel — Co-processador ELM em FPGA

**TEC 499 · MI Sistemas Digitais · UEFS 2026.1**

Implementação de um acelerador de hardware em FPGA para inferência de uma rede neural
Extreme Learning Machine (ELM) aplicada à classificação de dígitos manuscritos do conjunto
MNIST. O co-processador é descrito em Verilog RTL e sintetizado para a plataforma DE1-SoC
(Cyclone V FPGA).

**Repositório:** https://github.com/arthruur/fpga-digit-classifier-elm

**Equipe:** Arthur Teles de Oliveira Freitas · Davi Zardo Motté · Gustavo

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
| RF-06 | Expor interface MMIO com 5 registradores de 32 bits (CTRL, STATUS, IMG, RESULT, CYCLES) |
| RF-07 | Suportar as instruções STORE_IMG, START e leitura de STATUS/RESULT |

### 1.2 Requisitos Não Funcionais

| ID | Requisito |
|----|-----------|
| RNF-01 | Aritmética em ponto fixo Q4.12 (16 bits, signed) |
| RNF-02 | Arquitetura sequencial com FSM de controle e MAC compartilhada |
| RNF-03 | Função de ativação implementada sem ROM (lógica combinacional PWL) |
| RNF-04 | Pesos da rede armazenados em ROM inicializada por arquivo MIF/HEX |
| RNF-05 | Simulação RTL validada com golden model Python antes da síntese |
| RNF-06 | Código RTL sintetizável no Quartus Prime Lite para Cyclone V (DE1-SoC) |
| RNF-07 | Tempo de inferência inferior a 1 minuto |

### 1.3 Mapa de Registradores MMIO

Endereço base: `0xFF200000` (Lightweight HPS-to-FPGA bridge)

| Offset | Registrador | Acesso | Campos | Semântica |
|--------|-------------|--------|--------|-----------|
| 0x00 | CTRL | W | bit[0]=start, bit[1]=reset | start=1 inicia inferência; reset=1 aborta |
| 0x04 | STATUS | R | bits[1:0]=estado, bits[5:2]=pred | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR |
| 0x08 | IMG | W | bits[9:0]=addr, bits[17:10]=dado | Carrega um pixel por escrita |
| 0x0C | RESULT | R | bits[3:0]=pred | Dígito predito (0..9), válido em DONE |
| 0x10 | CYCLES | R | 32 bits | Ciclos de LOAD_IMG até DONE |

---

## 2. Softwares Utilizados

| Software | Versão | Finalidade |
|----------|--------|------------|
| Quartus Prime Lite | 25.1std.0 Build 1129 (21/10/2025) | Síntese, place-and-route, análise de timing |
| Icarus Verilog | 12.0 (devel) s20150603-1539-g2693dd32b | Compilação e simulação RTL |
| GTKWave | — | Visualização de waveforms (.vcd) |
| Python | 3.13.7 | Golden model, geração de arquivos HEX/MIF |
| Pillow (PIL) | — | Leitura de imagens PNG no golden model |
| NumPy | — | Operações matriciais no golden model |
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
│   ├── elm_accel.v              # Top-level
│   ├── fsm_regbank/
│   │   ├── fsm_ctrl.v
│   │   ├── reg_bank.v
│   │   ├── tb_fsm_ctrl.v
│   │   └── tb_reg_bank.v
│   ├── datapath/
│   │   ├── mac_unit.v
│   │   ├── pwl_activation.v
│   │   ├── argmax_block.v
│   │   ├── tb_mac.v
│   │   ├── tb_pwl_activation.v
│   │   ├── tb_argmax_block.v
│   │   └── tb_datapath.v
│   ├── memory/
│   │   ├── ram_img.v
│   │   ├── rom_pesos.v
│   │   ├── rom_bias.v
│   │   ├── rom_beta.v
│   │   ├── ram_hidden.v
│   │   └── tb_ram_*.v / tb_rom_*.v
│   └── tb/
│       └── tb_elm_accel.v
├── model/
│   ├── model_elm_q.npz          # Pesos treinados em Q4.12
│   ├── elm_golden.py            # Golden model Python
│   ├── gen_hex.py               # Geração de HEX e MIF
│   ├── diagnose_normalization.py
│   └── test/                   # Imagens MNIST por dígito (0..9)
├── sim/                         # Arquivos HEX e binários de simulação
│   ├── w_in.hex / w_in.mif
│   ├── bias.hex / bias.mif
│   ├── beta.hex / beta.mif
│   ├── img_test.hex
│   └── pred_ref.hex
├── quartus/                     # Projeto Quartus
│   ├── elm_accel.qpf
│   ├── elm_accel.qsf
│   └── elm_accel.sdc
├── scripts/
│   └── batch_validate.py
└── docs/
    ├── datapath/
    ├── memory/
    ├── fsm_regbank/
    ├── integration/
    └── tests/
```

### 4.3 Gerar os arquivos HEX e MIF

Os arquivos de pesos precisam ser gerados a partir do modelo antes de simular ou sintetizar:

```bash
cd model
python gen_hex.py --model model_elm_q.npz --outdir ../sim
```

Arquivos gerados em `sim/`:

| Arquivo | Linhas | Conteúdo |
|---------|--------|----------|
| `w_in.hex` | 131.072 | Pesos W_in em Q4.12, layout padded (neuron×1024+pixel) |
| `bias.hex` | 128 | Biases b em Q4.12 |
| `beta.hex` | 1.280 | Pesos β em Q4.12, layout neuron×10+class |
| `w_in.mif` | — | Versão MIF para síntese no Quartus |
| `bias.mif` | — | Versão MIF para síntese no Quartus |
| `beta.mif` | — | Versão MIF para síntese no Quartus |

### 4.4 Gerar vetores de teste

Para gerar os arquivos de teste para uma imagem específica:

```bash
cd model
python elm_golden.py test/3/1278.png --digit 3 --outdir ../sim
```

Saídas geradas em `sim/`:

| Arquivo | Conteúdo |
|---------|----------|
| `img_test.hex` | 784 pixels (8-bit por linha) |
| `z_hidden.hex` | 128 pré-ativações Q4.12 |
| `h_ref.hex` | 128 ativações PWL Q4.12 |
| `z_output.hex` | 10 scores de saída Q4.12 |
| `pred_ref.hex` | Dígito predito pelo golden model |

---

## 5. Arquitetura da Solução

### 5.1 Visão Geral

O co-processador implementa os quatro estágios da inferência ELM de forma sequencial:

```
Entrada (784 pixels)
       │
       ▼
  LOAD_IMG  → ram_img (784 × 8 bits)
       │
       ▼
CALC_HIDDEN → h[i] = PWL(W_in[i]·x + b[i])   para i=0..127
       │         MAC + rom_pesos + rom_bias + pwl_activation → ram_hidden
       ▼
CALC_OUTPUT → y[k] = β[:,k]·h                  para k=0..9
       │         MAC + rom_beta + ram_hidden → y_buf[10]
       ▼
   ARGMAX   → pred = argmax(y[0..9])
       │
       ▼
    RESULT  (0..9)
```

### 5.2 Blocos do Sistema

| Módulo | Tipo | Função |
|--------|------|--------|
| `elm_accel` | Top-level | Interconexão de todos os submódulos |
| `reg_bank` | Controle | Interface MMIO com o HPS (5 registradores) |
| `fsm_ctrl` | Controle | FSM de 7 estados, geração de sinais de controle |
| `mac_unit` | Datapath | Multiplicador-acumulador Q4.12 signed, saturação |
| `pwl_activation` | Datapath | Aproximação combinacional do tanh (5 segmentos) |
| `argmax_block` | Datapath | Comparador sequencial de 10 scores |
| `ram_img` | Memória | 784 × 8 bits — pixels da imagem |
| `rom_pesos` | Memória | 131.072 × 16 bits — W_in Q4.12 (padded) |
| `rom_bias` | Memória | 128 × 16 bits — biases b Q4.12 |
| `rom_beta` | Memória | 1.280 × 16 bits — pesos β Q4.12 |
| `ram_hidden` | Memória | 128 × 16 bits — ativações h[i] |

### 5.3 Formato de Ponto Fixo Q4.12

Todos os pesos e ativações são representados em Q4.12 signed de 16 bits:

| Bit | Significado |
|-----|-------------|
| 15 | Sinal (complemento de 2) |
| 14:12 | Parte inteira (3 bits) |
| 11:0 | Parte fracionária (12 bits, resolução 1/4096) |

Intervalo: [−8,0 ; +7,999755...] — cobrindo com folga o range de saída do tanh (±1).

### 5.4 Aproximação PWL do tanh

A função de ativação tanh(x) é aproximada por 5 segmentos lineares sem uso de ROM:

| Segmento | Intervalo |x|| Fórmula | Slope (impl.) |
|----------|-----------|---------|---------------|
| 1 | 0 ≤ \|x\| < 0,25 | y = \|x\| | identidade |
| 2 | 0,25 ≤ \|x\| < 0,5 | y = 7/8·\|x\| + 0,029 | shifts |
| 3 | 0,5 ≤ \|x\| < 1,0 | y = 5/8·\|x\| + 0,156 | shifts |
| 4 | 1,0 ≤ \|x\| < 1,5 | y = 5/16·\|x\| + 0,453 | shifts |
| 5 | 1,5 ≤ \|x\| < 2,0 | y ≈ 1/8·\|x\| + 0,717 | shifts |
| sat. | \|x\| ≥ 2,0 | y = ±1,0 | constante |

Latência: 0 ciclos (lógica combinacional pura, sem registradores).

### 5.5 Latência de Inferência

| Estado | Ciclos |
|--------|--------|
| LOAD_IMG | 784 |
| CALC_HIDDEN | 100.736 (128 neurônios × 787 ciclos) |
| CALC_OUTPUT | 1.300 (10 classes × 130 ciclos) |
| ARGMAX | 10 |
| **Total** | **102.830** |

A 50 MHz: **≈ 2,06 ms por inferência**.

---

## 6. Testes de Funcionamento

### 6.1 Estratégia de Validação

A validação seguiu a abordagem TDD (Test-Driven Development): para cada módulo,
os testbenches foram escritos antes da implementação, com todos os testes falhando
inicialmente. A implementação foi considerada completa apenas quando todos os
testes passaram.

### 6.2 Testbenches Individuais

Todos compilados e executados com Icarus Verilog:

```bash
# Exemplo: compilar e rodar testbench da MAC
cd rtl/datapath
iverilog -o tb_mac tb_mac.v mac_unit.v && vvp tb_mac
```

| Testbench | Módulo | Casos | Resultado |
|-----------|--------|-------|-----------|
| `tb_mac.v` | `mac_unit` | 14 | 14/14 PASS |
| `tb_pwl_activation.v` | `pwl_activation` | 17 | 17/17 PASS |
| `tb_argmax_block.v` | `argmax_block` | 11 | 11/11 PASS |
| `tb_datapath.v` | PWL + argmax integrados | 2 | 2/2 PASS |
| `tb_ram_img.v` | `ram_img` | 6 | 6/6 PASS |
| `tb_rom_pesos.v` | `rom_pesos` | 6 | 6/6 PASS |
| `tb_rom_bias.v` | `rom_bias` | 3 | 3/3 PASS |
| `tb_rom_beta.v` | `rom_beta` | 4 | 4/4 PASS |
| `tb_ram_hidden.v` | `ram_hidden` | 6 | 6/6 PASS |
| `tb_reg_bank.v` | `reg_bank` | 10 | 10/10 PASS |
| `tb_fsm_ctrl.v` | `fsm_ctrl` | 18 (63 pontos) | 63/63 PASS |

### 6.3 Testbench de Integração End-to-End

O testbench `tb_elm_accel.v` simula o comportamento completo do HPS realizando
uma inferência via MMIO. Os hex de pesos devem estar presentes em `sim/` antes
de executar.

```bash
# Da pasta sim/ (onde estão os arquivos HEX)
cd sim
vvp tb_elm_accel
```

**Imagens validadas:**

| Imagem | Dígito verdadeiro | Golden model | Hardware | Status |
|--------|------------------|--------------|----------|--------|
| `test/3/1278.png` | 3 | 3 | 3 | PASS |
| `test/7/...png` | 7 | 7 | 7 | PASS |
| `test/0/10.png` | 0 | 0 | 0 | PASS |

Em todos os casos validados: `pred_hardware == pred_golden` e `CYCLES = 102.832`.

### 6.4 Golden Model Python

O script `elm_golden.py` implementa a mesma aritmética Q4.12 e PWL do hardware,
servindo como referência para validação:

```bash
python model/elm_golden.py model/test/3/1278.png --digit 3
```

O golden model implementa:
- Conversão de pixel: `x = pixel << 4` (≈ pixel/255 em Q4.12)
- MAC com truncamento `product[27:12]` e saturação em ±32767/32768
- PWL com os mesmos breakpoints e interceptos do `pwl_activation.v`
- Camada de saída linear (sem ativação)

---

## 7. Análise dos Resultados

### 7.1 Corretude Funcional

O co-processador produziu resultados corretos em todas as imagens de teste
validadas, com concordância total entre hardware simulado e golden model Python.
A métrica relevante para o Marco 1 é `pred_hardware == pred_golden` (não
necessariamente `pred == true_label`), pois o golden model é a referência de
comportamento do hardware.

### 7.2 Saturação da MAC

Os pesos W_in possuem magnitude elevada (range [−16.305, +18.023] em Q4.12),
o que causa saturação do acumulador em 30–45 neurônios por imagem durante
CALC_HIDDEN. Esse comportamento é esperado e tratado corretamente pela lógica
de saturação da `mac_unit`: o acumulador é clampado em ±0x7FFF/0x8000 sem
propagar erro. Como `tanh(±∞) = ±1`, a ativação PWL retorna ±1,0 para todos
os neurônios saturados, preservando a semântica matemática da rede.

### 7.3 Divergência Float vs. Q4.12

Em algumas imagens, o golden model Q4.12 e o modelo float com tanh real produzem
predições diferentes. Isso é esperado: o modelo foi treinado com pesos Q4.12 e
PWL, de modo que a aritmética quantizada é o domínio correto de operação. A
divergência em relação ao float indica apenas que a quantização alterou
ligeiramente a fronteira de decisão — não é um bug.

### 7.4 Timing e Frequência

| Métrica | Valor |
|---------|-------|
| Fmax obtido | 32,53 MHz |
| Slack a 50 MHz | −10,740 ns |
| Caminho crítico | `reg_bank`: leitura combinacional addr→data_out |

O caminho crítico está isolado na lógica de leitura combinacional do `reg_bank`,
que resolve `data_out` no mesmo ciclo em que recebe `addr`. Essa escolha foi
intencional para simplificar o protocolo de polling do Marco 2 — sem latência
de leitura extra para o software. A correção planejada para o Marco 2 é adicionar
um registrador de pipeline na saída de leitura, o que deve fechar o timing a
50 MHz sem impacto funcional.

A 32,53 MHz (Fmax atual), a latência de inferência seria **≈ 3,16 ms** — ainda
dentro de requisitos práticos para classificação de dígitos embarcada.

---

## 8. Uso de Recursos FPGA

Dispositivo: Cyclone V SoC — 5CSEMA5F31C6

| Recurso | Utilizado | Disponível | Utilização |
|---------|-----------|------------|------------|
| ALMs (lógica) | 468 | 32.070 | 1% |
| Registradores | 364 | — | — |
| DSP blocks | 1 | 87 | 1% |
| Bits de memória M10K | 2.125.952 | 4.065.280 | 52% |
| Pinos de I/O | 100 | 457 | 22% |

### Breakdown de memória estimado

| Memória | Bits | Blocos M10K |
|---------|------|-------------|
| `rom_pesos` (W_in, padded) | 2.097.152 | ≈ 205 |
| `rom_beta` (β) | 20.480 | ≈ 2 |
| `ram_img` | 6.272 | ≈ 1 |
| `ram_hidden` | 2.048 | ≈ 1 |
| `rom_bias` | 2.048 | ≈ 1 |
| **Total** | **≈ 2.128.000** | **≈ 207** |

A dominância da `rom_pesos` (52% dos M10K disponíveis) é consequência direta
da dimensão da camada oculta: 128 neurônios × 784 pixels × 16 bits = 1,6 Mbit,
com overhead de 25% pelo layout padded (arredondamento de 784 para 1024). O
dispositivo comporta o design com folga — 48% dos blocos M10K e 99% da lógica
permanecem disponíveis para os Marcos 2 e 3.

O multiplicador da MAC foi inferido pelo Quartus como 1 bloco DSP dedicado
(1% dos 87 disponíveis), confirmando que a implementação signed 16×16 foi
reconhecida corretamente pelo sintetizador.