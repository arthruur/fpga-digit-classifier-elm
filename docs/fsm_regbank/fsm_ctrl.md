# Documentação Técnica: Módulo fsm_ctrl (fsm_ctrl.v)

**Projeto:** elm_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 4 (atualizado na Fase 5)

## 1. Visão Geral

O módulo `fsm_ctrl.v` é o orquestrador central do co-processador
`elm_accel`. Sua responsabilidade é sequenciar todos os módulos do
sistema — memórias, unidade MAC, função de ativação PWL e bloco argmax
— nos momentos exatos em que cada operação deve ocorrer, transformando
uma sequência de sinais de controle em uma inferência completa da rede
ELM.

**Características principais:**

- **FSM de 7 estados:** `IDLE → LOAD_IMG → CALC_HIDDEN → CALC_OUTPUT
  → ARGMAX → DONE → (volta ao IDLE)`, com estado `ERROR` acessível
  apenas via reset externo.
- **Arquitetura de 3 blocos:** separação explícita entre lógica
  sequencial de estado (BLOCO 1), lógica combinacional de transição
  (BLOCO 2) e lógica combinacional de sinais de controle (BLOCO 3).
- **Três contadores internos:** `j` (sub-ciclo pixel/fase), `i`
  (índice de neurônio/sub-ciclo de classe) e `k` (índice de classe),
  que juntos endereçam todas as memórias por concatenação ou
  shift-and-add de bits — sem multiplicadores.
- **Totalmente parametrizável:** `N_PIXELS`, `N_NEURONS` e `N_CLASSES`
  permitem instanciar o módulo com dimensões reduzidas para simulação
  sem alterar uma linha de lógica.

**Alterações introduzidas na Fase 5:**

- Adição das saídas `calc_output_active` e `k_out`, necessárias para
  o roteamento dos muxes da MAC e a captura do buffer `y_buf` no
  top-level `elm_accel.v`.
- Remoção da transição `overflow → ERROR`. A saturação da MAC é
  comportamento normal com os pesos do modelo treinado (magnitude
  elevada) e não constitui condição de erro. O estado ERROR permanece
  na FSM, mas só é acessível via reset externo (`reset=1`).

## 2. Interface do Módulo

### 2.1. Parâmetros

| Parâmetro | Padrão | Descrição |
|:---|:---|:---|
| N_PIXELS | 784 | Pixels por imagem (28×28) |
| N_NEURONS | 128 | Neurônios da camada oculta |
| N_CLASSES | 10 | Classes de saída (dígitos 0–9) |

### 2.2. Portas

