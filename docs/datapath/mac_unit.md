# **Documentação da Unidade MAC (mac\_unit.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 2

## **1\. Visão Geral**

A Unidade MAC (*Multiplier-Accumulator*) é o principal bloco de datapath do co-processador elm\_accel. Sua responsabilidade é computar o núcleo matemático da rede neural ELM: multiplicar as entradas (pixels da imagem ou sinais da camada oculta) pelos respectivos pesos sinápticos e acumular o resultado.

Para otimização de hardware na FPGA (Cyclone V), a unidade opera estritamente com aritmética de ponto fixo no formato **Q4.12** (16 bits).

* **Bit \[15\]:** Bit de sinal (Complemento de 2).  
* **Bits \[14:12\]:** Parte inteira (3 bits).  
* **Bits \[11:0\]:** Parte fracionária (12 bits).  
* **Intervalo de representação:** de \-8.0 (16'h8000) a \+7.999... (16'h7FFF).

### 1.1. Fundamentos Teóricos: Formato Q4.12 e Complemento de 2

Para compreender o funcionamento da unidade, é essencial entender a matemática subjacente a este formato:

**O que é o Complemento de 2?**
O Complemento de 2 é o padrão utilizado pelas arquiteturas computacionais para representar números negativos em binário. Neste formato, o bit mais à esquerda (bit mais significativo) atua como o bit de sinal: se for 0, o número é positivo; se for 1, o número é negativo. A grande vantagem desta abordagem em hardware é permitir que o mesmo circuito somador processe tanto somas como subtrações sem distinção matemática, otimizando drasticamente a utilização de portas lógicas e recursos na FPGA.

**Porquê o intervalo de -8.0 a +7.999...?**
Este limite é uma consequência matemática direta da representação em Complemento de 2 alocada numa estrutura de 16 bits dividida no formato Q4.12 (4 bits para a parte inteira com sinal e 12 bits para a parte fracionária):

