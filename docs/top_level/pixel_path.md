# Fluxo Geral - Caminho de um Pixel

Para ilustrar o funcionamento do co-processador, acompanharemos o caminho de um único pixel (ex: **x[5]**, sexto pixel da imagem, com valor **128**) desde a entrada até a predição final.

## Etapa 1: Carga da Imagem (HPS → co-processador)

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

## Etapa 2: Conversão para Ponto Fixo (Inteiro → Q4.12)

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

## Etapa 3: Cálculo da Camada Oculta

A FSM itera sobre os 128 neurônios (com o contador i) x 784 pixels (com o contador j). e para cada neurônio percorre 787 ciclos:

- Ciclo j=0 nesse ciclo ocorre o warmup A FSM apresenta `addr_img=0` e `addr_w={i,0}` para as BRAMs. `mac_en=0`. a MAC não acumula porque os dados ainda não estão disponíveis (latência de 1 ciclo das BRAMs).

- Ciclos j=1..784 nesses ciclos ocorrem a acumulação dos pixels. A cada ciclo, `img_data` (128 convertido para Q4.12 para o nosso exemplo) e `weight_data` (W[i][5]) para o nosso exemplo, estão disponíveis (pedidos no ciclo anterior). O mux seleciona `mac_a=pixel_q412` e `mac_b=weight_data`. Porque `bias_cycle=0` e `calc_output_active=0`. A MAC acumula `acc += W[i][j-1] * x[j-1]`.
- Ciclo j=785 nesse ciclo a FSM ativa `bias_cycle=1`e o mux seleciona `mac_a=bias_data` e `mac_b=0x1000`. Essa mudança nos operando se dá porque a MAC só sabe fazer acc += a × b. Não existe operação acc += b isolada. O truque b[i] × 1.0 usa o multiplicador existente para fazer uma adição pura, multiplicar por 1.0 é matematicamente neutro e não altera o valor do bias. Nesse ciclo, o acc já tem dentro dele a soma de todos os 784 produtos — o bias é simplesmente somado em cima desse resultado acumulado, e o acumulador passa a conter `W[i]*x + b[i]`, o argumento completo para a função de ativação
- Ciclo j=786 nesse ciclo `acc_out` ainda reflete `W[i]*x + b[i]`, a PWL calcula `pwl_out = tanh_aprox(acc_out)`.e a `ram_hidden` grava `h[i]= pwl_out` no endereço `i[6:0]. Na borda de clock o acumulador zera para repetir o processo no próximo neurônio. A função de ativação é calculada instantâneamente de forma combinacional (devido aos shifts e somas que implementam essa aproximação) e fica ligada direto na saída da MAC e na entrada da ram_hidden, dependendo apenas da FSM habilitar a escrita no momento correto (quando a acumulação terminar) e indicar o endereço correspondente do neurônio que foi processado (endereço ram_hidden = i[6:0]). 

Nesse ciclo os sinais `mac_en=0` que desabilita a acumulação da MAC e `mac_clr=1` limpa os valores para a acumulação do próximo neurônio. `h_capture` é um sinal redundante com `we_hidden` pois os dois são ativados no mesmo ciclo e desativados juntos. `h_capture` existe por uma questão de documentação semântica. `we_hidden`diz "escreva na RAM". `h_capture` diz "estamos capturando a saída da PWL", ele transmite a intenção do ciclo mas não necessariamente tem uma função diferente. Arquiteturalmente existe para deixar o código mais legível e para facilitar a instrumentação futura. 

Exemplo concreto para o pixel x[5]=0.5 contribuindo para o neurônio i:

acc += W[i][5] × 0.5 // W[i][5] são valores Q4.12 fixos da ROM dos pesos

## Etapa 4: Cálculo da Camada de Saída

Nessa etapa a FSM itera sobre as 10 classes (k) x 128 neurônios ocultos (i). O mux de entrada da mac agora seleciona `mac_a = h_rdata` (lido da ram_hidden), `mac_b = beta_data` (lido de rom_beta). A acumulação computa `y[k] = \sum _beta[k][i] * h[i]`. 

Assim como na CALC_HIDDEN, CALC_OUTPUT também tem a estrutura de 3 fases por classe: 
- Ciclo i=0 também ocorre o warmup, os endereços `addr_hidden=0` e `addr_bias=0` apresentados para as BRAMs. `mac_en=0` a MAC não acumula porque os dados ainda não estão disponíveis (latência de 1 ciclo das BRAMs).
- Ciclos i=1..127 nesses ciclos ocorrem a acumulação de `y[k] = _beta[k][i-1]*h[i-1]` 
- Ciclo i=128 nesse ciclo ocorre a captura de `y[k]` + clear (mac_clr=1, mac_en=0, we_hidden=0).

Totalizando 130 ciclos por classe * 10 classes = 1300 ciclos. Vale ressaltar que na CALC_HIDDEN não há um ciclo de bias, visto que a camada de saída é puramente linear (y[k] = _beta[:,k]*h), sem termo independente.

A lógica de captura é controlada pelo wire: `y_capture = mac_clr && !we_hidden;` porque a `mac_clr=1` sempre marca o fim de um cálculo (seja na etapa de hidden ou output) e o sinal `we_hidden=0` distingue CALC_OUTPUT de CALC_HIDDEN (em CALC_HIDDEN, we_hidden=1, junto com mac_clr=1). Quando o sinal de `y_capture` está ativo, então é feita a acumulação no buffer, pelo o trecho `y_buf[k_out] <= acc_out;`, onde o valor que está saindo do acumulador (`acc_out`) é copiado para a posição `k_out` (o índice do dígito atual) no buffer.


## Etapa 5: Argmax e Predição (Estado ARGMAX)

O bloco argmax_block recebe os 10 scores `y_buf[0..9]` um por ciclo. Usa comparação signed para lidar com os scores negativos. Após 10 ciclos, `done=1` e max_idx contém o índice do maior score. o dígito previsto.

## Etapa 6: Disponibilização do Resultado (Estado DONE)

A FSM transiciona para DONE por exatamente 1 ciclo: `result_out=max_idx`, `status=DONE`, `done_out=1`. O reg_bank atualiza os registradores STATUS e RESULT. O ARM detecta STATUS=DONE via polling e lê o RESULT[3:0]. O dígito previsto. A FSM retorna ao IDLE automáticamente.

O caminho do resultado sai do `argmax_block` e chega ao ARM em 3 passos: 

- Captura no estado ARGMAX(fsm_ctrl.v): a captura acontece no estado ARGMAX, não em done. Quando `argmax_done=1` o bloco sequencial da FSM captura `max_idx` em `result_out`na mesma borda de clock que transiciona para DONE. Isso garente que `result_out` esteja estável quando a FSM entra em DONE, sem o atraso de 1 ciclo. 
- Exposição pelo `reg_bank`: O `reg_bank` recebe continuamente `status_in` e `pred_in` vindos da FSM e os expõe via leitura MMIO: 
- Polling e leitura pelo ARM: O código implementado em C no processador ARM deve implementar um polling contínuo no STATUS. O campo bits[1:0] do STATUS muda de `01` BUSY para `10` DONE. o ARM detecta essa transição e lê `RESULT`

O registrador CYCLES congela com a latência total. A FSM retorna automaticamente para IDLE no ciclo seguinte, pronta para nova inferência.
