# **Documentação Técnica: Módulo fsm\_ctrl (fsm\_ctrl.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 4

## **1\. Visão Geral**

O módulo fsm\_ctrl.v é o orquestrador central do co-processador elm\_accel. Sua responsabilidade é sequenciar todos os módulos do sistema — memórias, unidade MAC, função de ativação PWL e bloco argmax — nos momentos exatos em que cada operação deve ocorrer, transformando uma sequência de sinais de controle em uma inferência completa da rede ELM.

**Características Principais da Arquitetura:**

* **FSM de 7 estados:** codifica a ordem rigorosa das operações: `IDLE → LOAD_IMG → CALC_HIDDEN → CALC_OUTPUT → ARGMAX → DONE → (volta ao IDLE)`.
* **Arquitetura de 3 blocos:** separação explícita entre lógica sequencial de estado (BLOCO 1), lógica combinacional de transição (BLOCO 2) e lógica combinacional de sinais de controle (BLOCO 3).
* **Três contadores internos:** `j` (sub-ciclo pixel/fase), `i` (índice de neurônio/sub-ciclo de classe) e `k` (índice de classe), que juntos endereçam todas as memórias por concatenação de bits — sem multiplicadores.
* **Totalmente parametrizável:** `N_PIXELS`, `N_NEURONS` e `N_CLASSES` permitem instanciar o módulo com dimensões reduzidas para simulação sem alterar uma linha de lógica.

## **2\. Interface do Módulo**

### 2.1. Parâmetros

| Parâmetro | Padrão | Descrição |
| :---- | :---- | :---- |
| N\_PIXELS | 784 | Pixels por imagem (28×28). |
| N\_NEURONS | 128 | Neurônios da camada oculta. |
| N\_CLASSES | 10 | Classes de saída (dígitos 0–9). |

### 2.2. Portas

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** |
| rst\_n | Entrada | 1 bit | **Reset assíncrono ativo-baixo.** Leva imediatamente ao estado IDLE. |
| start | Entrada | 1 bit | **Pulso de início.** Sobe por 1 ciclo quando o ARM escreve `CTRL[0]=1`. |
| reset | Entrada | 1 bit | **Nível de abort.** Força retorno ao IDLE a qualquer momento. Vindo de `CTRL[1]` do reg\_bank. |
| we\_img | Entrada | 1 bit | Sinal do reg\_bank indicando pixel novo disponível (não utilizado internamente — reservado para extensão). |
| overflow | Entrada | 1 bit | Detectado pela MAC. Qualquer overflow durante CALC\_HIDDEN ou CALC\_OUTPUT leva imediatamente ao estado ERROR. |
| argmax\_done | Entrada | 1 bit | Pulso de 1 ciclo do argmax\_block indicando que os 10 scores foram comparados. |
| max\_idx | Entrada | 4 bits | Índice do maior score, fornecido pelo argmax\_block quando `argmax_done=1`. |
| we\_img\_fsm | Saída | 1 bit | Write enable da ram\_img. Ativo durante LOAD\_IMG. |
| addr\_img | Saída | 10 bits | Endereço da ram\_img. Equivale ao contador `j` durante LOAD\_IMG e CALC\_HIDDEN. |
| we\_hidden | Saída | 1 bit | Write enable da ram\_hidden. Pulsa por 1 ciclo ao fim de cada neurônio em CALC\_HIDDEN. |
| addr\_hidden | Saída | 7 bits | Endereço da ram\_hidden. Equivale a `i[6:0]`. |
| addr\_w | Saída | 17 bits | Endereço da rom\_pesos. Concatenação `{i[6:0], j[9:0]}` — sem multiplicador. |
| addr\_bias | Saída | 7 bits | Endereço da rom\_bias. Equivale a `i[6:0]`. |
| addr\_beta | Saída | 11 bits | Endereço da rom\_beta. Concatenação `{k[3:0], i[6:0]}`. |
| mac\_en | Saída | 1 bit | Habilita acumulação na MAC. Nunca sobe junto com `mac_clr`. |
| mac\_clr | Saída | 1 bit | Limpa o acumulador da MAC. Nunca sobe junto com `mac_en`. |
| bias\_cycle | Saída | 1 bit | **Sinal de roteamento de bias.** Quando em 1, o top-level deve rotear `bias_data → mac_a` e `16'h1000 → mac_b` em vez dos dados normais de pixel/peso. |
| h\_capture | Saída | 1 bit | Indica ao top-level que `pwl_out` deve ser amostrado e escrito na ram\_hidden neste ciclo. |
| argmax\_en | Saída | 1 bit | Habilita comparação no argmax\_block. Ativo durante todo o estado ARGMAX. |
| status\_out | Saída | 2 bits | Estado do sistema para o reg\_bank: `00`=IDLE, `01`=BUSY, `10`=DONE, `11`=ERROR. |
| result\_out | Saída | 4 bits | Dígito predito (0–9). Válido e estável a partir do estado DONE. |
| cycles\_out | Saída | 32 bits | Contador de ciclos de clock desde o início de LOAD\_IMG até DONE. Congela em DONE. |
| done\_out | Saída | 1 bit | Pulso de 1 ciclo. Sobe no ciclo em que o estado entra em DONE. |

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Diagrama de Estados**

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
 │    ◄── 1 ciclo ──      │  i == N_NEURONS+1