| Porta | Direção | Largura | Descrição |
|:---|:---|:---|:---|
| clk | Entrada | 1 bit | Relógio do sistema |
| rst_n | Entrada | 1 bit | Reset assíncrono ativo-baixo |
| start | Entrada | 1 bit | Pulso de início — sobe por 1 ciclo quando o ARM escreve `CTRL[0]=1` |
| reset | Entrada | 1 bit | Nível de abort — força retorno ao IDLE a qualquer momento, vindo de `CTRL[1]` |
| we_img | Entrada | 1 bit | Sinal do reg_bank indicando pixel novo disponível (reservado para extensão) |
| overflow | Entrada | 1 bit | Detectado pela MAC. Não provoca mais transição de estado — tratado como evento normal de saturação |
| argmax_done | Entrada | 1 bit | Pulso de 1 ciclo do argmax_block indicando que os 10 scores foram comparados |
| max_idx | Entrada | 4 bits | Índice do maior score, fornecido pelo argmax_block quando `argmax_done=1` |
| we_img_fsm | Saída | 1 bit | Write enable da ram_img. Ativo durante LOAD_IMG |
| addr_img | Saída | 10 bits | Endereço da ram_img. Equivale ao contador `j` |
| we_hidden | Saída | 1 bit | Write enable da ram_hidden. Pulsa por 1 ciclo ao fim de cada neurônio em CALC_HIDDEN |
| addr_hidden | Saída | 7 bits | Endereço da ram_hidden. Equivale a `i[6:0]` |
| addr_w | Saída | 17 bits | Endereço da rom_pesos. Concatenação `{i[6:0], j[9:0]}` |
| addr_bias | Saída | 7 bits | Endereço da rom_bias. Equivale a `i[6:0]` |
| addr_beta | Saída | 11 bits | Endereço da rom_beta. Calculado como `i×10 + k` via shift-and-add |
| mac_en | Saída | 1 bit | Habilita acumulação na MAC. Nunca sobe junto com `mac_clr` |
| mac_clr | Saída | 1 bit | Limpa o acumulador da MAC. Nunca sobe junto com `mac_en` |
| bias_cycle | Saída | 1 bit | Quando em 1, o top-level roteia `bias_data → mac_a` e `16'h1000 → mac_b` |
| h_capture | Saída | 1 bit | Indica ao top-level que `pwl_out` deve ser amostrado e escrito na ram_hidden |
| argmax_en | Saída | 1 bit | Habilita comparação no argmax_block. Ativo durante todo o estado ARGMAX |
| status_out | Saída | 2 bits | Estado do sistema para o reg_bank: `00`=IDLE, `01`=BUSY, `10`=DONE, `11`=ERROR |
| result_out | Saída | 4 bits | Dígito predito (0–9). Válido e estável a partir do estado DONE |
| cycles_out | Saída | 32 bits | Contador de ciclos de clock desde o início de LOAD_IMG até DONE. Congela em DONE |
| done_out | Saída | 1 bit | Pulso de 1 ciclo. Sobe no ciclo em que o estado entra em DONE |
| calc_output_active | Saída | 1 bit | Nível alto durante todo o estado CALC_OUTPUT. Usado pelo top-level para rotear os muxes da MAC para a camada de saída |
| k_out | Saída | 4 bits | Índice de classe atual (`k[3:0]`). Usado pelo top-level para indexar `y_buf` durante a captura dos scores |

## 3. Arquitetura e Lógica do Circuito

### 3.1. Diagrama de Estados
```
         start
IDLE  ─────────────► LOAD_IMG
 ▲                       │  j == N_PIXELS-1
 │                       ▼
 │                  CALC_HIDDEN
 │                       │  i == N_NEURONS-1
 │                       │  j == N_PIXELS+2
 │                       ▼
 │                  CALC_OUTPUT
 │                       │  k == N_CLASSES-1
 │                       │  i == N_NEURONS+1
 │                       ▼
 │    ◄── 1 ciclo ──   ARGMAX
IDLE ◄──── DONE ◄─── (argmax_done=1)

ERROR ◄── (qualquer estado, reset=1) ──► IDLE
```

O estado ERROR é acessível apenas quando `reset=1` é assertado
externamente via `CTRL[1]`. A saturação da MAC (`overflow=1`) não
provoca transição de estado — esse sinal é recebido pela FSM mas
ignorado na lógica de transição.

### 3.2. BLOCO 1 — Lógica Sequencial

Atualiza `current_state`, os três contadores e as saídas registradas
(`result_out`, `done_out`, `cycles_out`) a cada borda de subida do
clock. Quando `rst_n=0` ou `reset=1`, todos os registradores são
zerados imediatamente e o estado vai para IDLE.

A captura de resultado ocorre no estado ARGMAX, não no DONE. Isso
garante que `result_out` e `done_out` já estejam estáveis no mesmo
ciclo em que `current_state` se torna DONE.

O contador de ciclos (`cycles_out`) é zerado na transição
`IDLE → LOAD_IMG` e incrementa em todos os estados exceto IDLE e DONE.

### 3.3. BLOCO 2 — Lógica de Transição

Circuito combinacional puro que determina `next_state`. Todas as
transições são determinadas exclusivamente pelos contadores internos e
pelos sinais de entrada `start`, `reset` e `argmax_done`. O sinal
`overflow` não influencia mais as transições de estado.

### 3.4. BLOCO 3 — Geração de Sinais de Controle

Circuito combinacional que mapeia o estado atual e os contadores para
os sinais de controle das memórias e do datapath. Todos os sinais têm
valores padrão seguros em zero antes do `case`.

**Endereçamento da rom_beta:**