- **Limite Positivo Máximo (+7.999...):** Obtém-se quando o bit de sinal é 0 e todos os restantes bits são 1 (16'h7FFF). Os 3 bits da parte inteira (111) equivalem a 7, e os 12 bits fracionários (111...1) equivalem a quase 1 (0.999755...), totalizando o teto positivo de +7.999...

- **Limite Negativo Máximo (-8.0):** Em Complemento de 2, a representação do número zero consome uma das combinações lógicas do lado positivo. Isto permite "descer" uma unidade extra no lado negativo. O menor número possível é alcançado definindo o bit de sinal a 1 e todos os restantes a 0 (16'h8000). Os 4 bits inteiros (1000) são lidos diretamente como -8, e a parte fracionária é 0, resultando num valor matemático exato de -8.0.

## **2\. Arquitetura e Lógica do Circuito (Datapath)**

O circuito foi projetado dividindo-se claramente a lógica combinacional (cálculos matemáticos) da lógica sequencial (armazenamento e controle temporal).

### **2.1. Multiplicação e Truncamento**

A multiplicação de dois operandos de 16 bits (a e b) gera um produto intermediário de 32 bits no formato Q8.24. Para realinhar este resultado ao barramento Q4.12, o circuito realiza um **truncamento extraindo os bits \[27:12\]**.

* **Por que \[27:12\]?** Os bits \[11:0\] formam a "poeira fracionária" extra gerada pela multiplicação e são descartados para caber nos 12 bits de fração originais. Os bits a partir do 28 em diante são os bits extras da parte inteira que teoricamente deveriam ser apenas extensões de sinal.

### **2.2. Lógica de Saturação Preventiva (Clamp)**

Durante a multiplicação de dois valores altos (ex: 7FFF \* 7FFF), o resultado bruto de 32 bits pode invadir os bits de sinal, gerando um *wrap-around* indesejado (um produto altamente positivo virando um número negativo após o truncamento).

Para mitigar isso, o circuito avalia os bits superiores (\[31:27\]) do produto bruto através de portas lógicas (comparadores Equal). Se esses bits não forem todos iguais ao bit de sinal da operação, um multiplexador desvia o fluxo de dados e força o valor máximo permitido (16'h7FFF para positivo ou 16'h8000 para negativo), atuando como uma barreira de saturação (*clamp*) antes mesmo da acumulação.

### **2.3. Acumulação e Controle (Registradores)**

A lógica de acúmulo é regida por um bloco sequencial síncrono com o clock:

* **acc\_next (Calculadora Combinacional):** Um somador puro que soma o valor armazenado no acumulador com o produto truncado/saturado recém-chegado.  
* **mac\_en (Habilitação):** Controla a teia de multiplexadores (Muxes) de realimentação. Se estiver em nível baixo, o registrador realimenta seu próprio valor (mantém estado).  
* **mac\_clr (Clear Síncrono):** Sinal gerado pela Máquina de Estados (FSM) para zerar a MAC entre os cálculos de diferentes neurônios. Ele age de forma **síncrona**, ou seja, zera o registrador apenas na borda de subida do clock, garantindo imunidade a *glitches* transientes da lógica de controle combinacional.

## **3\. Metodologia de Validação e Testbench (tb\_mac.v)**

Para garantir a confiabilidade do bloco antes da integração com a FSM, foi desenvolvido um testbench exaustivo simulando o comportamento via **Icarus Verilog**. O plano de testes cobre as operações normais, os casos extremos (limites numéricos) e os sinais de controle essenciais.

Abaixo, a justificativa para cada caso de teste abordado:

* **TC01 — Operação Nula (0 × 0 \= 0):** *Justificativa:* Teste base de sanidade. Garante que multiplicações por zero não gerem ruído e que o acumulador inicie e opere de forma neutra.  
* **TC02 — Limite Operacional Positivo (Máximo Q4.12 × 1.0):** *Justificativa:* Verifica se o multiplicador e o truncamento \[27:12\] conseguem lidar com os valores máximos nominais permitidos pela régua Q4.12 sem acionar falsos positivos na lógica de overflow.  
* **TC03 e TC04 — Saturação Positiva e Negativa (Overflow → Clamp):** *Justificativa:* Avalia a resposta ao pior risco apontado no projeto. No TC03 (estouro positivo), o resultado natural causaria *wrap-around* negativo; a MAC deve detectar, levantar a *flag* de erro por um ciclo, e travar a saída em 0x7FFF. O TC04 testa a mesma premissa para o limite inferior (0x8000). Se falhassem, a rede ELM poderia inverter completamente a polaridade de um neurônio fortemente ativado.  
* **TC05 — Sequência Síncrona (Acumula → Limpa → Acumula):** *Justificativa:* Valida a lógica do sinal mac\_clr. Prova que o clear é de fato **síncrono** (respeitando a borda do clock) e que limpa totalmente os contadores internos para que a próxima operação comece estritamente do zero, simulando a transição de cálculo de um neurônio para o outro.  
* **TC06 — Regra de Sinais (Dois Negativos \= Resultado Positivo):** *Justificativa:* Garante que o bloco Verilog está inferindo corretamente o multiplicador como signed (Complemento de 2). Multiplicadores unsigned tratariam números negativos como valores inteiros absurdamente altos, arruinando a inferência.  
* **TC07 — Precedência do Reset Global (rst\_n):** *Justificativa:* Confirma que o *reset* assíncrono do sistema, caso ativado no meio de uma imagem, tem prioridade sobre todas as outras lógicas e derruba o valor do acumulador de imediato.  
* **TC08 — Retenção de Estado (mac\_en \= 0):** *Justificativa:* Testa a integridade do "laço de realimentação" dos multiplexadores. Quando a FSM pausa a inferência, a MAC não pode perder os dados acumulados mesmo que os fios de entrada a e b continuem oscilando.  
* **TC09 — Acumulação Contínua Sem Overflow:** *Justificativa:* Simula um cenário real da ELM. Na prática, a MAC vai somar 784 vezes para processar a imagem. Este teste executa 4 somas consecutivas normais para comprovar que o acc\_internal consegue somar sequencialmente sem perdas e sem acionar as lógicas de saturação indevidamente.  
* **TC10 — Transparência da Saída no Clear:** *Justificativa:* Comprova que não há "registradores fantasmas" atrasando a saída. Quando o mac\_clr bate junto com o clock, o acc\_out (a vitrine do módulo) vai imediatamente para 16'h0000.

## **4\. Conclusão da Fase**

Os 10 casos de teste resultaram em PASS durante a simulação RTL. A unidade demonstrou precisão matemática no truncamento e robustez no tratamento de *overflows* com limites rígidos (clamp), estando apta para a integração no datapath superior e interconexão com as memórias ROM da rede neural.