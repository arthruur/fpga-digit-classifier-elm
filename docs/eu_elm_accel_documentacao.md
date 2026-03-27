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
| Memória    | rom_beta.v / ram_hidden.v | ROM dos pesos β e RAM das ativações h\[i\]                    |

**2. Fluxo Geral --- Caminho de um Pixel**

A seguir, o percurso completo de um único pixel desde a entrada da imagem até a predição final. Usamos o pixel x\[5\] (sexto pixel da imagem, valor=128) como exemplo concreto.

**Etapa 1 --- Carga da Imagem (Estado LOAD_IMG)**

O programa C lê o arquivo PNG e envia os 784 pixels ao driver. O driver, via MMIO, escreve cada pixel no registrador IMG do co-processador:

> data_in = {14\'b0, 8\'d128, 10\'d5} // pixel_data=128, pixel_addr=5

O reg_bank decodifica essa escrita: pixel_addr=5, pixel_data=128, we_img=1 por 1 ciclo. A ram_img grava 8\'h80 (128) na posição 5. A FSM conta 784 escritas e transiciona para CALC_HIDDEN.

**Etapa 2 --- Conversão para Q4.12**

Antes de entrar na MAC, cada pixel é convertido do domínio inteiro \[0..255\] para Q4.12 \[0..\~1.0\]:

> pixel_q412 = {4\'b0000, img_data, 4\'b0000}
>
> // pixel=128 → 0x0800 → +0.5 em Q4.12

Isso é equivalente a dividir por 256 (shift de 4 bits à direita), aproximando a normalização por 255 com erro máximo de 0.4%.

**Etapa 3 --- Cálculo da Camada Oculta (Estado CALC_HIDDEN)**

A FSM itera sobre 128 neurônios (i) × 784 pixels (j). Para cada par (i, j) em um ciclo de clock:

- A FSM apresenta addr_img=j para a ram_img e addr_w={i,j} para a rom_pesos

- No ciclo seguinte (latência BRAM=1), img_data e weight_data ficam disponíveis

- O mux de entrada da MAC seleciona: mac_a=pixel_q412, mac_b=weight_data

- A MAC acumula: acc += W\[i\]\[j\] × x\[j\]

Quando j=783 (fim do neurônio i), a FSM ativa mac_clr=1 e we_hidden=1 no mesmo ciclo. Neste ciclo, a pwl_activation calcula h\[i\] = tanh_pwl(acc) de forma combinacional e a ram_hidden grava h\[i\] na posição i. O acumulador é limpo para o próximo neurônio.

Exemplo concreto para o pixel x\[5\]=0.5 contribuindo para o neurônio 0:

> acc += W\[0\]\[5\] × 0.5 // W\[0\]\[5\] é um valor Q4.12 fixo da ROM

**Etapa 4 --- Cálculo da Camada de Saída (Estado CALC_OUTPUT)**

A FSM itera sobre 10 classes (k) × 128 neurônios ocultos (i). O mux de entrada da MAC agora seleciona: mac_a=h_rdata (lido de ram_hidden), mac_b=beta_data (lido de rom_beta). A acumulação computa y\[k\] = Σ β\[k\]\[i\] × h\[i\].

Ao fim de cada classe (i=127), mac_clr=1 e we_hidden=0 --- isso ativa y_capture, que captura acc_out em y_buf\[k\]. Diferente da camada oculta, não há ativação PWL aqui (camada linear).

**Etapa 5 --- Argmax (Estado ARGMAX)**

O bloco argmax_block recebe os 10 scores y_buf\[0..9\] um por ciclo. Usa comparação signed (\$signed) para lidar com scores negativos. Após 10 ciclos, done=1 e max_idx contém o índice do maior score --- o dígito previsto.

**Etapa 6 --- Resultado (Estado DONE)**

A FSM transiciona para DONE por exatamente 1 ciclo: result_out=max_idx, status=DONE, done_out=1. O reg_bank atualiza os registradores STATUS e RESULT. O ARM detecta STATUS=DONE via polling e lê RESULT\[3:0\] --- o dígito previsto. A FSM retorna ao IDLE automaticamente.

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
