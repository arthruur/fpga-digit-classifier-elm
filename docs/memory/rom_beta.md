# **Documentação Técnica: Módulo rom\_beta (rom\_beta.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 3

## **1\. Visão Geral**

O módulo rom\_beta.v armazena os pesos `β` da camada de saída da rede ELM. Estes pesos são os únicos parâmetros *aprendidos* durante o treinamento da ELM e determinam diretamente a predição final. Para cada uma das 10 classes de dígitos (0 a 9), existem 128 pesos — um para cada neurônio oculto — totalizando 1.280 valores de 16 bits:

```
y[c] = sigmoid(β[c] · h)  =  sigmoid( Σ β[c][i] · h[i] )  para i = 0..127
```

Por serem parâmetros fixos do modelo treinado, os pesos β são armazenados em ROM inicializada em síntese — nunca modificados em tempo de execução.

**Características Principais da Arquitetura:**

* **Tipo:** ROM síncrona de porta única (*single-port synchronous ROM*), 1.280 posições × 16 bits.
* **Endereçamento composto (11 bits):** `addr = hidden_idx × 10 + class_idx`, equivalente a `class_idx × 128 + hidden_idx`.
* **Inicialização:** Via diretiva `$readmemh("beta.hex", mem)` com os pesos reais do modelo treinado.
* **Profundidade declarada:** 1.280 entradas (exata) — não há endereços desperdiçados, ao contrário da rom\_pesos que usa profundidade padded.

### 1.1. Fundamentos Teóricos: Os Pesos β e a Camada de Saída da ELM

Na arquitetura ELM, a camada de saída executa essencialmente uma regressão linear sobre as ativações ocultas `h`. Matematicamente, para cada classe `c`:

**Fase de Treinamento (offline):**

A ELM calcula `β = H† · T`, onde `H` é a matriz de ativações ocultas para todas as imagens de treinamento, `H†` é sua pseudo-inversa de Moore-Penrose, e `T` é a matriz de rótulos alvo. O resultado é uma matriz β de dimensão 10 × 128 que mapeia as ativações ocultas aos 10 escores de classe.

**Fase de Inferência (hardware):**

O co-processador recebe β já treinado (gravado na ROM) e apenas executa a multiplicação `y = β · h` para cada nova imagem. Isso é o cerne da eficiência da ELM: o treino é feito uma única vez em software e o hardware só executa a inferência, sem nenhuma lógica de aprendizado.

### 1.2. Endereçamento Composto e o Layout da Matriz β

A matriz β tem dimensão lógica 10 (classes) × 128 (neurônios). Para armazená-la linearmente em uma ROM 1D, é necessário um mapeamento bijeto entre o par `(c, i)` e um índice inteiro. O esquema adotado é a linearização por linha:

```
addr = c × 128 + i
```

Em hardware, isso se traduz em uma concatenação de bits: `addr = {c[3:0], i[6:0]}`. A concatenação funciona porque 128 = 2⁷, logo os 7 bits de `hidden_idx` representam exatamente os 128 neurônios sem endereços de padding — diferente da rom\_pesos, onde 784 ≠ 2^n exigiu padding até 1024.

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Leitura síncrona com latência de 1 ciclo. |
| addr | Entrada | 11 bits | **Endereço composto.** `{class_idx[3:0], hidden_idx[6:0]}`. Endereço máximo: `{4'd9, 7'd127} = 11'd1279`. |
| data\_out | Saída | 16 bits | **Peso β\[classe\]\[neurônio\] em Q4.12.** Disponível 1 ciclo após a apresentação do endereço. |

*Nota: 4 bits para class\_idx representam 0 a 15 — as posições 10 a 15 não existem fisicamente (mem declarado com 1280 entradas) e a FSM nunca deve gerar esses endereços.*

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Endereçamento Composto: A Concatenação como Multiplicação Grátis**

