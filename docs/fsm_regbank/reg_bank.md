# Documentação Técnica: Módulo reg_bank (reg_bank.v)

**Banco de Registradores MMIO — Interface ARM ↔ Co-processador**

**Projeto:** elm_accel — Co-processador ELM em FPGA  
**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1  
**Marco:** 1 / Fase 4

---

## 1. Visão Geral

O módulo `reg_bank.v` é a interface entre o processador ARM (HPS) e o
co-processador `elm_accel`. Sua responsabilidade é decodificar os
endereços do barramento MMIO e distribuir os sinais de controle para a
FSM, além de expor os sinais de status de volta para o ARM.

**Características principais:**

- Decodifica 5 registradores de 32 bits mapeados em memória (CTRL,
  STATUS, IMG, RESULT, CYCLES).
- Lógica de escrita **síncrona** — registradores capturam os dados na
  borda de subida do clock.
- Lógica de leitura **síncrona com registrador de pipeline** — `data_out`
  é atualizado no ciclo seguinte à apresentação do endereço (Marco 2:
  correção de timing, ver Seção 5).
- Endereços não mapeados são ignorados silenciosamente na escrita e
  retornam zero na leitura.

---

## 2. Mapa de Registradores MMIO

| Offset | Nome   | Acesso | Campos                                  | Semântica                                      |
|:-------|:-------|:-------|:----------------------------------------|:-----------------------------------------------|
| 0x00   | CTRL   | W      | bit[0]=start, bit[1]=reset              | start=1 inicia inferência; reset=1 aborta a FSM |
| 0x04   | STATUS | R      | bits[1:0]=estado, bits[5:2]=pred        | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR             |
| 0x08   | IMG    | W      | bits[9:0]=pixel_addr, bits[17:10]=pixel_data | Carrega um pixel por escrita; we_img pulsa 1 ciclo |
| 0x0C   | RESULT | R      | bits[3:0]=pred                          | Dígito predito (0..9); válido quando DONE       |
| 0x10   | CYCLES | R      | bits[31:0]                              | Ciclos de clock desde LOAD_IMG até DONE; congela em DONE |

---

## 3. Interface do Módulo

| Porta       | Direção | Largura  | Descrição                                      |
|:------------|:--------|:---------|:-----------------------------------------------|
| clk         | Entrada | 1 bit    | Relógio do sistema                             |
| rst_n       | Entrada | 1 bit    | Reset assíncrono ativo-baixo                   |
| addr        | Entrada | 32 bits  | Endereço do registrador (offset)               |
| write_en    | Entrada | 1 bit    | 1 = escrita do ARM                             |
| read_en     | Entrada | 1 bit    | 1 = leitura do ARM                             |
| data_in     | Entrada | 32 bits  | Dado vindo do ARM                              |
| status_in   | Entrada | 2 bits   | Estado da FSM (IDLE/BUSY/DONE/ERROR)           |
| pred_in     | Entrada | 4 bits   | Dígito previsto (0..9)                         |
| cycles_in   | Entrada | 32 bits  | Contador de ciclos da FSM                      |
| data_out    | Saída   | 32 bits  | Dado enviado ao ARM (latência 1 ciclo)         |
| start_out   | Saída   | 1 bit    | Pulso de 1 ciclo: inicia inferência            |
| reset_out   | Saída   | 1 bit    | Nível: reseta a FSM                            |
| pixel_addr  | Saída   | 10 bits  | Endereço do pixel (0..783)                     |
| pixel_data  | Saída   | 8 bits   | Valor do pixel (0..255)                        |
| we_img_out  | Saída   | 1 bit    | Write enable para ram_img (pulso 1 ciclo)      |

---

## 4. Arquitetura e Lógica do Circuito

### 4.1. Lógica de Escrita (Síncrona)

O bloco de escrita é síncrono — os registradores capturam os dados na
borda de subida do clock quando `write_en=1`. O sinal `we_img_out` é
tratado como pulso: volta automaticamente a 0 no ciclo seguinte à
escrita, garantindo exatamente 1 ciclo de write enable por pixel.

**Decodificação de endereço para escrita:**

```
addr=0x00 (CTRL):  start_out ← data_in[0]
                   reset_out ← data_in[1]

addr=0x08 (IMG):   pixel_addr ← data_in[9:0]
                   pixel_data ← data_in[17:10]
                   we_img_out ← 1  (pulso de 1 ciclo)
```

O empacotamento do registrador IMG em uma única palavra de 32 bits
permite carregar um pixel com uma única transação no barramento MMIO —
endereço nos bits baixos, valor nos bits intermediários, bits altos
reservados (zeros).

### 4.2. Lógica de Leitura (Síncrona — Registrador de Pipeline)