O arquivo `beta.hex` armazena os pesos no layout `neuron × 10 + class`
(determinado pelo formato de geração do `gen_hex.py`). O endereço é
calculado por shift-and-add, sem multiplicador:
```verilog
addr_beta = ({4'b0, i[6:0]} << 3)   // i × 8
          + ({4'b0, i[6:0]} << 1)   // i × 2
          + {7'b0, k};              // + k
// resultado: i × 10 + k
```

## 4. Timing Crítico: A Latência de 1 Ciclo das BRAMs

As BRAMs síncronas do Cyclone V retornam o dado lido no ciclo seguinte
à apresentação do endereço. A FSM gerencia essa latência com uma
sequência de fases explícitas dentro de cada estado de cálculo.

### 4.1. Sequência por Neurônio em CALC_HIDDEN

| Ciclo j | Fase | mac_en | mac_clr | bias_cycle | we_hidden |
|:---:|:---|:---:|:---:|:---:|:---:|
| 0 | Warmup | 0 | 0 | 0 | 0 |
| 1..N_PIXELS | Acumulação | 1 | 0 | 0 | 0 |
| N_PIXELS+1 | Bias | 1 | 0 | 1 | 0 |
| N_PIXELS+2 | Captura+Clear | 0 | 1 | 0 | 1 |

**Total:** N_PIXELS + 3 ciclos por neurônio.
Para N_PIXELS=784: 787 × 128 = 100.736 ciclos.

### 4.2. Sequência por Classe em CALC_OUTPUT

| Ciclo i | Fase | mac_en | mac_clr |
|:---:|:---|:---:|:---:|
| 0 | Warmup | 0 | 0 |
| 1..N_NEURONS | Acumulação | 1 | 0 |
| N_NEURONS+1 | Captura+Clear | 0 | 1 |

**Total:** N_NEURONS + 2 ciclos por classe.
Para N_NEURONS=128: 130 × 10 = 1.300 ciclos.

### 4.3. Latência Total de Inferência

| Estado | Ciclos |
|:---|:---|
| LOAD_IMG | 784 |
| CALC_HIDDEN | 100.736 |
| CALC_OUTPUT | 1.300 |
| ARGMAX | 10 |
| **Total** | **102.830** |

### 4.4. A Regra do Mutex mac_clr / mac_en

O BLOCO 3 garante estruturalmente que as fases de acumulação
(`mac_en=1, mac_clr=0`) e de limpeza (`mac_en=0, mac_clr=1`) são
sempre ciclos distintos e nunca sobrepostos.

### 4.5. O Sinal bias_cycle e o Roteamento no Top-Level
```
bias_cycle=0:  mac_a = img_data    (ou h_rdata em CALC_OUTPUT)
               mac_b = weight_data (ou beta_data em CALC_OUTPUT)

bias_cycle=1:  mac_a = bias_data
               mac_b = 16'h1000   (+1.0 em Q4.12)
```

## 5. Metodologia de Validação e Testbench (tb_fsm_ctrl.v)

O testbench instancia a FSM com parâmetros reduzidos
(`N_PIXELS=8, N_NEURONS=4, N_CLASSES=3`), reduzindo a simulação de
≈103.000 para ≈70 ciclos sem perder cobertura de transições.

Os 18 casos de teste cobrem todos os aspectos funcionais e de
robustez. O TC-FSM-14 foi atualizado na Fase 5 para refletir a
remoção da transição `overflow → ERROR`:

**TC-FSM-14 (atualizado) — overflow não interrompe a inferência:**
Verifica que a FSM permanece em CALC_HIDDEN quando `overflow=1` é
assertado, confirmando que a saturação da MAC é tratada como evento
normal e não causa transição para ERROR.

## 6. Conclusão da Fase

Os 63 pontos de verificação dos 18 casos de teste resultaram em PASS
durante a simulação RTL com Icarus Verilog (parâmetros reduzidos).
A atualização da Fase 5 — remoção da transição `overflow → ERROR` e
adição de `calc_output_active`/`k_out` — foi validada pela simulação
end-to-end do `tb_elm_accel.v`, que executou uma inferência completa
e retornou a predição correta para múltiplas imagens MNIST.