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
* **Endereçamento composto (11 bits):** `addr = hidden_idx × 10 + class_idx`. O índice lento é `hidden_idx` (varia de 0 a 127); o índice rápido é `class_idx` (varia de 0 a 9).
* **Inicialização:** Via diretiva `$readmemh("beta_q.hex", mem)` com os pesos reais do modelo treinado.
* **Profundidade declarada:** 1.280 entradas (exata) — não há endereços desperdiçados, ao contrário da rom\_pesos que usa profundidade padded.

### 1.1. Fundamentos Teóricos: Os Pesos β e a Camada de Saída da ELM

Na arquitetura ELM, a camada de saída executa essencialmente uma regressão linear sobre as ativações ocultas `h`. Matematicamente, para cada classe `c`:

**Fase de Treinamento (offline):**

A ELM calcula `β = H† · T`, onde `H` é a matriz de ativações ocultas para todas as imagens de treinamento, `H†` é sua pseudo-inversa de Moore-Penrose, e `T` é a matriz de rótulos alvo. O resultado é uma matriz β de dimensão 10 × 128 que mapeia as ativações ocultas aos 10 escores de classe.

**Fase de Inferência (hardware):**

O co-processador recebe β já treinado (gravado na ROM) e apenas executa a multiplicação `y = β · h` para cada nova imagem. Isso é o cerne da eficiência da ELM: o treino é feito uma única vez em software e o hardware só executa a inferência, sem nenhuma lógica de aprendizado.

### 1.2. Endereçamento Composto e o Layout da Matriz β

A matriz β tem dimensão lógica 128 (neurônios) × 10 (classes), armazenada linearmente com `hidden_idx` como índice lento e `class_idx` como índice rápido:

```
addr = hidden_idx × 10 + class_idx
```

Exemplos:
- `β[hidden=0][class=0]` → addr 0
- `β[hidden=0][class=9]` → addr 9
- `β[hidden=1][class=0]` → addr 10
- `β[hidden=127][class=9]` → addr 1279 (máximo)

Como 10 não é potência de 2, a multiplicação `hidden_idx × 10` não pode ser resolvida por concatenação de bits como na rom\_pesos. Em hardware, a FSM calcula o endereço com shift-and-add:

```verilog
addr_beta = (i << 3) + (i << 1) + k;  // i*8 + i*2 + k = i*10 + k
```

Esse é o mesmo padrão usado na FSM real do elm\_accel (`addr_beta = (i<<3)+(i<<1)+k`), implementado com dois deslocamentos e uma soma — sem multiplicador dedicado.

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Leitura síncrona com latência de 1 ciclo. |
| addr | Entrada | 11 bits | **Endereço composto.** `hidden_idx × 10 + class_idx`. Endereço máximo: `127 × 10 + 9 = 11'd1279`. |
| data\_out | Saída | 16 bits | **Peso β\[neurônio\]\[classe\] em Q4.12.** Disponível 1 ciclo após a apresentação do endereço. |

*Nota: 11 bits cobrem até 2047, mas apenas endereços 0..1279 contêm pesos válidos. A FSM nunca gera endereços acima de 1279.*

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Endereçamento Composto: Shift-and-Add em vez de Concatenação**

O par `(hidden_idx, class_idx)` é mapeado para um endereço linear via `hidden_idx × 10 + class_idx`. Como 10 não é potência de 2, a concatenação de bits não é possível aqui — diferente da rom\_pesos, onde `neuron × 1024` se resolve com concatenação porque 1024 = 2¹⁰.

A solução adotada é shift-and-add: `10 = 8 + 2 = 2³ + 2¹`, portanto:

```verilog
addr_beta = (i << 3) + (i << 1) + k;
// i*8 + i*2 + k  =  i*10 + k
```

Em hardware, cada deslocamento é implementado apenas com roteamento de fios (custo zero). A soma de dois termos consome um somador pequeno de 7 bits — muito mais econômico que um multiplicador genérico por 10.

### **3.2. Profundidade Exata vs. Padded**

A rom\_beta declara `mem [1279:0]` — exatamente as 1.280 posições necessárias. Isso contrasta com a rom\_pesos, que precisa de profundidade padded (131.072) porque 784 ≠ potência de 2. No caso da rom\_beta, o endereço máximo válido é `127 × 10 + 9 = 1279`, que coincide exatamente com o limite do array declarado — não há gap nem posições desperdiçadas.

Consequência prática: qualquer endereço gerado pela FSM com `hidden_idx ∈ [0,127]` e `class_idx ∈ [0,9]` está garantidamente dentro dos limites do array.

### **3.3. Acesso durante CALC\_OUTPUT**

Durante o estado `CALC_OUTPUT` da FSM, o co-processador calcula `y[c] = Σ β[i][c] · h[i]` para cada classe `c`. A FSM mantém `class_idx = c` fixo e itera `hidden_idx` de 0 a 127, gerando o endereço `i × 10 + c` a cada ciclo e lendo simultaneamente `β[i][c]` da rom\_beta e `h[i]` da ram\_hidden. A unidade MAC acumula o produto `β[i][c] × h[i]` a cada ciclo. Ao final dos 128 neurônios, o acumulador contém `y[c]`, que é capturado no buffer `y_buf[c]` do top-level e posteriormente comparado pelo bloco argmax.

## **4\. Metodologia de Validação e Testbench (tb\_rom\_beta.v)**

O testbench foi construído com valores de referência dos pesos reais do professor, validando que a ROM entrega o peso correto para cada par (classe, neurônio).

* **TC-BETA-01 — Leitura de β\[0\]\[0\]:** *Justificativa:* `β[0][0] = −131 → 0xFF7D`. Teste de sanidade base. O valor negativo confirma que o arquivo `beta_q.hex` foi gerado corretamente em complemento de dois e que o `$readmemh` preservou o bit de sinal.

* **TC-BETA-02 — Leitura de β\[127\]\[9\] (endereço máximo = 1279):** *Justificativa:* `β[127][9] = 11 → 0x000B`. Endereço máximo: `127 × 10 + 9 = 11'd1279`. Verifica que a ROM tem profundidade suficiente para cobrir todos os 128 neurônios e que o campo `hidden_idx` (índice lento, bits altos do cálculo) é corretamente resolvido pelo shift-add da FSM para o último neurônio.

* **TC-BETA-03 — Independência entre classes:** *Justificativa:* Lê `β[0][0]` (addr=0) e `β[0][1]` (addr=1) e verifica que são distintos. Se `class_idx` fosse ignorado no endereçamento, todos os 10 scores de saída seriam calculados com os mesmos pesos — o classificador produziria escores idênticos para todas as classes e a predição seria sempre a classe 0.

* **TC-BETA-04 — Varredura por amostragem (3 neurônios × 3 classes):** *Justificativa:* Compara 9 posições estratégicas com o array `expected[]` carregado do mesmo `beta_q.hex`. As posições testadas cobrem o início, meio e fim de três neurônios distintos (0, 63 e 127) para três classes (0, 4 e 9), garantindo que a fórmula `hidden_idx × 10 + class_idx` produz o endereço correto em todo o espaço de endereçamento da matriz.

## **5\. Conclusão da Fase**

Os 4 casos de teste resultaram em PASS durante a simulação RTL com os pesos reais fornecidos. A rom\_beta demonstrou inicialização correta via `$readmemh`, funcionamento do endereçamento composto por shift-and-add (`i×10+k`) e independência entre todas as 10 classes de saída, estando apta para integração no estado `CALC_OUTPUT` do elm\_accel.