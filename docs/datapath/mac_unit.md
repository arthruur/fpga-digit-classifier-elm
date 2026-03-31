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

### **2.3. Detecção de Overflow do Acumulador (Correção v2)**

Além da saturação do produto individual (seção 2.2), existe uma verificação independente sobre o resultado da acumulação (`acc_next`). As duas verificações são distintas e podem ser acionadas em momentos diferentes:

- **Overflow de produto:** ocorre quando um único `a × b` já excede o range Q4.12. Detectado nos bits `[31:27]` do produto bruto de 32 bits.
- **Overflow de acumulador:** ocorre quando a soma acumulada ultrapassa o range, mesmo que cada produto individual seja válido. Detectado nos bits `[31:15]` de `acc_next`.

A verificação do acumulador usa o range `[31:15]` porque `acc_internal` armazena valores Q4.12 sign-extendidos em 32 bits. Para que `acc_next[15:0]` seja um Q4.12 válido, os bits `[31:15]` devem ser todos iguais — extensão de sinal uniforme. Se não forem, houve overflow.

> **Correção aplicada (v2):** a versão inicial verificava apenas `[31:28]`, o que só detectava overflows acima de 2²⁸ (~268 milhões). Valores acumulados entre 32.768 e 268 milhões passavam sem saturar, produzindo wrap-around silencioso no `acc_out`. A correção para `[31:15]` elimina essa janela cega.

### **2.4. Acumulação e Controle (Registradores)**

A lógica de acúmulo é regida por um bloco sequencial síncrono com o clock:

* **acc\_next (Calculadora Combinacional):** Um somador puro que soma o valor armazenado no acumulador com o produto truncado/saturado recém-chegado.  
* **mac\_en (Habilitação):** Controla a teia de multiplexadores (Muxes) de realimentação. Se estiver em nível baixo, o registrador realimenta seu próprio valor (mantém estado).  
* **mac\_clr (Clear Síncrono):** Sinal gerado pela Máquina de Estados (FSM) para zerar a MAC entre os cálculos de diferentes neurônios. Ele age de forma **síncrona**, ou seja, zera o registrador apenas na borda de subida do clock, garantindo imunidade a *glitches* transientes da lógica de controle combinacional. O `mac_clr` também limpa o flag `is_saturated` (ver abaixo).
* **is\_saturated (Travamento Pós-Saturação):** Flag interna que indica que o acumulador atingiu um limite de saturação em algum ciclo anterior. Uma vez setada, a MAC congela `acc_internal` e `acc_out` no valor saturado (`0x7FFF` ou `0x8000`) pelos ciclos seguintes, ignorando novas acumulações. O flag `overflow` desce para 0 após o primeiro ciclo de saturação — ele é um pulso de 1 ciclo, não um nível permanente. O estado é encerrado apenas quando `mac_clr=1` ou `rst_n=0`, que limpam `is_saturated` e zeram o acumulador.

## **3\. Metodologia de Validação e Testbench (tb\_mac.v)**

Para garantir a confiabilidade do bloco antes da integração com a FSM, foi desenvolvido um testbench exaustivo com **14 casos de teste** simulados via **Icarus Verilog**. O plano cobre operações normais, casos extremos numéricos, sinais de controle e o comportamento de travamento pós-saturação.

* **TC-MAC-01 — Reset limpa o acumulador:** *Justificativa:* Teste de sanidade inicial. Confirma que após `rst_n=0`, `acc_out` e `overflow` retornam a zero, garantindo que nenhuma inferência comece com estado residual.

* **TC-MAC-02 — mac\_clr tem prioridade sobre mac\_en:** *Justificativa:* Quando ambos os sinais são assertados simultaneamente, `mac_clr` deve vencer. Garante que a FSM pode zerar o acumulador de forma segura mesmo que `mac_en` esteja ativo por overlap de controle.

