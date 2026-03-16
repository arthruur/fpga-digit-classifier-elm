Documentação Técnica: Módulo pwl_activation

Aproximação Piecewise Linear (PWL) da Função Tanh em Hardware

1. Visão Geral

O módulo pwl_activation.v é o responsável por aplicar a função de ativação não-linear nos neurônios da camada oculta do co-processador ELM. Ele aproxima matematicamente a função tangente hiperbólica ($tanh(x)$) utilizando uma técnica de retas conectadas (Piecewise Linear).

Características Principais da Arquitetura:

Latência Zero: É um circuito puramente combinacional. Não possui clock, registradores ou memória (BRAM). A saída y_out é gerada no mesmo ciclo de clock em que x_in é fornecido.

Formatos de Dados: Opera exclusivamente em Ponto Fixo com sinal Q4.12 (16 bits).

Eficiência de Área: Não utiliza multiplicadores de hardware (DSP slices). Todas as multiplicações de inclinação (slopes) são feitas através de deslocamentos de bits (shifts) e somas.

2. Interface do Módulo


- x_in: Entrada de 16 bits representando o valor de entrada proveniente do acumulador (Unidade MAC). Formato Q4.12 signed.
- y_out Saída de 16 bits representando o resultado da ativação $tanh(x)$, limitado à faixa de $[-1.0, +1.0]$. Formato Q4.12 signed.

3. Filosofia de Funcionamento (Os 5 Passos do Datapath)

A lógica interna foi dividida em 5 etapas sequenciais que o sinal elétrico percorre instantaneamente:

Passo 1: O "Truque do Espelho" e a Proteção contra o -32768

A função $tanh(x)$ é uma função ímpar, ou seja, $f(-x) = -f(x)$. Para economizar hardware, o módulo trabalha apenas com a parte positiva do gráfico ($|x|$).
Nesta etapa, o sinal de entrada é extraído e armazenado. Em seguida, calcula-se o valor absoluto.

A Proteção de Overflow: Existe uma assimetria no formato de Complemento de 2 (o limite negativo é $-32768$, mas o máximo positivo é $+32767$). Tentar fazer o absoluto de $-32768$ causaria um overflow silencioso, mantendo o número negativo e quebrando toda a lógica seguinte. O módulo possui uma blindagem explícita: se a entrada for 0x8000 ($-32768$), o absoluto é forçado para o máximo positivo suportado 0x7FFF.

Passo 2: Multiplicação "Grátis" via Shifts

As retas que aproximam a função possuem inclinações (slopes) baseadas em potências de 2 (ex: $1/2$, $1/8$, $1/16$). Em vez de usar multiplicadores caros na FPGA, o módulo divide o valor de entrada empurrando seus bits para a direita (Shift Aritmético >>>).
Exemplo: Para multiplicar por $5/8$, o hardware simplesmente calcula $(x \gg 1) + (x \gg 3)$.

Passo 3: Computação Paralela dos Segmentos

O hardware não espera para saber em qual reta o x está para fazer a conta. Ele calcula o valor de $y$ para todos os 5 segmentos simultaneamente. A equação de cada reta é y = slope * x + B (onde B é o intercepto/constante ajustada para continuidade perfeita).

Passo 4: O Multiplexador "Juiz" e Saturação

Com as 5 possíveis respostas prontas, um bloco de multiplexadores aninhados (implementado via operadores ternários ? :) compara o valor de $|x|$ contra os limites de cada segmento (breakpoints: $0.25, 0.5, 1.0, 1.5$ e $2.0$).

Saturação: Se $|x| \ge 2.0$, o módulo ignora os cálculos das retas e trava a saída interna em 0x1000 ($+1.0$).

Seleção: Caso contrário, ele "abre a porteira" do segmento em que o valor se encaixa perfeitamente, garantindo que não existam degraus (descontinuidades) no gráfico gerado.

Passo 5: O Espelhamento Final

Se o sinal extraído no Passo 1 indicava que a entrada original era negativa, o módulo inverte o sinal da resposta final escolhida pelo multiplexador. Caso contrário, a resposta sai inalterada. Isso garante a simetria perfeita da função tangente hiperbólica no hardware.