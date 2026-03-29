# Documentação Técnica: Módulo top_demo (top_demo.v)

**Top-level Demo Standalone para DE1-SoC**

**Projeto:** elm_accel — Co-processador ELM em FPGA  
**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1  
**Marco:** 1 / Demo Standalone

---

## 1. Visão Geral

O módulo `top_demo.v` é o top-level de demonstração do co-processador
`elm_accel` na placa DE1-SoC, projetado para operar de forma
**standalone** — sem necessidade do HPS (ARM) ou de qualquer software
externo. Toda a orquestração do protocolo MMIO é feita em hardware pelo
próprio `top_demo`.

**Características principais:**

- Armazena 10 imagens MNIST (uma por dígito 0..9) em ROMs internas
  inicializadas em tempo de síntese via arquivos HEX.
- Emula o papel do HPS: escreve os 784 pixels via registrador IMG, pulsa
  START e faz polling no STATUS — tudo em hardware, sem processador.
- Interface física direta com os periféricos da DE1-SoC: switches,
  botões, LEDs e displays de 7 segmentos.
- `elm_accel` é instanciado com `INIT_FILE=""` e `PRELOADED_IMG=0` — o
  co-processador opera no modo normal, com pixels chegando via MMIO.

---

## 2. Interface Física (DE1-SoC)

| Porta    | Pino      | Direção | Descrição                                            |
|:---------|:----------|:--------|:-----------------------------------------------------|
| CLOCK_50 | AF14      | Entrada | Clock de 50 MHz do oscilador da placa                |
| SW[9:0]  | AB12..AE12| Entrada | Seleção do dígito (SW[i]=1 seleciona o dígito i)     |
| KEY0     | AA14      | Entrada | Dispara inferência (ativo baixo, com debounce)       |
| KEY1     | AA15      | Entrada | Reset do sistema (ativo baixo)                       |
| HEX0[6:0]| AE26..AH28| Saída  | Dígito **predito** pelo co-processador (7 segmentos) |
| HEX1[6:0]| AD26..AD28| Saída  | Dígito **selecionado** pelas chaves (7 segmentos)    |
| LEDR0    | V16       | Saída  | BUSY — acende durante a inferência                   |
| LEDR1    | W16       | Saída  | DONE — acende e permanece após a inferência          |
| LEDR2    | V17       | Saída  | ERROR — overflow detectado pela MAC                  |

---

## 3. Operação

**Estado inicial (ao gravar o .sof ou pressionar KEY1):**
- HEX0 exibe traço central (`—`)
- HEX1 exibe o dígito selecionado pelas chaves em tempo real
- Todos os LEDs apagados

**Seleção do dígito:**
- Coloca UMA chave SW[i] para cima para selecionar o dígito i (0..9)
- HEX1 atualiza imediatamente, refletindo a seleção atual
- O encoder de prioridade usa o bit menos significativo ativo: SW[0]
  tem prioridade sobre SW[1], que tem sobre SW[2], e assim por diante

**Disparo da inferência (KEY0):**
1. LEDR0 acende — FSM em BUSY
2. `top_demo` escreve os 784 pixels do dígito selecionado via MMIO
3. `top_demo` pulsa START
4. `top_demo` faz polling no STATUS até DONE
5. LEDR0 apaga, LEDR1 acende — resultado travado
6. HEX0 exibe o dígito predito

**Reset (KEY1):**
- HEX0 volta ao traço, HEX1 mantém o dígito selecionado
- LEDR1 e LEDR2 apagam
- Sistema pronto para nova inferência

---

## 4. Arquitetura Interna

### 4.1. ROMs de Dígitos

O `top_demo` mantém 10 arrays de memória independentes, um por dígito:

```verilog
reg [7:0] rom0 [783:0];   // imagem do dígito 0
reg [7:0] rom1 [783:0];   // imagem do dígito 1
...
reg [7:0] rom9 [783:0];   // imagem do dígito 9

initial begin
    $readmemh(DIGIT_0_HEX, rom0);
    ...
    $readmemh(DIGIT_9_HEX, rom9);
end
```

Os arquivos HEX são gerados pelo script `model/gen_all_digits.py` e
gravados em `sim/digit_0.hex` .. `sim/digit_9.hex`. O Quartus respeita
`$readmemh` em blocos `initial` para memórias **read-only** (nunca
escritas), diferente da `ram_img` que é RAM e exige `altsyncram`.

