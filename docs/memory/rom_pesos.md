# **Documentação Técnica: Módulo rom\_pesos (rom\_pesos.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 3

## **1\. Visão Geral**

O módulo rom\_pesos.v é a maior e mais crítica memória do co-processador elm\_accel. Armazena os 100.352 pesos sinápticos `W_in` da camada oculta — 784 pesos por neurônio, para cada um dos 128 neurônios ocultos. Cada peso define a importância de um pixel específico da imagem de entrada para um neurônio específico:

```
h[i] = sigmoid( Σ W_in[i][j] · x[j] + b[i] )  para j = 0..783
```

Este módulo concentra as duas decisões arquiteturais mais relevantes da Fase 3: a escolha do esquema de endereçamento e a profundidade correta da memória para suportar esse esquema.

**Características Principais da Arquitetura:**

* **Tipo:** ROM síncrona de porta única (*single-port synchronous ROM*), 131.072 posições × 16 bits (profundidade padded = 2¹⁷).
* **Pesos armazenados:** 100.352 valores reais em Q4.12, gerados a partir de `W_in_q.txt`. As 30.720 posições restantes contêm zeros (padding inacessível pela FSM).
* **Endereçamento composto padded (17 bits):** `addr = {neuron_idx[6:0], pixel_idx[9:0]}`, equivalente a `neuron_idx × 1024 + pixel_idx`.
* **Inicialização:** Via `$readmemh("w_in.hex", mem)` com layout padded gerado por `scripts/gen_hex.py`.

### 1.1. Fundamentos Teóricos: O Desafio do Endereçamento com 784 ≠ 2ⁿ

A escolha da estratégia de endereçamento de uma memória 2D em hardware é uma decisão com impacto direto na área, velocidade e complexidade da FSM. Para a matriz `W_in` de dimensão 128 × 784, existem duas abordagens fundamentais:

**Endereçamento Linear (descartado):**

```
addr = neuron_idx × 784 + pixel_idx
```

Este esquema mapeia os 100.352 pesos de forma compacta, sem posições desperdiçadas. No entanto, a operação `neuron_idx × 784` exige um multiplicador ou um somador de deslocamento com constante (784 = 512 + 256 + 16) na FSM, adicionando latência e área de hardware. Além disso, a profundidade 100.352 não é potência de 2, dificultando a inferência de BRAM pelo Quartus.

**Endereçamento Padded com Concatenação (adotado):**

Como 784 pixels por neurônio não é potência de 2, o próximo valor acima é 1024 = 2¹⁰. Ao alocar 1024 posições por neurônio em vez de 784, o endereço se torna uma simples concatenação de campos:

```
addr = {neuron_idx[6:0], pixel_idx[9:0]}  =  neuron_idx × 1024 + pixel_idx
```

A concatenação em Verilog é implementada apenas com fios — zero portas lógicas, zero ciclos extras. O custo é o desperdício de `(1024 − 784) × 128 = 30.720` posições, que ocupam memória física mas nunca são acessadas. Para o Cyclone V, esse tradeoff — mais memória, menos lógica — é favorável, pois M10K é um recurso abundante comparado a DSP slices e LUTs.

### 1.2. A Correção Crítica: Profundidade 131.072 em vez de 100.352

Este módulo passou por uma correção crítica durante o desenvolvimento. A versão inicial declarava `mem [100351:0]` (100.352 entradas), mas o endereço máximo gerado pelo esquema padded é:

```
{7'd127, 10'd783} = 127 × 1024 + 783 = 130.831
```

Como 130.831 > 100.351, qualquer acesso a neurônios acima do índice 97 resultaria em leitura fora dos limites do array — retornando `'x` (indefinido) em simulação e comportamento imprevisível em hardware. A correção adotada foi declarar `mem [131071:0]` (2¹⁷ = 131.072), que cobre com folga todos os endereços válidos (máximo 130.831 < 131.071).

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Leitura síncrona com latência de 1 ciclo. |
| addr | Entrada | 17 bits | **Endereço composto padded.** `{neuron_idx[6:0], pixel_idx[9:0]}`. Máximo válido: `{7'd127, 10'd783} = 17'd130831`. |
| data\_out | Saída | 16 bits | **Peso W\_in\[neurônio\]\[pixel\] em Q4.12.** Disponível 1 ciclo após a apresentação do endereço. |

*Nota: Os 17 bits de endereço cobrem até 131.071, mas apenas endereços com `pixel_idx ∈ [0, 783]` contêm pesos válidos. Endereços com `pixel_idx ∈ [784, 1023]` contêm zeros (padding) e não devem ser gerados pela FSM.*

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Layout do Arquivo w\_in.hex e Posições de Padding**