IDLE ◄── DONE ◄─── ARGMAX ◄─── argmax_done=1
         │
         │  (qualquer estado, overflow=1)
         ▼
        ERROR ─── (aguarda reset externo via CTRL[1]) ──► IDLE
```

### **3.2. BLOCO 1 — Lógica Sequencial**

Atualiza `current_state`, os três contadores e as saídas registradas (`result_out`, `done_out`, `cycles_out`) a cada borda de subida do clock. Quando `rst_n=0` ou `reset=1`, todos os registradores são zerados imediatamente e o estado vai para IDLE.

A **captura de resultado** ocorre no estado ARGMAX, não no DONE. Isso garante que `result_out` e `done_out` já estejam estáveis no mesmo ciclo em que `current_state` se torna DONE — evitando um atraso de 1 ciclo que faria o banco de registradores ler um resultado antigo.

O **contador de ciclos** (`cycles_out`) é zerado na transição `IDLE → LOAD_IMG` e incrementa em todos os estados exceto IDLE e DONE, produzindo a latência exata de inferência em ciclos de clock.

### **3.3. BLOCO 2 — Lógica de Transição**

Circuito combinacional puro que determina `next_state`. A condição de ERROR tem prioridade sobre qualquer outra transição: se `overflow=1` em qualquer estado ativo (exceto IDLE, DONE e ERROR), o sistema vai imediatamente para ERROR, independentemente de qual cálculo estava em andamento.

### **3.4. BLOCO 3 — Geração de Sinais de Controle**

Circuito combinacional que mapeia o estado atual e os contadores para os sinais de controle das memórias e do datapath. Todos os sinais têm valores padrão seguros em zero antes do `case`, garantindo que nenhum sinal fique indefinido em estados não tratados.

## **4\. Timing Crítico: A Latência de 1 Ciclo das BRAMs**

As BRAMs síncronas do Cyclone V retornam o dado lido no ciclo seguinte à apresentação do endereço. Ignorar essa latência foi a causa raiz dos três bugs corrigidos nesta versão. A FSM gerencia essa latência com uma sequência de fases explícitas dentro de cada estado de cálculo.

### **4.1. Sequência por Neurônio em CALC\_HIDDEN**

| Ciclo j | Fase | mac\_en | mac\_clr | bias\_cycle | we\_hidden | Dado disponível |
| :----: | :---- | :----: | :----: | :----: | :----: | :---- |
| 0 | Warmup | 0 | 0 | 0 | 0 | Lixo/resíduo (não acumulado) |
| 1..N\_PIXELS | Acumulação | 1 | 0 | 0 | 0 | W\[i\]\[j−1\] × x\[j−1\] ✓ |
| N\_PIXELS+1 | Bias | 1 | 0 | 1 | 0 | b\[i\] × 1.0 ✓ |
| N\_PIXELS+2 | Captura+Clear | 0 | 1 | 0 | 1 | acc\_out = Σ + b\[i\] ✓ |

**Total:** N\_PIXELS + 3 ciclos por neurônio. Para N\_PIXELS=784: 787 ciclos × 128 neurônios = 100.736 ciclos.

### **4.2. Sequência por Classe em CALC\_OUTPUT**

| Ciclo i | Fase | mac\_en | mac\_clr | Dado disponível |
| :----: | :---- | :----: | :----: | :---- |
| 0 | Warmup | 0 | 0 | Lixo/resíduo (não acumulado) |
| 1..N\_NEURONS | Acumulação | 1 | 0 | β\[k\]\[i−1\] × h\[i−1\] ✓ |
| N\_NEURONS+1 | Captura+Clear | 0 | 1 | acc\_out = y\[k\] ✓ |

**Total:** N\_NEURONS + 2 ciclos por classe. Para N\_NEURONS=128: 130 ciclos × 10 classes = 1.300 ciclos.

### **4.3. Latência Total de Inferência**

| Estado | Ciclos (parâmetros reais) |
| :---- | :---- |
| LOAD\_IMG | 784 |
| CALC\_HIDDEN | 100.736 |
| CALC\_OUTPUT | 1.300 |
| ARGMAX | 10 |
| **Total aproximado** | **≈ 102.830 ciclos ≈ 2,06 ms a 50 MHz** |

### **4.4. A Regra do Mutex mac\_clr / mac\_en**

A unidade MAC define que `mac_clr` tem prioridade sobre `mac_en`. Se ambos fossem 1 no mesmo ciclo, o acumulador seria zerado antes de acumular o produto, perdendo o último termo de cada neurônio. O BLOCO 3 garante estruturalmente que as fases de acumulação (`mac_en=1, mac_clr=0`) e de limpeza (`mac_en=0, mac_clr=1`) são sempre ciclos distintos e nunca sobrepostos.

### **4.5. O Sinal bias\_cycle e o Roteamento no Top-Level**

A FSM não conecta diretamente os dados de bias à MAC — esse roteamento é responsabilidade do top-level `elm_accel.v`. O sinal `bias_cycle=1` é a instrução que a FSM emite para o top-level inserir o multiplexador correto:

```
bias_cycle=0:  mac_a = img_data    (ou h_rdata em CALC_OUTPUT)
               mac_b = weight_data (ou beta_data em CALC_OUTPUT)