Um mux combinacional seleciona o pixel correto da ROM correspondente ao
dígito travado em `sel_latch`:

```verilog
always @(*) begin
    case (sel_latch)
        4'd0: rom_pixel = rom0[load_cnt];
        4'd1: rom_pixel = rom1[load_cnt];
        ...
    endcase
end
```

### 4.2. Encoder de Prioridade (SW[9:0] → sel_digit)

As 10 chaves são codificadas por prioridade com `casez`:

```verilog
casez (SW)
    10'b?????????1: sel_digit = 4'd0;  // SW[0] tem prioridade
    10'b????????10: sel_digit = 4'd1;
    ...
    10'b1000000000: sel_digit = 4'd9;
    default:        sel_digit = 4'd0;
endcase
```

`sel_digit` reflete o dígito selecionado em tempo real. Quando KEY0 é
pressionado, `sel_digit` é travado em `sel_latch` — a inferência usa
sempre o dígito que estava selecionado no momento do disparo, mesmo que
as chaves mudem durante o carregamento.

### 4.3. Debounce do KEY0

KEY0 é ativo baixo (nível alto em repouso, baixo quando pressionado).
Um contador de 20 bits filtra o bouncing mecânico (~20 ms a 50 MHz):

```verilog
if (KEY0 !== key_stable)
    dbnc_cnt <= dbnc_cnt + 1;
else
    dbnc_cnt <= 0;

if (dbnc_cnt == 20'hFFFFF)
    key_stable <= KEY0;
```

`start_pulse` é gerado na borda de descida de `key_stable` (transição
de 1 para 0 = botão pressionado). É um pulso de exatamente 1 ciclo.

### 4.4. FSM Interna do top_demo

O `top_demo` possui uma FSM própria de 6 estados que orquestra o
protocolo MMIO sem o HPS:

```
IDLE → LOADING → STARTING → CLEARING → WAITING → LATCHED
  ↑_______________________________________↑ (novo KEY0)
```

| Estado   | O que acontece                                              |
|:---------|:------------------------------------------------------------|
| IDLE     | Aguarda `start_pulse` (KEY0 pressionado)                    |
| LOADING  | Escreve 785 ciclos via MMIO: ciclo 0 = warmup, ciclos 1..784 = pixels |
| STARTING | Escreve 0x01 em CTRL (start=1)                              |
| CLEARING | Escreve 0x00 em CTRL (start=0) — limpa o pulso de start     |
| WAITING  | Polling em STATUS até bits[1:0] == DONE ou ERROR            |
| LATCHED  | Resultado disponível — aguarda próximo KEY0 ou KEY1          |

**Por que a sequência STARTING → CLEARING é necessária:**

O `reg_bank` mantém `start_out=1` até receber uma escrita explícita com
`start=0`. Sem o ciclo CLEARING, a FSM do `elm_accel` reentraria em
LOAD_IMG imediatamente após retornar ao IDLE, criando um loop infinito
de inferências.

**Detalhamento do estado LOADING:**

```
Ciclo load_cnt=0:  warmup — endereço apresentado, sem escrita (we=0)
Ciclo load_cnt=1:  escreve pixel[0] no addr=0
Ciclo load_cnt=2:  escreve pixel[1] no addr=1
...
Ciclo load_cnt=784: escreve pixel[783] no addr=783
                    → transita para STARTING
```

O ciclo de warmup existe porque a leitura da ROM interna (`rom_pixel =
romX[load_cnt]`) é combinacional mas o dado é registrado em `pixel_reg`
no ciclo seguinte. O ciclo 0 apresenta `load_cnt=0` para a ROM mas não
escreve — `pixel_reg` ainda não tem um valor válido. A escrita começa
em `load_cnt=1`, quando `pixel_reg` contém `romX[0]`.

### 4.5. Geração dos Sinais MMIO

```
LOADING (load_cnt > 0):  addr=0x08, write_en=1, data_in=(pixel<<10)|addr_pixel
STARTING:                addr=0x00, write_en=1, data_in=0x01
CLEARING:                addr=0x00, write_en=1, data_in=0x00
demais estados:          addr=0x04, read_en=1   (lê STATUS)
```

O formato do registrador IMG empacotar endereço e dado em uma única
palavra de 32 bits:

```verilog
mmio_din = ({22'b0, pixel_reg} << 10) | {22'b0, img_addr_wr};
// bits[17:10] = pixel_reg (valor do pixel, 0..255)
// bits[9:0]   = img_addr_wr (endereço, 0..783)
```

### 4.6. Travamento do Resultado (done_latch)

DONE dura exatamente 1 ciclo (20 ns) na FSM do `elm_accel` — invisível
ao olho e ao display. O `done_latch` captura o resultado no ciclo exato
em que DONE aparece e o mantém indefinidamente:

```verilog
if (fsm_state == 2'b10) begin   // detecta DONE
    pred_latch <= pred_now;
    done_latch <= 1'b1;
end
```

O `reset_guard` bloqueia o `done_latch` nos primeiros 255 ciclos após
o reset, evitando captura de valores espúrios do `reg_bank` durante a
inicialização:

```verilog
reg [7:0] reset_guard;
wire system_ready = &reset_guard;  // 1 quando reset_guard == 8'hFF (255 ciclos)
```

### 4.7. Decoder de 7 Segmentos

O decoder é implementado como função Verilog pura, compartilhada entre
HEX0 e HEX1:

```verilog
function [6:0] digit_to_seg;
    input [3:0] d;
    case (d)
        4'd0: digit_to_seg = 7'b1000000;  // 0
        4'd1: digit_to_seg = 7'b1111001;  // 1
        ...
    endcase
endfunction
```

Os displays são de cátodo comum — segmentos **ativos em nível baixo**
(0 = aceso). O segmento g isolado (`7'b0111111`) representa o traço
central exibido quando não há resultado disponível.

```
HEX0 = done_latch ? digit_to_seg(pred_latch) : 7'b0111111  // predição ou traço
HEX1 = digit_to_seg(sel_digit)                              // seleção em tempo real
```

---

## 5. Parâmetros

| Parâmetro    | Padrão                  | Descrição                       |
|:-------------|:------------------------|:--------------------------------|
| DIGIT_0_HEX  | `"../sim/digit_0.hex"`  | Caminho do HEX da imagem do 0   |
| DIGIT_1_HEX  | `"../sim/digit_1.hex"`  | Caminho do HEX da imagem do 1   |
| ...          | ...                     | ...                             |
| DIGIT_9_HEX  | `"../sim/digit_9.hex"`  | Caminho do HEX da imagem do 9   |

Os caminhos são relativos à pasta do projeto Quartus (onde está o
`.qpf`).

---

## 6. Instância do elm_accel

```verilog
elm_accel #(
    .INIT_FILE     (""),   // sem pré-carregamento — pixels chegam via MMIO
    .PRELOADED_IMG (0)     // FSM percorre LOAD_IMG normalmente
) u_elm (
    .clk      (CLOCK_50),
    .rst_n    (rst_n),
    .addr     (mmio_addr),
    .write_en (mmio_wen),
    .read_en  (mmio_ren),
    .data_in  (mmio_din),
    .data_out (status_word)
);
```

O `elm_accel` opera no modo completamente normal — a única diferença em
relação ao uso com o HPS é que o agente que escreve os pixels é o
`top_demo` em vez de um programa C.

---

## 7. Geração das Imagens de Teste

O script `model/gen_all_digits.py` gera os 10 arquivos HEX
automaticamente a partir das imagens de teste disponíveis:

```bash
cd model
python gen_all_digits.py --testdir test --outdir ../sim
```

Para cada dígito 0..9, o script seleciona a primeira imagem disponível
em `test/<digito>/` e gera `sim/digit_<d>.hex` com 784 linhas de 2
dígitos hex por pixel.

Após gerar os arquivos, re-sintetize o projeto Quartus para que as
imagens sejam gravadas nas ROMs internas do bitstream.

---

## 8. Uso de Recursos (top_demo como top-level)

| Recurso              | Utilizado | Disponível | Utilização |
|:---------------------|:----------|:-----------|:-----------|
| ALMs (lógica)        | 1.463     | 32.070     | 5%         |
| Registradores        | 386       | —          | —          |
| DSP blocks           | 1         | 87         | 1%         |
| Bits de memória M10K | 2.125.952 | 4.065.280  | 52%        |
| Pinos de I/O         | 30        | 457        | 7%         |
| Fmax obtido          | 58,22 MHz | —          | —          |
| Slack a 50 MHz       | +2,823 ns | —          | —          |
