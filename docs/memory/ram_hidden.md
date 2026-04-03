# **Documentação Técnica: Módulo ram\_hidden (ram\_hidden.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 3

## **1\. Visão Geral**

O módulo ram\_hidden.v é a memória de trabalho intermediária do co-processador elm\_accel. Sua responsabilidade é armazenar os 128 valores de ativação `h[i]` produzidos pela camada oculta da rede ELM, tornando-os disponíveis para a camada de saída sem a necessidade de recalculá-los.

Matematicamente, cada posição desta memória guarda o resultado da operação:

```
h[i] = sigmoid(W_in[i] · x + b[i])
```

Esses valores são escritos sequencialmente durante o estado `CALC_HIDDEN` da FSM e lidos durante o estado `CALC_OUTPUT`, formando o elo de dados entre as duas camadas da rede.

**Características Principais da Arquitetura:**

* **Tipo:** BRAM síncrona de porta única (*single-port synchronous RAM*), 128 posições × 16 bits.
* **Dado armazenado:** Valores em ponto fixo Q4.12 com sinal (16 bits), resultado da função de ativação sigmoid aplicada à saída da unidade MAC.
* **Ciclo de vida por inferência:** Escrita completa durante `CALC_HIDDEN` (128 ciclos) → Leitura durante `CALC_OUTPUT` (128 × 10 ciclos) → Sobrescrita na próxima inferência.
* **Diferença estrutural em relação à rom\_bias:** Ambas têm exatamente 128 posições de 16 bits, mas a ram\_hidden é uma RAM (reescrita a cada inferência) enquanto a rom\_bias é uma ROM (valores fixos gravados em síntese).

### 1.1. Fundamentos Teóricos: O Papel do Buffer Intermediário na Arquitetura Sequencial

A arquitetura sequencial do elm\_accel processa um neurônio por vez para economizar recursos de hardware — em vez de 128 MACs em paralelo, existe apenas 1 unidade MAC compartilhada. Isso cria uma dependência de dados: a camada de saída precisa dos 128 valores `h[i]` *todos ao mesmo tempo*, mas a camada oculta os produz *um por vez*.

A ram\_hidden resolve exatamente essa tensão arquitetural. Ela age como um buffer de pipeline: enquanto a camada oculta produz e armazena `h[i]`, a camada de saída aguarda. Quando todos os 128 valores estão gravados, a FSM transiciona para `CALC_OUTPUT` e passa a ler a ram\_hidden no ritmo necessário para alimentar a MAC com pares `(β[c][i], h[i])`.

Sem esse buffer, o co-processador precisaria ou de 128 MACs em paralelo (proibitivo em área de FPGA) ou recalcular cada `h[i]` 10 vezes — uma por classe de saída (proibitivo em latência).

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Todas as operações ocorrem na borda de subida. |
| we | Entrada | 1 bit | **Write Enable.** Se `1`, o valor `data_in` é gravado na posição `addr`. Ativo durante `CALC_HIDDEN`; inativo durante `CALC_OUTPUT`. |
| addr | Entrada | 7 bits | **Endereço.** Indexa os 128 neurônios ocultos (0 a 127). 7 bits cobrem exatamente 128 posições sem endereços ociosos. |
| data\_in | Entrada | 16 bits | **Dado de Escrita.** Valor `h[i]` em Q4.12, saída da função de ativação sigmoid. |
| data\_out | Saída | 16 bits | **Dado de Leitura.** Valor `h[addr]` disponível 1 ciclo após a apresentação do endereço. |

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Fase de Escrita: Estado HIDDEN\_LAYER**

Durante o estado `CALC_HIDDEN`, a FSM ativa `we=1` e itera `addr` de 0 a 127. A cada ciclo, a unidade MAC finaliza o acúmulo para o neurônio `i`, a função de ativação aplica sigmoid ao resultado e o valor resultante é imediatamente gravado em `mem[i]`. A latência de escrita é zero do ponto de vista da FSM: o dado gravado na borda N está disponível para leitura a partir da borda N+1.

### **3.2. Fase de Leitura: Estado OUTPUT\_LAYER**

Durante o estado `CALC_OUTPUT`, `we=0` e a FSM itera sobre as 10 classes de saída. Para cada classe `c` (0 a 9), o módulo percorre todos os 128 neurônios ocultos lendo `h[i]` sequencialmente, alimentando a MAC com os pares `(β[c][i], h[i])`. A mesma memória é percorrida 10 vezes — uma por classe — sem nunca ser reescrita durante esse estado.

### **3.3. Comportamento Read-Before-Write**

Identicamente à ram\_img, a ram\_hidden opera em modo *read-before-write*: leitura e escrita simultâneas no mesmo endereço retornam o valor anterior à escrita do ciclo corrente. Na prática, a FSM nunca lê e escreve no mesmo endereço no mesmo ciclo (as duas fases são mutuamente exclusivas via `we`), então esse comportamento não tem impacto funcional — mas deve ser conhecido pelo verificador.

## **4\. Metodologia de Validação e Testbench (tb\_ram\_hidden.v)**

O testbench foi projetado para simular os dois estados operacionais reais do módulo: a fase de escrita sequencial de 128 ativações e a fase de leitura para a camada de saída.

* **TC-HID-01 — Escrita e leitura simples no endereço 0:** *Justificativa:* Teste de sanidade base. Usa `0x1000` (+1.0 em Q4.12) por ser um valor significativo da função sigmoid, verificando que o bit de valor máximo da parte inteira (bit 12) é armazenado sem truncamento.

* **TC-HID-02 — Escrita e leitura no endereço máximo (127):** *Justificativa:* Verifica que os 7 bits de endereço cobrem as 128 posições. Usa `0xF000` (−1.0 em Q4.12) para testar simultaneamente o endereço extremo e a preservação do bit de sinal — erros de extensão de sinal em `data_in` poderiam corromper a informação negativa.

* **TC-HID-03 — Valor negativo Q4.12 preserva o bit de sinal:** *Justificativa:* A saída do sigmoid pode ser negativa antes da saturação. Se `data_in` fosse inadvertidamente declarado sem sinal ou com menos de 16 bits, o bit 15 (sinal) seria descartado, convertendo ativações negativas em positivas e invertendo completamente a semântica da rede.

* **TC-HID-04 — Escrita sequencial de 128 neurônios:** *Justificativa:* Simula o estado `CALC_HIDDEN` completo. Carrega todos os 128 neurônios com o padrão `0x1000 + i` e verifica por amostragem nas posições 0, 64 e 127 — início, meio e fim do banco de ativações.

* **TC-HID-05 — Isolamento entre endereços adjacentes:** *Justificativa:* Detecta erros de aliasing (dois neurônios compartilhando a mesma posição física). Um erro de decodificação de endereço poderia fazer h[20] e h[21] compartilharem o mesmo dado, produzindo predições sistematicamente erradas para todos os pares de neurônios afetados.

* **TC-HID-06 — Sobrescrita entre inferências:** *Justificativa:* Garante que a segunda inferência substitui completamente os valores da primeira. Um resíduo de ativação de uma imagem anterior contaminaria os pesos efetivos da próxima inferência, degradando silenciosamente a acurácia do classificador.

## **5\. Conclusão da Fase**

Os 6 casos de teste resultaram em PASS durante a simulação RTL. A ram\_hidden demonstrou correta inferência como BRAM síncrona, preservação de valores negativos em Q4.12 e isolamento total entre neurônios adjacentes, estando apta para integração como buffer de pipeline entre os estados `CALC_HIDDEN` e `CALC_OUTPUT` da FSM de controle.