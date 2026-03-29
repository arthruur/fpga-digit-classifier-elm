**elm_accel**

Co-processador ELM em FPGA

*Documentação Técnica --- Marco 1*

TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**1. Visão Geral do Sistema**

O elm_accel é um co-processador dedicado à inferência de uma rede neural Extreme Learning Machine (ELM) para classificação de dígitos manuscritos MNIST (0--9). O sistema é implementado em Verilog RTL e sintetizado para a FPGA Cyclone V da placa DE1-SoC.

A rede ELM recebe como entrada uma imagem 28×28 pixels em escala de cinza e retorna o dígito previsto (0..9). O processamento é sequencial --- um único bloco MAC reutilizado em loop --- o que minimiza o uso de recursos da FPGA às custas de latência (\~2 ms por imagem a 50 MHz).

**1.1 Hierarquia de Módulos**

O sistema é composto por 10 módulos Verilog organizados em três camadas:

| **Camada** | **Módulo**                | **Função**                                                    |
|------------|---------------------------|---------------------------------------------------------------|
| Top-level  | top_demo.v                | Interface com a placa DE1-SoC (switches, LEDs, display 7-seg) |
| Top-level  | elm_accel.v               | Instancia e interconecta todos os submódulos                  |
| Controle   | reg_bank.v                | Decodifica MMIO --- interface ARM ↔ co-processador            |
| Controle   | fsm_ctrl.v                | Máquina de estados --- orquestra o cálculo                    |
| Datapath   | mac_unit.v                | Multiplicador-acumulador em Q4.12                             |
| Datapath   | pwl_activation.v          | Aproximação piecewise linear do tanh                          |
| Datapath   | argmax_block.v            | Comparador sequencial dos 10 scores                           |
| Memória    | ram_img.v                 | BRAM 784×8 bits --- pixels da imagem                          |
| Memória    | rom_pesos.v / rom_bias.v  | ROM dos pesos W_in e biases b                                 |
| Memória    | rom_beta.v / ram_hidden.v | ROM dos pesos β e RAM das ativações h[i]                    |

**2. Fluxo Geral - Caminho de um Pixel**

Para ilustrar o funcionamento do co-processador, acompanharemos o caminho de um único pixel (ex: **x[5]**, sexto pixel da imagem, com valor **128**) desde a entrada até a predição final.

### Etapa 1: Carga da Imagem (HPS → co-processador)

Nessa etapa o programa lê o arquivo PNG e envia os 784 pixels ao driver. O driver, via MMIO, escreve cada pixel no registrador IMG do co-processador. 

Para a demonstração diretamente na placa do marco 1 já existirão 10 imagens pré-carregadas via inicialização do quartus, sendo possível escolher qual imagem está sendo carregada no registrador via chaves. Porém o processo de escrever cada pixel no registrador IMG é o mesmo. Para o marco 1 só muda a forma que esses dados estão chegando no registrador.