O arquivo `w_in.hex`, gerado por `scripts/gen_hex.py`, tem exatamente 131.072 linhas (uma por posição). O script mapeia cada peso `W_in[n][p]` (fornecido linearmente no arquivo `W_in_q.txt` na ordem `n × 784 + p`) para a posição padded `n × 1024 + p` do arquivo `.hex`. As posições de padding (`n × 1024 + 784` a `n × 1024 + 1023`) são preenchidas com `0000`.

Esse layout garante que a diretiva `$readmemh("w_in.hex", mem)` inicializa corretamente toda a memória de 131.072 posições, sem necessidade de lógica adicional para o tratamento de endereços.

### **3.2. Acesso durante HIDDEN\_LAYER**

Durante `CALC_HIDDEN`, a FSM itera sobre os 128 neurônios. Para cada neurônio `n`, itera-se sobre os 784 pixels `p`, gerando o endereço `{n[6:0], p[9:0]}` a cada ciclo. A MAC acumula `W_in[n][p] × x[p]` para todos os 784 pixels e ao final soma o bias `b[n]`. O loop completo da camada oculta realiza `128 × 784 = 100.352` leituras desta ROM.

### **3.3. Latência e Pipeline**

A latência de 1 ciclo exige que a FSM apresente `addr` no ciclo N para consumir o peso no ciclo N+1. Na prática, a FSM gera o endereço composto `{neuron_idx, pixel_idx}` por concatenação de fios, sem lógica adicional — a troca de neurônio (incremento de `neuron_idx`) e a troca de pixel (incremento de `pixel_idx`) são operações de contadores simples.

## **4\. Metodologia de Validação e Testbench (tb\_rom\_pesos.v)**

O testbench valida o módulo com os pesos reais do professor, cobrindo explicitamente os endereços que detectariam o bug de profundidade descrito na seção 1.2.

* **TC-WGT-01 — Leitura de W\[0\]\[0\]:** *Justificativa:* `W[0][0] = −136 → 0xFF78`. Sanidade base: o neurônio 0, pixel 0 corresponde ao endereço 0, o mais simples possível. Confirma inicialização via `$readmemh` e preservação de sinal negativo.

* **TC-WGT-02 — Leitura de W\[0\]\[783\] (último pixel do neurônio 0):** *Justificativa:* `W[0][783] = 5670 → 0x1626`. Endereço `{7'd0, 10'd783} = 17'd783`. Verifica que `pixel_idx[9:0]` cobre corretamente os 784 pixels sem truncamento.

* **TC-WGT-03 — Leitura de W\[127\]\[0\] (último neurônio, primeiro pixel):** *Justificativa:* `W[127][0] = −466 → 0xFE2E`. **Este é o teste que detecta o bug de profundidade.** O endereço `{7'd127, 10'd0} = 17'd130048` estaria fora dos limites de `mem [100351:0]`, retornando `'x`. Com a correção para `mem [131071:0]`, o acesso é válido e retorna o peso correto.

* **TC-WGT-04 — Leitura de W\[127\]\[783\] (endereço máximo real = 130.831):** *Justificativa:* `W[127][783] = −4225 → 0xEF7F`. Endereço máximo gerado pela FSM. Garante que a ROM tem profundidade suficiente para cobrir todo o espaço de endereçamento da matriz de pesos.

* **TC-WGT-05 — Latência de leitura é exatamente 1 ciclo:** *Justificativa:* Confirma o comportamento síncrono. A FSM não pode consumir o peso no mesmo ciclo em que apresenta o endereço, e o testbench documenta essa janela de espera obrigatória.

* **TC-WGT-06 — Dois endereços consecutivos retornam valores distintos:** *Justificativa:* `W[0][0] ≠ W[1][0]`. Detecta erros de travamento de registrador (saída presa em um valor) ou de ausência de atualização de endereço. Com pesos reais, a probabilidade de `W[0][0] = W[1][0]` é negligenciável — qualquer igualdade indica defeito no hardware.

## **5\. Conclusão da Fase**

Os 6 casos de teste resultaram em PASS durante a simulação RTL com os pesos reais fornecidos, incluindo os testes de endereços altos (TC-WGT-03 e TC-WGT-04) que validam a correção da profundidade padded. A rom\_pesos demonstrou inicialização correta do layout padded via `$readmemh`, endereçamento por concatenação sem lógica adicional e cobertura completa dos 100.352 pesos de `W_in`, estando apta para integração no estado `CALC_HIDDEN` do elm\_accel.