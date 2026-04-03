# **Documentação Técnica: Módulo rom\_bias (rom\_bias.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 3

## **1\. Visão Geral**

O módulo rom\_bias.v armazena os 128 biases `b[i]` da camada oculta da rede ELM. Cada bias é somado ao produto `W_in[i] · x` pela unidade MAC antes da aplicação da função de ativação, deslocando o ponto de operação de cada neurônio oculto:

```
h[i] = sigmoid(W_in[i] · x + b[i])
```

Por serem parâmetros treinados e fixos durante a inferência, os biases são armazenados em uma ROM inicializada em síntese — nunca reescritos em tempo de execução.

**Características Principais da Arquitetura:**

* **Tipo:** ROM síncrona de porta única (*single-port synchronous ROM*), 128 posições × 16 bits.
* **Dado armazenado:** Valores em ponto fixo Q4.12 com sinal (16 bits), gerados pelo script `gen_hex.py` a partir do arquivo `b_q.txt` fornecido pelo professor.
* **Inicialização:** Via diretiva `$readmemh("bias.hex", mem)`, carregando os pesos reais no início da simulação/síntese.
* **Endereçamento simples:** 1 dimensão — o endereço é diretamente o índice do neurônio (`neuron_idx`), sem composição de campos.
* **Menor ROM do projeto:** 128 × 16 bits = 2.048 bits totais (0,25 KB), cabendo integralmente em uma fração de um bloco M10K.

### 1.1. Fundamentos Teóricos: O Papel do Bias na Rede Neural

O bias desempenha, em hardware, a mesma função matemática que o termo independente em uma equação de reta: deslocar a curva de ativação ao longo do eixo horizontal. Sem o bias, todos os neurônios só poderiam aprender funções que passam pela origem — uma restrição severa que reduziria drasticamente a capacidade expressiva da rede.

Na ELM (*Extreme Learning Machine*), os pesos `W_in` e os biases `b` da camada oculta são inicializados aleatoriamente e **nunca atualizados** durante o treinamento — apenas os pesos `β` da camada de saída são aprendidos. Isso significa que os biases da rom\_bias são determinísticos e fixos para todo o ciclo de vida do hardware, justificando plenamente o uso de ROM em vez de RAM.

### 1.2. Formato Q4.12 e Representação dos Biases

Os valores em `b_q.txt` são inteiros que representam os biases reais multiplicados por 4096 (2¹²). Por exemplo, o bias `b[0] = -710` representa o valor real `−710 / 4096 ≈ −0,1733`. A conversão para hexadecimal 16-bit em complemento de dois resulta em `0xFD3A`, que é o valor gravado na posição 0 do arquivo `bias.hex`.

O intervalo observado nos pesos fornecidos é `[−13439, +8520]`, equivalente a `[−3,281, +2,080]` em Q4.12 — confortavelmente dentro da faixa representável de `[−8,0, +7,999]` pelo formato Q4.12 de 16 bits.

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** A leitura é síncrona: dado disponível 1 ciclo após o endereço. |
| addr | Entrada | 7 bits | **Índice do neurônio.** Varia de 0 a 127. 7 bits representam exatamente 128 posições sem endereços ociosos. |
| data\_out | Saída | 16 bits | **Bias b\[addr\] em Q4.12.** Valor do bias do neurônio indexado por `addr`, disponível no ciclo seguinte. |

*Nota: Não há porta `we` (write enable) — ROMs não possuem lógica de escrita em hardware.*

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Inicialização via \$readmemh**

A diretiva `$readmemh("bias.hex", mem)` instrui o simulador (e o Quartus, via MIF equivalente) a preencher o array `mem` com os valores hexadecimais do arquivo `bias.hex` antes de qualquer simulação começar. Cada linha do arquivo contém um valor de 4 dígitos hexadecimais correspondente a um bias em Q4.12 no formato complemento de dois.

O arquivo `bias.hex` é gerado pelo script `scripts/gen_hex.py` a partir do arquivo `b_q.txt` (pesos originais fornecidos pelo professor), convertendo cada inteiro para sua representação hexadecimal de 16 bits sem sinal (unsigned). Para valores negativos, aplica-se a operação `val & 0xFFFF` (módulo 65536), que produz exatamente a representação em complemento de dois de 16 bits.

### **3.2. Endereçamento Linear**

A rom\_bias é a única ROM do projeto com endereçamento de 1 dimensão. O endereço `addr` é diretamente o índice do neurônio, sem necessidade de composição de campos (`{campo_A, campo_B}`). Isso elimina qualquer risco de erro de mapeamento de endereço — a posição 0 contém sempre `b[0]`, a posição 127 contém sempre `b[127]`.

A FSM acessa a rom\_bias em paralelo com a rom\_pesos durante o estado `CALC_HIDDEN`: ambas recebem o mesmo `neuron_idx` e retornam seus dados respectivos no ciclo seguinte. A MAC então acumula `W_in[i][j] · x[j]` para todos os pixels `j` e, ao final do neurônio, soma `b[i]` lido da rom\_bias.

### **3.3. Latência de Leitura**

Identicamente às demais memórias síncronas do projeto, a leitura tem latência de 1 ciclo de clock. A FSM deve apresentar `addr = neuron_idx` um ciclo antes de precisar do valor do bias na entrada da MAC.

## **4\. Metodologia de Validação e Testbench (tb\_rom\_bias.v)**

O testbench foi adaptado para validar o módulo com os pesos reais do professor em vez de um padrão sintético, tornando a validação diretamente significativa para a qualidade do classificador.

* **TC-BIAS-01 — Leitura de b\[0\]:** *Justificativa:* Sanidade fundamental com o primeiro bias real. `b[0] = −710 → 0xFD3A`. Confirma que a inicialização via `$readmemh` funcionou, que o bit de sinal está preservado (valor negativo representado corretamente em complemento de dois) e que o endereço base retorna o valor correto.

* **TC-BIAS-02 — Leitura de b\[127\] (endereço máximo):** *Justificativa:* `b[127] = 7146 → 0x1BEA`. Verifica que os 7 bits de endereço cobrem completamente as 128 posições. Se `addr` fosse declarado com apenas 6 bits, `7'd127` seria truncado para `6'd63`, mapeando o último bias para a posição do neurônio 63 — um erro silencioso que degradaria a acurácia dos neurônios 64 a 127.

* **TC-BIAS-03 — Varredura completa (128 posições):** *Justificativa:* Compara cada posição lida do DUT com um array `expected[]` carregado diretamente do mesmo `bias.hex` que inicializa a ROM. Qualquer divergência indica corrupção na inicialização ou erro de endereçamento. Este teste garante que todos os 128 neurônios ocultos recebem seus biases corretos antes da integração com a FSM.

## **5\. Conclusão da Fase**

Os 3 casos de teste resultaram em PASS durante a simulação RTL com os pesos reais fornecidos pelo professor. A rom\_bias demonstrou inicialização correta via `$readmemh`, preservação de valores negativos em Q4.12 e cobertura completa das 128 posições, estando apta para integração no datapath de inferência da camada oculta do elm\_accel.