data_in = {14'b0, 8'd128, 10'd5} // pixel_data=128, pixel_addr=5

Estrutura do registrador IMG (32 bits): 
- [31:18]: 14 bits zeros (não usados), representado por 14'b0 
- [17:10]: 8 bits de pixel_data (0..255), representado por 8'd128 
- [9:0]: 10 bits de pixel_addr (0..783), representado por 10'd5

Quando o ARM escreve no offset 0x08, o reg_bank faz três coisas simultaneamente na mesma borda de clock: 
- captura o endereço (pixel_addr <= data_in[9:0];)
- captura o valor do pixel (pixel_data <= data_in[17:10];)
- autoriza a escrita na RAM (we_img_out <= 1;) 

No ciclo seguinte, automaticamente o sinal we_img_out volta para 0, se ele ficasse em 1, ram_img escreveria o mesmo pixel repetidamente a cada clock, corrompendo qualquer leitura posterior. Esse sinal we_img_out chega ao top-level como we_img_rb.Como a ram_img é single-port, leitura e escrita usam o mesmo barramento, e isso é decidido pelo seguinte trecho no módulo top_level:

wire [9:0] ram_img_addr = we_img_rb ? pixel_addr : addr_img;

No ciclo em que `we_img_rb=1` o mux seleciona `pixel_addr` como endereço e a RAM grava o `pixel data` nesse endereço. Nos demais ciclos, `we_img_rb=0` o mux seleciona `addr_img` (contador j da FSM) e a ram recebe `we=0`. É um sinal que controla duas coisas com um único bit, endereçamento e autorização de escrita. 

Depois que o reg_bank decodifica essa escrita, a ram_img grava 8'h80 (128) na posição 5. Depois que a FSM contar as 784 escritas (todos os pixels da imagem), o estado será transicionado para CALC_HIDDEN. o que nos leva para a próxima etapa. 

### Etapa 2: Conversão para Ponto Fixo (Inteiro → Q4.12)

Já no estado de CALC_HIDDEN. Antes de entrar na MAC, cada pixel é convertido de inteiro para Q4.12 no seguinte trecho:

wire  [7:0] img_data;           // pixel lido de ram_img
pixel_q412 = {4'b0000, img_data, 4'b0000}

Isso é o equivalente a dividir por 256 (shift de 4 bits à direita), porque quando isso é feito está sendo criado o seguinte mapa de bits do formato inteiro para o Q4.12: 


- 4'b0000: Bit de sinal [15] e parte inteira [15:12]
- img_data: Os dados originais [11:4]
- 4'b0000: Preenchimento fracionário [3:0]

Para qualquer pixel válido (0..255), a parte inteira sempre será zero. 

O maior pixel possível é 255: 

{0000, 1111_1111, 0000} = 0x0FF0 / 4096 = 4080/4096 = 0.996

O valor máximo representado é ~0.996, sempre menor que 1.0. Os 4 bits da parte inteira ficam em zero porque pixels normalizados vivem no intervalo [0, 1), que em Q4.12 nunca precisa da parte inteira.

A concatenação `{4'b0000, img_data, 4'b0000}` é equivalente a `img_data << 4` — desloca o pixel 4 bits para a esquerda dentro da palavra de 16 bits. Isso é um shift aritmético implementado **apenas com roteamento de fios** — zero lógica, zero ciclos, zero recursos.

O efeito matemático é multiplicar o pixel por 16:
```
pixel=128 → 128 × 16 = 2048 = 0x0800
```

Como o denominador implícito do Q4.12 é 4096, o valor representado é:
```
2048 / 4096 = 0.5
```

Que é equivalente a `128 / 256` — daí a aproximação de `pixel/255 ≈ pixel/256`.

### Etapa 3: Cálculo da Camada Oculta

A FSM itera sobre os 128 neurônios (com o contador i) x 784 pixels (com o contador j). e para cada neurônio percorre 787 ciclos:

- Ciclo j=0 nesse ciclo ocorre o warmup A FSM apresenta `addr_img=0` e `addr_w={i,0}` para as BRAMs. `mac_en=0`. a MAC não acumula porque os dados ainda não estão disponíveis (latência de 1 ciclo das BRAMs).

- Ciclos j=1..784 nesses ciclos ocorrem a acumulação dos pixels. A cada ciclo, `img_data` (128 convertido para Q4.12 para o nosso exemplo) e `weight_data` (W[i][5]) para o nosso exemplo, estão disponíveis (pedidos no ciclo anterior). O mux seleciona `mac_a=pixel_q412` e `mac_b=weight_data`. Porque `bias_cycle=0` e `calc_output_active=0`. A MAC acumula `acc += W[i][j-1] * x[j-1]`.
- Ciclo j=785 nesse ciclo a FSM ativa `bias_cycle=1`e o mux seleciona `mac_a=bias_data` e `mac_b=0x1000`. Essa mudança nos operando se dá porque a MAC só sabe fazer acc += a × b. Não existe operação acc += b isolada. O truque b[i] × 1.0 usa o multiplicador existente para fazer uma adição pura, multiplicar por 1.0 é matematicamente neutro e não altera o valor do bias. Nesse ciclo, o acc já tem dentro dele a soma de todos os 784 produtos — o bias é simplesmente somado em cima desse resultado acumulado, e o acumulador passa a conter `W[i]*x + b[i]`, o argumento completo para a função de ativação
- Ciclo j=786 nesse ciclo `acc_out` ainda reflete `W[i]*x + b[i]`, a PWL calcula `pwl_out = tanh_aprox(acc_out)`.e a `ram_hidden` grava `h[i]= pwl_out` no endereço `i[6:0]. Na borda de clock o acumulador zera para repetir o processo no próximo neurônio. A função de ativação é calculada instantâneamente de forma combinacional (devido aos shifts e somas que implementam essa aproximação) e fica ligada direto na saída da MAC e na entrada da ram_hidden, dependendo apenas da FSM habilitar a escrita no momento correto (quando a acumulação terminar) e indicar o endereço correspondente do neurônio que foi processado (endereço ram_hidden = i[6:0]). 

Nesse ciclo os sinais `mac_en=0` que desabilita a acumulação da MAC e `mac_clr=1` limpa os valores para a acumulação do próximo neurônio. `h_capture` é um sinal redundante com `we_hidden` pois os dois são ativados no mesmo ciclo e desativados juntos. `h_capture` existe por uma questão de documentação semântica. `we_hidden`diz "escreva na RAM". `h_capture` diz "estamos capturando a saída da PWL", ele transmite a intenção do ciclo mas não necessariamente tem uma função diferente. Arquiteturalmente existe para deixar o código mais legível e para facilitar a instrumentação futura. 

Exemplo concreto para o pixel x[5]=0.5 contribuindo para o neurônio i:

acc += W[i][5] × 0.5 // W[i][5] são valores Q4.12 fixos da ROM dos pesos

### Etapa 4: Cálculo da Camada de Saída

Nessa etapa a FSM itera sobre as 10 classes (k) x 128 neurônios ocultos (i). O mux de entrada da mac agora seleciona `mac_a = h_rdata` (lido da ram_hidden), `mac_b = beta_data` (lido de rom_beta). A acumulação computa `y[k] = \sum _beta[k][i] * h[i]`. 

Assim como na CALC_HIDDEN, CALC_OUTPUT também tem a estrutura de 3 fases por classe: 
- Ciclo i=0 também ocorre o warmup, os endereços `addr_hidden=0` e `addr_bias=0` apresentados para as BRAMs. `mac_en=0` a MAC não acumula porque os dados ainda não estão disponíveis (latência de 1 ciclo das BRAMs).
- Ciclos i=1..127 nesses ciclos ocorrem a acumulação de `y[k] = _beta[k][i-1]*h[i-1]` 
- Ciclo i=129 nesse ciclo ocorre a captura de `y[k]` + clear (mac_clr=1, mac_en=0, we_hidden=0).

Totalizando 130 ciclos por classe * 10 classe = 1300 ciclos. Vale ressaltar que na CALC_HIDDEN não há um ciclo de bias, visto que a camada de saída é puramente linear (y[k] = _beta[:,k]*h), sem termo independente.

A lógica de captura é controlada pelo wire: `y_capture = mac_clr && !we_hidden;` porque a `mac_clr=1` sempre marca o fim de um cálculo (seja na etapa de hidden ou output) e o sinal `we_hidden=0` distingue CALC_OUTPUT de CALC_HIDDEN (em CALC_HIDDEN, we_hidden=1, junto com mac_clr=1). Quando o sinal de `y_capture` está ativo, então é feita a acumulação no buffer, pelo o trecho `y_buf[k_out] <= acc_out;`, onde o valor que está saindo do acumulador (`acc_out`) é copiado para a posição `k_out` (o índice do dígito atual) no buffer.


### Etapa 5: Argmax e Predição (Estado ARGMAX)

O bloco argmax_block recebe os 10 scores `y_buf[0..9]` um por ciclo. Usa comparação signed para lidar com os scores negativos. Após 10 ciclos, `done=1` e max_idx contém o índice do maior score. o dígito previsto.

### Etapa 6: Disponibilização do Resultado (Estado DONE)

A FSM transiciona para DONE por exatamente 1 ciclo: `result_out=max_idx`, `status=DONE`, `done_out=1`. O reg_bank atualiza os registradores STATUS e RESULT. O ARM detecta STATUS=DONE via polling e lê o RESULT[3:0]. O dígito previsto. A FSM retorna ao IDLE automáticamente.

O caminho do resultado sai do `argmax_block` e chega ao ARM em 3 passos: 

- Captura no estado ARGMAX(fsm_ctrl.v): a captura acontece no estado ARGMAX, não em done. Quando `argmax_done=1` o bloco sequencial da FSM captura `max_idx` em `result_out`na mesma borda de clock que transiciona para DONE. Isso garente que `result_out` esteja estável quando a FSM entra em DONE, sem o atraso de 1 ciclo. 
- Exposição pelo `reg_bank`: O `reg_bank` recebe continuamente `status_in` e `pred_in` vindos da FSM e os expõe via leitura MMIO: 
- Polling e leitura pelo ARM: O código implementado em C no processador ARM deve implementar um polling contínuo no STATUS. O campo bits[1:0] do STATUS muda de `01` BUSY para `10` DONE. o ARM detecta essa transição e lê `RESULT`

O registrador CYCLES congela com a latência total. A FSM retorna automaticamente para IDLE no ciclo seguinte, pronta para nova inferência.

**3. Documentação por Bloco**

**3.1 top_demo.v --- Demo Standalone na DE1-SoC**

Módulo de interface física com a placa. Permite demonstrar o sistema sem precisar de um computador ARM conectado --- tudo é controlado pelas chaves e botões da DE1-SoC.

**Portas**

| **Porta**   | **Direção** | **Descrição**                                           |
|-------------|-------------|---------------------------------------------------------|
| CLOCK_50    | input       | Clock de 50 MHz da placa (pino AF14)                    |
| SW\[9:0\]   | input       | Chaves: SW\[i\]=1 seleciona o dígito i para classificar |
| KEY0        | input       | Botão de start (ativo baixo) --- inicia inferência      |
| KEY1        | input       | Botão de reset (ativo baixo) --- reinicia sistema       |
| HEX0\[6:0\] | output      | Display 7-segmentos: dígito predito pela rede           |
| HEX1\[6:0\] | output      | Display 7-segmentos: dígito selecionado pelas chaves    |
| LEDR0       | output      | LED: aceso durante processamento (BUSY)                 |
| LEDR1       | output      | LED: aceso quando resultado disponível (DONE)           |
| LEDR2       | output      | LED: aceso em caso de erro (ERROR)                      |

**Máquina de Estados Interna**

O top_demo tem sua própria FSM de 6 estados que gerencia a comunicação MMIO com o elm_accel:

| **Estado**  | **Ação**                                               |
|-------------|--------------------------------------------------------|
| ST_IDLE     | Aguarda KEY\[0\] com debounce de 20 ms                 |
| ST_LOADING  | Escreve 784 pixels via registrador IMG (1 pixel/ciclo) |
| ST_STARTING | Escreve 0x01 em CTRL (start=1)                         |
| ST_CLEARING | Escreve 0x00 em CTRL (start=0)                         |
| ST_WAITING  | Polling em STATUS até DONE ou ERROR                    |
| ST_LATCHED  | Resultado travado --- aguarda novo KEY\[0\]            |

**Pontos de atenção**

- Debounce de 20 bits (2\^20 / 50MHz ≈ 20 ms) para KEY\[0\] --- evita múltiplos starts por um toque

- 10 ROMs independentes (rom0..rom9) carregadas via \$readmemh de arquivos digit_0.hex..digit_9.hex

- Reset guard de 255 ciclos após rst_n --- evita captura de STATUS espúrio na inicialização

- pred_latch e done_latch persistem entre inferências --- resultado visível até novo reset ou start

**3.2 elm_accel.v --- Top-Level do Co-processador**

Módulo integrador: instancia e conecta todos os 9 submódulos. Não contém lógica de cálculo --- é responsável pelo roteamento de sinais e pelas três lógicas de cola: conversão pixel→Q4.12, mux de entradas da MAC e captura do buffer y\[0..9\].

**Parâmetros**

| **Parâmetro** | **Default** | **Descrição**                                             |
|---------------|-------------|-----------------------------------------------------------|
| INIT_FILE     | \"\"        | Arquivo HEX para pré-carregar a ram_img (modo standalone) |
| PRELOADED_IMG | 0           | 1 = pula o estado LOAD_IMG (imagem já na RAM)             |

**Lógicas de Cola Internas**

- Conversão pixel→Q4.12: pixel_q412 = {4\'b0, img_data, 4\'b0} --- equivale a dividir por 256

- Mux MAC: seleciona (pixel,peso) em CALC_HIDDEN ou (h\[i\],beta) em CALC_OUTPUT ou (bias,1.0) no ciclo de bias

- Mux endereço ram_img: pixel_addr durante escrita ARM; addr_img da FSM durante leitura

- Buffer y_buf\[0..9\]: captura acc_out quando mac_clr=1 e we_hidden=0 (fim de cada classe)

- Controle argmax: gera argmax_start_pulse na borda de subida de argmax_en; argmax_k conta 0..9

**3.3 reg_bank.v --- Banco de Registradores MMIO**

Interface entre o processador ARM (ou top_demo) e o co-processador. Decodifica endereços de 32 bits e roteia leituras/escritas para os sinais corretos.

**Mapa de Registradores**

| **Offset** | **Nome** | **Acesso** | **Bits**                     | **Descrição**                                              |
|------------|----------|------------|------------------------------|------------------------------------------------------------|
| 0x00       | CTRL     | W          | \[0\]=start, \[1\]=reset     | Controle: inicia ou aborta inferência                      |
| 0x04       | STATUS   | R          | \[1:0\]=estado, \[5:2\]=pred | Estado atual da FSM + dígito previsto                      |
| 0x08       | IMG      | W          | \[9:0\]=addr, \[17:10\]=dado | Transferência de pixel: endereço + valor empacotados       |
| 0x0C       | RESULT   | R          | \[3:0\]=pred                 | Dígito previsto (0..9)                                     |
| 0x10       | CYCLES   | R          | \[31:0\]=ciclos              | Ciclos de clock desde START até DONE (medição de latência) |

**Comportamento**

- Escrita em CTRL\[0\]=1 → start_out pulsa por 1 ciclo → FSM sai do IDLE

- Escrita em CTRL\[1\]=1 → reset_out=1 → FSM retorna ao IDLE de qualquer estado

- Escrita em IMG → we_img_out=1 por exatamente 1 ciclo --- pulsos extras corromperiam a contagem da FSM

- Leitura é combinacional (always @\*) --- sem latência adicional para o ARM

- Endereço inválido em leitura → retorna 0x00000000 (comportamento seguro)

**3.4 fsm_ctrl.v --- Máquina de Estados de Controle**

Coração do co-processador. Orquestra todos os módulos sequenciando os cálculos da inferência ELM. Contém três blocos always com responsabilidades distintas.

**Estados e Transições**

| **Estado**            | **Condição de Saída**                    | **Próximo Estado** |
|-----------------------|------------------------------------------|--------------------|
| IDLE                  | start=1                                  | LOAD_IMG           |
| LOAD_IMG              | j=783 (784 pixels carregados)            | CALC_HIDDEN        |
| CALC_HIDDEN           | i=127 e j=783 (128 neurônios calculados) | CALC_OUTPUT        |
| CALC_OUTPUT           | k=9 e i=127 (10 classes calculadas)      | ARGMAX             |
| ARGMAX                | argmax_done=1                            | DONE               |
| DONE                  | automático após 1 ciclo                  | IDLE               |
| Qualquer estado ativo | overflow=1                               | ERROR              |
| ERROR                 | reset=1                                  | IDLE               |

**Contadores Internos**

| **Contador** | **Bits** | **Range** | **Usado em**                                  |
|--------------|----------|-----------|-----------------------------------------------|
| j            | 10       | 0..783    | LOAD_IMG e CALC_HIDDEN (loop de pixels)       |
| i            | 7        | 0..127    | CALC_HIDDEN e CALC_OUTPUT (loop de neurônios) |
| k            | 4        | 0..9      | CALC_OUTPUT (loop de classes)                 |

**Sinais de Controle por Estado**

| **Estado**          | **Sinais Ativos**                                     |
|---------------------|-------------------------------------------------------|
| LOAD_IMG            | we_img_fsm=1, addr_img=j, STATUS=BUSY                 |
| CALC_HIDDEN         | mac_en=1, addr_img=j, addr_w={i,j}, STATUS=BUSY       |
| CALC_HIDDEN (j=783) | mac_en=1, mac_clr=1, we_hidden=1, h_capture=1         |
| CALC_OUTPUT         | mac_en=1, addr_hidden=i, addr_beta={k,i}, STATUS=BUSY |
| CALC_OUTPUT (i=127) | mac_en=1, mac_clr=1 (aciona y_capture no elm_accel)   |
| ARGMAX              | argmax_en=1, STATUS=BUSY                              |
| DONE                | done_out=1, STATUS=DONE, result_out=max_idx           |
| ERROR               | STATUS=ERROR (aguarda reset externo)                  |

**3.5 mac_unit.v --- Unidade Multiply-Accumulate**

Realiza acc = acc + (a × b) em ponto fixo Q4.12 (16 bits signed). É o bloco computacional central --- executado 100.352 vezes para a camada oculta e 1.280 vezes para a camada de saída.

**Formato Q4.12**

| **Campo**         | **Bits**  | **Significado**                           |
|-------------------|-----------|-------------------------------------------|
| Sinal             | \[15\]    | 0=positivo, 1=negativo (complemento de 2) |
| Parte inteira     | \[14:12\] | 3 bits --- range 0..7                     |
| Parte fracionária | \[11:0\]  | 12 bits --- resolução 1/4096 ≈ 0.000244   |

**Operação**

- Multiplicação: product\[31:0\] = \$signed(a) × \$signed(b) --- produto completo Q8.24

- Truncamento: product_q412 = product\[27:12\] --- descarta os 12 bits fracionários inferiores

- Acumulação: acc_internal += product_q412 (sign-extended para 32 bits)

- Saturação positiva: se acc \> +7.9997, acc = 0x7FFF (congela até mac_clr)

- Saturação negativa: se acc \< -8.0, acc = 0x8000 (congela até mac_clr)

- mac_clr tem prioridade máxima sobre mac_en --- zera o acumulador imediatamente

**Correção de Bug Aplicada**

A detecção de overflow foi corrigida de acc_next\[31:28\] para acc_next\[31:15\]. A razão: o acumulador interno é de 32 bits mas o resultado válido Q4.12 ocupa apenas os bits \[15:0\]. Os bits \[31:15\] devem ser todos iguais (extensão de sinal) para que o valor seja representável em Q4.12. Verificar apenas \[31:28\] deixava valores entre 32.768 e 268M passarem sem saturar.

**3.6 pwl_activation.v --- Ativação Piecewise Linear**

Aproxima a função tanh(x) por 5 segmentos lineares usando apenas shifts e somas --- sem multiplicadores, sem ROM, sem registradores. Latência zero ciclos (resultado disponível no mesmo ciclo da entrada).

**Segmentos de Aproximação (semiplano positivo)**

| **Segmento** | **Intervalo \|x\|** | **Fórmula**            | **Slope (implementação)**   |
|--------------|---------------------|------------------------|-----------------------------|
| 1            | \[0, 0.25)          | y = \|x\|              | 1 (direto)                  |
| 2            | \[0.25, 0.5)        | y = 7/8·\|x\| + 0.029  | \|x\| - \|x\|\>\>\>3        |
| 3            | \[0.5, 1.0)         | y = 5/8·\|x\| + 0.156  | \|x\|\>\>\>1 + \|x\|\>\>\>3 |
| 4            | \[1.0, 1.5)         | y = 5/16·\|x\| + 0.453 | \|x\|\>\>\>2 + \|x\|\>\>\>4 |
| 5            | \[1.5, 2.0)         | y ≈ 1/8·\|x\| + 0.717  | \|x\|\>\>\>3 + \|x\|\>\>\>9 |
| Saturação    | \|x\| ≥ 2.0         | y = +1.0               | constante 0x1000            |

Para x\<0, a propriedade de função ímpar é aplicada: y = -y_pos. MAE teórico ≈ 0.0049 em relação ao tanh exato em float64.

**3.7 argmax_block.v --- Bloco Argmax Sequencial**

Encontra o índice do maior score dentre os 10 valores y\[0..9\] usando um único comparador signed de 16 bits, iterando por 10 ciclos consecutivos.

**Interface de Controle**

| **Sinal** | **Direção** | **Descrição**                                                  |
|-----------|-------------|----------------------------------------------------------------|
| start     | input       | Pulso de 1 ciclo: reinicia a busca (max_val = mínimo possível) |
| enable    | input       | 1 = escore válido presente --- avança a comparação             |
| y_in      | input       | Escore atual em Q4.12 signed (pode ser negativo)               |
| k_in      | input       | Índice do escore atual (0..9)                                  |
| max_idx   | output      | Índice do maior score após done=1                              |
| done      | output      | Pulso de 1 ciclo após os 10 escores comparados                 |

**Pontos de atenção**

- Comparação com \$signed() --- essencial pois scores podem ser negativos

- Empate: comparador usa \'\>\' estrito --- o primeiro índice encontrado vence

- max_val inicializa com 0x8000 (mínimo Q4.12) --- garante que o primeiro score sempre vença

- done=1 por exatamente 1 ciclo --- a FSM transiciona para DONE neste pulso

**3.8 Módulos de Memória**

Cinco módulos de memória armazenam todos os dados que circulam durante a inferência. O Quartus infere automaticamente BRAMs para todos eles quando detecta o padrão: array de reg + always @(posedge clk).

| **Módulo**   | **Tipo** | **Profundidade** | **Largura**   | **Endereço**                 | **Inicialização**    |
|--------------|----------|------------------|---------------|------------------------------|----------------------|
| ram_img.v    | RAM      | 784              | 8 bits        | 10 bits direto               | ARM via MMIO         |
| rom_pesos.v  | ROM      | 100.352          | 16 bits Q4.12 | 17 bits: {i\[6:0\],j\[9:0\]} | \$readmemh(w_in.mif) |
| rom_bias.v   | ROM      | 128              | 16 bits Q4.12 | 7 bits direto                | \$readmemh(bias.mif) |
| rom_beta.v   | ROM      | 1.280            | 16 bits Q4.12 | 11 bits: {k\[3:0\],i\[6:0\]} | \$readmemh(beta.mif) |
| ram_hidden.v | RAM      | 128              | 16 bits Q4.12 | 7 bits direto                | FSM (CALC_HIDDEN)    |

- Todas as memórias são síncronas --- latência de leitura de 1 ciclo de clock

- RAMs: escrita com we=1; leitura síncrona acontece sempre independente de we

- ROMs: sem porta de escrita em runtime --- conteúdo fixo gravado em síntese

- Endereços compostos (rom_pesos, rom_beta): concatenação de dois índices via operador {}

**4. Estimativa de Latência**

Com arquitetura sequencial (1 MAC, pipeline de leitura+cálculo) a 50 MHz:

| **Estado**   | **Ciclos** | **Cálculo**                                               |
|--------------|------------|-----------------------------------------------------------|
| LOAD_IMG     | 784        | 1 pixel por ciclo                                         |
| CALC_HIDDEN  | \~100.864  | 128 neurônios × \~788 ciclos (784 MACs + bias + overhead) |
| CALC_OUTPUT  | \~1.310    | 10 classes × \~131 ciclos (128 MACs + overhead)           |
| ARGMAX       | 10         | 1 score por ciclo                                         |
| Overhead FSM | \~10       | Transições entre estados                                  |
| TOTAL        | \~102.978  |                                                           |

Tempo estimado a 50 MHz: 102.978 / 50.000.000 ≈ 2,06 ms por imagem.

Nota: cada MAC custa 1 ciclo efetivo graças ao pipeline --- enquanto a MAC processa o pixel atual, a FSM já apresenta o endereço do próximo pixel às BRAMs. O custo sem pipeline seria 2 ciclos por MAC, totalizando \~200k ciclos por imagem.

**5. Mapa de Registradores MMIO**

Todos os registradores têm largura de 32 bits. O endereço base depende do Marco 2 (ponte HPS↔FPGA). No Marco 1, apenas os offsets são relevantes para o testbench.

| **Offset** | **Nome** | **Acesso** | **Bits relevantes** | **Semântica**                              |
|------------|----------|------------|---------------------|--------------------------------------------|
| 0x00       | CTRL     | W          | \[0\]=start         | Escrever 0x01: inicia inferência           |
| 0x00       | CTRL     | W          | \[1\]=reset         | Escrever 0x02: aborta e reinicia           |
| 0x04       | STATUS   | R          | \[1:0\]=estado      | 00=IDLE, 01=BUSY, 10=DONE, 11=ERROR        |
| 0x04       | STATUS   | R          | \[5:2\]=pred        | Dígito previsto (válido quando \[1:0\]=10) |
| 0x08       | IMG      | W          | \[9:0\]=addr        | Endereço do pixel (0..783)                 |
| 0x08       | IMG      | W          | \[17:10\]=dado      | Valor do pixel (0..255)                    |
| 0x0C       | RESULT   | R          | \[3:0\]=pred        | Dígito previsto em bits separados          |
| 0x10       | CYCLES   | R          | \[31:0\]=n          | Ciclos de clock da inferência              |

**6. Pendências para Entrega (Marco 1)**

| **Item**             | **Status**           | **Descrição**                                                    |
|----------------------|----------------------|------------------------------------------------------------------|
| Arquivos MIF/HEX     | Aguardando professor | w_in.mif, bias.mif, beta.mif --- pesos treinados da ELM          |
| digit_0..9.hex       | Aguardando geração   | Imagens MNIST em HEX para demo na placa                          |
| Golden model Python  | Pendente             | elm_golden.py com pwl_tanh_q412() e comparação Q4.12             |
| Testbench integração | Pendente             | tb_elm_accel.v --- simulação end-to-end com K vetores            |
| Síntese Quartus      | Pendente             | Compilar para Cyclone V e coletar LUT/FF/DSP/BRAM                |
| Script automação     | Pendente             | Makefile ou shell para compilar + simular + reportar pass/fail   |
| README.md            | Em progresso         | Requisitos, softwares, instalação, testes, análise de resultados |