O par `(class_idx, hidden_idx)` poderia ser mapeado para um endereço linear via `c × 128 + i`, que exigiria um multiplicador ou somador de deslocamento na FSM. A concatenação `{c[3:0], i[6:0]}` é matematicamente equivalente — pois 128 = 2⁷ — mas é implementada em hardware apenas com fios, sem nenhum recurso lógico adicional. Isso elimina completamente a lógica de cálculo de endereço da FSM e transfere a complexidade para o esquema de roteamento de bits.

### **3.2. Profundidade Exata vs. Padded**

A rom\_beta declara `mem [1279:0]` — exatamente as 1.280 posições necessárias. Isso contrasta com a rom\_pesos, que precisa de profundidade padded (131.072) porque 784 ≠ potência de 2. No caso da rom\_beta, `hidden_idx` tem 7 bits que representam exatamente 128 posições (2⁷ = 128), portanto não há gap entre o número real de pesos e a profundidade da memória.

Consequência prática: a rom\_beta não desperdiça nenhuma posição de memória, e qualquer endereço gerado pela concatenação `{c[3:0], i[6:0]}` com `c ∈ [0,9]` e `i ∈ [0,127]` está garantidamente dentro dos limites do array.

### **3.3. Acesso durante OUTPUT\_LAYER**

Durante o estado `OUTPUT_LAYER` da FSM, o co-processador calcula `y[c] = Σ β[c][i] · h[i]` para cada classe `c`. A FSM mantém `class_idx = c` fixo e itera `hidden_idx` de 0 a 127, lendo simultaneamente `β[c][i]` da rom\_beta e `h[i]` da ram\_hidden. A unidade MAC acumula o produto `β[c][i] × h[i]` a cada ciclo. Ao final dos 128 neurônios, o acumulador contém `y[c]`, que é armazenado e comparado pelo bloco argmax.

## **4\. Metodologia de Validação e Testbench (tb\_rom\_beta.v)**

O testbench foi construído com valores de referência dos pesos reais do professor, validando que a ROM entrega o peso correto para cada par (classe, neurônio).

* **TC-BETA-01 — Leitura de β\[0\]\[0\]:** *Justificativa:* `β[0][0] = −131 → 0xFF7D`. Teste de sanidade base. O valor negativo confirma que o arquivo `beta.hex` foi gerado corretamente em complemento de dois e que o `$readmemh` preservou o bit de sinal.

* **TC-BETA-02 — Leitura de β\[9\]\[127\] (endereço máximo = 1279):** *Justificativa:* `β[9][127] = 11 → 0x000B`. Endereço máximo: `{4'd9, 7'd127} = 11'd1279`. Verifica que a ROM tem profundidade suficiente para cobrir todas as 10 classes e que o campo `class_idx` (bits altos) do endereço composto é corretamente decodificado para a última classe.

* **TC-BETA-03 — Independência entre classes:** *Justificativa:* Lê `β[0][0] = 0xFF7D` e `β[1][0] = 0x000D` e verifica que são distintos. Se `class_idx` fosse ignorado no endereçamento (bug de conectividade em `addr`), todas as 10 classes retornariam os mesmos 128 pesos — o classificador só poderia predizer um único dígito para qualquer entrada.

* **TC-BETA-04 — Varredura por amostragem (3 classes × 3 neurônios):** *Justificativa:* Compara 9 posições estratégicas com o array `expected[]` carregado do mesmo `beta.hex`. As posições testadas cobrem o início, meio e fim de três classes distintas (0, 4 e 9), garantindo que a composição `{class_idx, hidden_idx}` produz o endereço correto em todo o espaço de endereçamento da matriz.

## **5\. Conclusão da Fase**

Os 4 casos de teste resultaram em PASS durante a simulação RTL com os pesos reais fornecidos. A rom\_beta demonstrou inicialização correta via `$readmemh`, funcionamento do endereçamento composto por concatenação de bits e independência entre todas as 10 classes de saída, estando apta para integração no estado `OUTPUT_LAYER` do elm\_accel.