A leitura é implementada como lógica **síncrona** com registrador de
pipeline: `data_out` é capturado na borda de subida do clock, ficando
estável no ciclo seguinte à apresentação do endereço.

```
Ciclo N:   addr + read_en chegam → lógica combinacional resolve o mux
Ciclo N+1: data_out registrado fica estável para o barramento
```

**Decodificação de endereço para leitura:**

```
addr=0x04 (STATUS):  data_out ← {26'b0, pred_in, status_in}
addr=0x0C (RESULT):  data_out ← {28'b0, pred_in}
addr=0x10 (CYCLES):  data_out ← cycles_in
default:             data_out ← 32'h00000000
```

---

## 5. Correção de Timing (Marco 2)

### 5.1. Problema — Caminho Crítico no Projeto Original

Na versão original do módulo, a lógica de leitura era **combinacional**
(`always @(*)`): `data_out` resolvia imediatamente quando `addr` ou
`read_en` mudavam, sem nenhum registrador intermediário.

O caminho crítico resultante era:

```
addr (registrador externo)
  → comparadores de endereço (addr == 0x04? addr == 0x0C?)
  → mux de seleção (status_in / pred_in / cycles_in)
  → data_out (fio direto para o barramento)
```

O Quartus mediu esse caminho em ~30 ns, superior ao período de clock de
20 ns (50 MHz). O resultado:

| Métrica          | Valor          |
|:-----------------|:---------------|
| Fmax obtido      | 32,53 MHz      |
| Slack a 50 MHz   | −10,740 ns     |
| Caminho crítico  | `reg_bank` addr → data_out |

### 5.2. Solução — Registrador de Pipeline na Saída

A correção foi converter o bloco de leitura de `always @(*)` para
`always @(posedge clk)`, inserindo um registrador de pipeline entre a
lógica combinacional e a saída:

```verilog
// ANTES (combinacional — caminho crítico de ~30 ns):
always @(*) begin
    if (read_en) begin
        case (addr)
            32'h04: data_out = {26'b0, pred_in, status_in};
            ...
        endcase
    end
end

// DEPOIS (síncrono — dois segmentos de ~10 ns cada):
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) data_out <= 32'h00000000;
    else if (read_en) begin
        case (addr)
            32'h04: data_out <= {26'b0, pred_in, status_in};
            ...
        endcase
    end
end
```

O registrador funciona como ponto de parada que quebra o caminho longo
em dois segmentos curtos, cada um com ~10–12 ns — dentro do período de
20 ns.

### 5.3. Resultado após a Correção

| Métrica          | Antes          | Depois         |
|:-----------------|:---------------|:---------------|
| Fmax             | 32,53 MHz      | **58,22 MHz**  |
| Slack a 50 MHz   | −10,740 ns     | **+2,823 ns**  |
| Caminho crítico  | reg_bank addr→data_out | outro ponto do design |

### 5.4. Impacto da Mudança

**Software (infer.c / polling):** nenhum impacto. O polling em C tem
overhead de microssegundos — 1 ciclo extra de 20 ns é invisível. O
STATUS continua refletindo o estado atual da FSM porque `status_in` e
`pred_in` são sinais estáveis entre ciclos.

**Testbench (tb_reg_bank.v):** os testcases de leitura precisam de 1
ciclo extra antes de verificar `data_out`. Em vez de amostrar `data_out`
no mesmo ciclo em que `read_en` é ativado, é necessário aguardar o
ciclo seguinte.

**Demais módulos:** nenhum impacto — a interface do `reg_bank` não
mudou.

---

## 6. Metodologia de Validação (tb_reg_bank.v)

| Testcase    | O que verifica                                         | Resultado |
|:------------|:-------------------------------------------------------|:----------|
| TC-REG-01   | Reset assíncrono zera todos os registradores           | PASS      |
| TC-REG-02   | Escrita em CTRL[0] gera start_out=1                    | PASS      |
| TC-REG-03   | Escrita em CTRL[1] gera reset_out=1                    | PASS      |
| TC-REG-04   | Escrita em IMG extrai pixel_addr, pixel_data, we_img   | PASS      |
| TC-REG-05   | we_img_out pulsa por exatamente 1 ciclo                | PASS      |
| TC-REG-06   | Leitura de STATUS retorna campo correto                | PASS      |
| TC-REG-07   | Leitura de RESULT retorna pred correto                 | PASS      |
| TC-REG-08   | Leitura de CYCLES retorna contador correto             | PASS      |
| TC-REG-09   | Leitura em endereço inválido retorna zero              | PASS      |
| TC-REG-10   | Escrita em endereço inválido não afeta registradores   | PASS      |

**Nota sobre TC-REG-06..08 após a correção de timing:** os testcases de
leitura foram ajustados para amostrar `data_out` 1 ciclo após a
ativação de `read_en`, refletindo o novo comportamento síncrono.