* **TC-MAC-03 — mac\_en=0 mantém o acumulador estável:** *Justificativa:* Verifica por 5 ciclos consecutivos que o acumulador retém seu valor quando a habilitação está desativada, mesmo com `a` e `b` oscilando em valores altos. Protege contra latch inference indevida.

* **TC-MAC-04 — +1.0 × +1.0 = +1.0:** *Justificativa:* Multiplicação de referência. Valida truncamento `[27:12]` e ausência de overflow para operandos nominais idênticos ao valor unitário Q4.12 (`0x1000`).

* **TC-MAC-05 — +0.5 × +0.5 = +0.25:** *Justificativa:* Verifica precisão fracionária do truncamento. O produto exato é `0x0400_0000` em Q8.24; `[27:12]` deve extrair `0x0400` (+0.25 em Q4.12).

* **TC-MAC-06 — +1.0 × −1.0 = −1.0:** *Justificativa:* Valida que o multiplicador opera em complemento de 2 com sinal. Um multiplicador inferido como `unsigned` produziria resultado completamente errado neste caso.

* **TC-MAC-07 — −1.0 × −1.0 = +1.0:** *Justificativa:* Regra de sinais: dois negativos devem produzir positivo. Complementar ao TC-MAC-06 — juntos provam o comportamento `signed` em ambas as polaridades.

* **TC-MAC-08 — Acumulação de 4 parcelas = +1.25:** *Justificativa:* Simula o padrão real da ELM (784 acumulações por neurônio). Verifica que `acc_internal` acumula corretamente sem perdas nem acionamento indevido da saturação em sequências normais.

* **TC-MAC-09 — Cancelamento: +1.0 + (−1.0) = 0:** *Justificativa:* Valida que a acumulação de valores opostos resulta em zero, confirmando o comportamento correto do somador com operandos negativos sign-extendidos.

* **TC-MAC-10 — Saturação positiva em +7.999 (0x7FFF):** *Justificativa:* 8 acumulações de +1.0 tentariam atingir +8.0, que excede o range Q4.12. O acumulador deve saturar em `0x7FFF` e permanecer travado. Sem `is_saturated`, o wrap-around produziria um valor negativo, invertendo a polaridade do neurônio.

* **TC-MAC-11 — Saturação negativa em −8.0 (0x8000):** *Justificativa:* Espelho negativo do TC-MAC-10. 8 acumulações de −1.0 devem saturar em `0x8000` e permanecer travadas.

* **TC-MAC-12 — Saturação permanente até mac\_clr (duas partes):** *Justificativa:* Valida diretamente o mecanismo `is_saturated`. Após saturação positiva, uma acumulação de −0.25 não deve reduzir o valor (`12a`). Só após `mac_clr=1` o acumulador deve zerar (`12b`). Garante que a saturação é um estado terminal, não um evento pontual.

* **TC-MAC-13 — Truncamento abaixo da resolução (1 LSB):** *Justificativa:* `a = b = 0x0001` (+1/4096 cada). O produto bruto é 1 em Q8.24 — abaixo de `product[12]` — então `[27:12]` extrai zero. Verifica que o truncamento não gera ruído em produtos abaixo da resolução Q4.12.

* **TC-MAC-14 — mac\_clr seguido de nova acumulação imediata:** *Justificativa:* Confirma que após `mac_clr=1`, o acumulador pode receber nova acumulação já no ciclo seguinte sem delay. Simula a transição real entre neurônios na FSM, onde CALC\_HIDDEN usa `mac_clr` e retoma `mac_en` imediatamente.

## **4\. Conclusão da Fase**

Os 14 casos de teste resultaram em PASS durante a simulação RTL. A unidade demonstrou precisão matemática no truncamento Q4.12, robustez no tratamento de overflows com saturação permanente via `is_saturated`, e comportamento correto de todos os sinais de controle, estando apta para a integração no datapath superior e interconexão com as memórias ROM da rede neural.