bias_cycle=1:  mac_a = bias_data
               mac_b = 16'h1000  (+1.0 em Q4.12)
```

Esse ciclo único de bias garante que `h[i] = PWL(Σ W[i][j]·x[j] + b[i])` — o argumento completo da PWL, incluindo o deslocamento aprendido durante o treinamento.

## **5\. Metodologia de Validação e Testbench (tb\_fsm\_ctrl.v)**

O testbench instancia a FSM com parâmetros reduzidos (`N_PIXELS=8, N_NEURONS=4, N_CLASSES=3`), reduzindo a simulação de ≈103.000 para ≈70 ciclos sem perder cobertura de transições. Os 18 casos de teste cobrem todos os aspectos funcionais e de robustez.

* **TC-FSM-01 — Reset assíncrono leva ao estado IDLE:** *Justificativa:* Um reset defeituoso invalida todos os testes seguintes. Verifica que `rst_n=0` leva imediatamente ao IDLE e que todos os sinais de controle ficam em zero.

* **TC-FSM-02 — IDLE permanece em IDLE sem start:** *Justificativa:* A FSM não deve avançar espontaneamente. Uma transição sem `start=1` iniciaria uma inferência com imagem indefinida na ram\_img.

* **TC-FSM-03 — IDLE → LOAD\_IMG quando start=1:** *Justificativa:* Transição fundamental do sistema. Verifica que um pulso de `start=1` é suficiente para iniciar o carregamento.

* **TC-FSM-04 — LOAD\_IMG: we\_img\_fsm=1 e addr\_img=j incrementando:** *Justificativa:* Durante LOAD\_IMG, cada ciclo deve endereçar o pixel correto na ram\_img. Um erro em `addr_img` embaralharia a imagem antes mesmo da inferência começar.

* **TC-FSM-05 — LOAD\_IMG → CALC\_HIDDEN após N\_PIXELS ciclos:** *Justificativa:* A transição deve ocorrer exatamente em `j=N_PIXELS-1`. Um ciclo a menos deixaria o último pixel sem endereçar; um a mais leria posição inválida.

* **TC-FSM-06 — CALC\_HIDDEN: warmup em j=0 e acumulação em j=1:** *Justificativa:* Verifica a separação entre o ciclo de warmup (`mac_en=0`, BRAM carregando) e o início da acumulação (`mac_en=1`, dado válido). Detecta o bug clássico de acumular lixo da BRAM no primeiro ciclo.

* **TC-FSM-07 — CALC\_HIDDEN: bias\_cycle e captura+clear ao fim do neurônio:** *Justificativa:* Verifica os três ciclos finais de cada neurônio em sequência: `j=N_PIXELS` (último pixel), `j=N_PIXELS+1` (bias, `bias_cycle=1`, `mac_en=1`, `mac_clr=0`) e `j=N_PIXELS+2` (captura, `we_hidden=1`, `mac_clr=1`, `mac_en=0`). Confirma o mutex `mac_clr/mac_en` e a presença do bias.

* **TC-FSM-08 — CALC\_HIDDEN → CALC\_OUTPUT após N\_NEURONS neurônios:** *Justificativa:* Transição crítica de pipeline. Uma saída prematura deixaria neurônios sem calcular e contaminaria os scores de saída.

* **TC-FSM-09 — CALC\_OUTPUT: warmup em i=0 e acumulação em i=1:** *Justificativa:* Mesmo princípio do TC-FSM-06 para a camada de saída: o primeiro ciclo é warmup (`mac_en=0`), o dado de `h[0]` e `β[k][0]` só é válido em `i=1`.

* **TC-FSM-10 — CALC\_OUTPUT → ARGMAX após N\_CLASSES classes:** *Justificativa:* Garante que todos os 10 scores y[0..9] são calculados antes de entrar em ARGMAX.

* **TC-FSM-11 — ARGMAX → DONE quando argmax\_done=1:** *Justificativa:* A FSM deve detectar o pulso de 1 ciclo do argmax\_block e transicionar. Se ignorar o sinal, o sistema travaria em ARGMAX indefinidamente.

* **TC-FSM-12 — DONE: done\_out=1 e result correto disponível:** *Justificativa:* Verifica que `result_out` e `done_out` já estão válidos no mesmo ciclo em que `current_state=DONE`. A captura antecipada no estado ARGMAX (e não em DONE) é a garantia desse timing.

* **TC-FSM-13 — DONE → IDLE automaticamente após 1 ciclo:** *Justificativa:* O estado DONE dura exatamente 1 ciclo — tempo para o ARM detectar via polling e ler RESULT. A FSM deve estar pronta para nova inferência imediatamente.

* **TC-FSM-14 — ERROR: overflow da MAC leva ao estado ERROR:** *Justificativa:* Um overflow durante o cálculo invalida o resultado. A FSM deve abandonar imediatamente a inferência em vez de reportar um dígito incorreto como válido.

* **TC-FSM-15 — ERROR → IDLE via reset externo:** *Justificativa:* O único caminho de saída do estado ERROR é um reset explícito via `CTRL[1]`. Qualquer auto-recuperação geraria comportamento imprevisível.

* **TC-FSM-16 — Contador CYCLES incrementa e congela em DONE:** *Justificativa:* CYCLES permite ao ARM medir a latência real de inferência. O contador deve iniciar em 0 na entrada de LOAD\_IMG e parar de incrementar assim que o estado DONE é atingido.

* **TC-FSM-17 — Duas inferências consecutivas sem contaminação:** *Justificativa:* O sistema deve classificar imagens em sequência sem que o resultado de uma afete a próxima. Verifica que os contadores são zerados corretamente no retorno ao IDLE.

* **TC-FSM-18 — Reset no meio de CALC\_HIDDEN aborta e volta ao IDLE:** *Justificativa:* O ARM pode precisar cancelar uma inferência em andamento. Verifica que `reset=1` leva imediatamente ao IDLE, zerando `i`, `j` e `k`, e desativando todos os sinais de controle.

## **6\. Conclusão da Fase**

Os 62 pontos de verificação dos 18 casos de teste resultaram em PASS durante a simulação RTL com Icarus Verilog (parâmetros reduzidos: N\_PIXELS=8, N\_NEURONS=4, N\_CLASSES=3). O módulo demonstrou sequenciamento correto em todas as transições de estado, respeito ao mutex `mac_clr/mac_en`, geração correta do ciclo de bias, warmup adequado das BRAMs e tolerância a abort e reset em qualquer ponto da inferência. A FSM está apta para integração no top-level `elm_accel.v` como Fase 5 do Marco 1.
