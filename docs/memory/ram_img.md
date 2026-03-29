# Documentação Técnica: Módulo ram_img (ram_img.v)

**BRAM de Imagem — Ponto de Entrada de Dados do Co-processador**

**Projeto:** elm_accel — Co-processador ELM em FPGA  
**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1  
**Marco:** 1 / Fase 3

---

## 1. Visão Geral

O módulo `ram_img.v` é o ponto de entrada de dados do co-processador
`elm_accel`. Sua responsabilidade é receber e armazenar temporariamente
os 784 bytes que representam uma imagem MNIST de 28×28 pixels em escala
de cinza, disponibilizando-os sequencialmente para o datapath durante a
inferência.

**Características principais:**

- **Tipo:** BRAM síncrona de porta única, 784 posições × 8 bits.
- **Inferência pelo Quartus:** o padrão `reg [7:0] mem [783:0]` com
  leitura em `always @(posedge clk)` é reconhecido automaticamente e
  sintetizado como bloco M10K, sem consumir flip-flops.
- **Comportamento Read-Before-Write:** leitura e escrita simultâneas no
  mesmo endereço retornam o valor anterior à escrita.
- **Latência de leitura:** 1 ciclo de clock.

---

## 2. Interface do Módulo

| Porta    | Direção | Largura | Descrição                                          |
|:---------|:--------|:--------|:---------------------------------------------------|
| clk      | Entrada | 1 bit   | Relógio do sistema                                 |
| we       | Entrada | 1 bit   | Write Enable — 1 = escreve, 0 = só lê              |
| addr     | Entrada | 10 bits | Endereço (0..783)                                  |
| data_in  | Entrada | 8 bits  | Pixel a escrever (0..255)                          |
| data_out | Saída   | 8 bits  | Pixel lido (latência 1 ciclo)                      |

---

## 3. Arquitetura e Lógica do Circuito

### 3.1. Escrita Condicional

O sinal `we` atua como guardião da memória. Quando `we=1`, o pixel em
`data_in` é gravado na posição `addr`. Quando `we=0`, a memória é
preservada — o datapath pode ler pixels sem risco de corrupção.

### 3.2. Leitura Síncrona e Latência de 1 Ciclo

A leitura é registrada: o endereço `addr` é amostrado na borda de
subida do clock e o dado aparece em `data_out` apenas no ciclo seguinte.

```
Ciclo N:   FSM apresenta addr_img = j
Ciclo N+1: data_out contém pixel[j] → MAC pode acumular
```

O ciclo de warmup (j=0 em CALC_HIDDEN) existe para absorver essa
latência — a acumulação começa em j=1, quando o primeiro pixel já está
estável em `data_out`.

### 3.3. Porta Única e Mux de Endereço

A `ram_img` é single-port — leitura e escrita compartilham o mesmo
barramento de endereço. O mux no top-level seleciona a fonte:

```verilog
wire [9:0] ram_img_addr = we_img_rb ? pixel_addr : addr_img;
```

- `we_img_rb=1` → ARM ou `top_demo` escrevendo → usa `pixel_addr`
- `we_img_rb=0` → FSM lendo durante CALC_HIDDEN → usa `addr_img` (contador j)

As duas fases são mutuamente exclusivas no tempo: os pixels são
carregados antes do START, e a FSM lê durante CALC_HIDDEN.

---

## 4. Fluxo de Dados

**Fase de escrita:** o `top_demo` (ou o ARM via MMIO) escreve os 784
pixels antes de disparar START. O `reg_bank` decodifica cada escrita no
offset `0x08`, extrai `pixel_addr` e `pixel_data`, e pulsa `we_img_out`
por 1 ciclo — suficiente para gravar exatamente um pixel.

**Fase de leitura:** durante CALC_HIDDEN, a FSM apresenta `addr_img=j`
a cada ciclo. O top-level converte o pixel lido para Q4.12 antes de
enviar à MAC:

```verilog
wire [15:0] pixel_q412 = {4'b0000, img_data, 4'b0000};
// pixel=128 → 0x0800 → +0.5 em Q4.12
```

---

## 5. Metodologia de Validação (tb_ram_img.v)

| Testcase  | O que verifica                                          | Resultado |
|:----------|:--------------------------------------------------------|:----------|
| TC-IMG-01 | Escrita e leitura no endereço 0                         | PASS      |
| TC-IMG-02 | Escrita e leitura no endereço máximo (783)              | PASS      |
| TC-IMG-03 | we=0 não sobrescreve dado existente                     | PASS      |
| TC-IMG-04 | Latência de leitura é exatamente 1 ciclo                | PASS      |
| TC-IMG-05 | Escrita sequencial de 784 pixels, verificação por amostragem | PASS |
| TC-IMG-06 | Sobrescrita entre inferências                           | PASS      |

**6/6 PASS** com Icarus Verilog.