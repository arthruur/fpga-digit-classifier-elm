# Especificação de Testes — Fase 4: FSM e Banco de Registradores
## Abordagem TDD (Test-Driven Development)

> **Como usar este documento**
> Cada caso de teste aqui descrito tem um `ID` único que é referenciado
> diretamente nos testbenches (ex: `// TC-FSM-01`). Leia a justificativa
> de cada caso antes de implementar o módulo — o objetivo do TDD é que
> os testes guiem as decisões de implementação, não o contrário.
>
> **Ordem obrigatória:** escreva TODOS os testbenches de um módulo antes
> de escrever uma linha do módulo em si. Só avance para o próximo módulo
> quando todos os testes do atual passarem.

---

## Convenções

**Mapa de registradores MMIO (32 bits cada):**

| Offset  | Nome    | Acesso | Descrição                                  |
|---------|---------|--------|--------------------------------------------|
| 0x00    | CTRL    | W      | Controle: bit[0]=start, bit[1]=reset       |
| 0x04    | STATUS  | R      | Estado: bits[1:0]=BUSY/DONE/ERROR, bits[5:2]=pred |
| 0x08    | IMG     | W      | Pixel: bits[9:0]=addr, bits[17:10]=dado    |
| 0x0C    | RESULT  | R      | Dígito previsto: bits[3:0]=pred (0..9)     |
| 0x10    | CYCLES  | R      | Ciclos de clock desde START até DONE       |

**Codificação do campo STATUS[1:0]:**

| Valor | Significado |
|-------|-------------|
| 2'b00 | IDLE        |
| 2'b01 | BUSY        |
| 2'b10 | DONE        |
| 2'b11 | ERROR       |

**Estados da FSM:**

| Estado       | Valor | Descrição                              |
|--------------|-------|----------------------------------------|
| IDLE         | 3'd0  | Aguardando start                       |
| LOAD_IMG     | 3'd1  | Recebendo pixels do ARM via MMIO       |
| CALC_HIDDEN  | 3'd2  | Calculando camada oculta (128 neurônios)|
| CALC_OUTPUT  | 3'd3  | Calculando camada de saída (10 classes) |
| ARGMAX       | 3'd4  | Determinando o índice do maior score   |
| DONE         | 3'd5  | Resultado disponível em RESULT         |
| ERROR        | 3'd6  | Erro detectado durante processamento   |

**Sinais de controle gerados pela FSM:**

| Sinal      | Descrição                                           |
|------------|-----------------------------------------------------|
| we_img     | Write enable da ram_img                             |
| we_hidden  | Write enable da ram_hidden                          |
| mac_en     | Habilita acumulação na MAC                          |
| mac_clr    | Limpa acumulador (entre neurônios/classes)          |
| h_capture  | Captura saída da PWL em ram_hidden                  |
| argmax_en  | Habilita comparação no bloco argmax                 |

**Critério de PASS:** igualdade bit a bit (`===`) salvo indicação contrária.

---

## Módulo 1: reg_bank.v

### Comportamento esperado (contrato do módulo)

```
Decodificador de endereço MMIO para os 5 registradores.

Escrita (write_en=1):
  addr=0x00 → CTRL:   bit[0] → start_out, bit[1] → reset_out
  addr=0x08 → IMG:    bits[17:10] → pixel_data, bits[9:0] → pixel_addr
              we_img_out=1 por 1 ciclo

Leitura (read_en=1):
  addr=0x04 → data_out = STATUS (montado a partir de sinais internos)
  addr=0x0C → data_out = RESULT (pred em bits[3:0])
  addr=0x10 → data_out = CYCLES (contador de ciclos)

Escrita em endereço inválido → ignorada silenciosamente
Leitura em endereço inválido → data_out = 0x00000000
```

---

### TC-REG-01 — Reset assíncrono limpa todos os registradores

**Motivação:**
Estado inicial indefinido nos registradores pode fazer a FSM
sair do IDLE espontaneamente ou retornar lixo em STATUS/RESULT.
Este é o teste de sanidade fundamental — deve passar antes
de qualquer outro.

**Sequência:**
1. Aplicar `rst_n=0` por 2 ciclos
2. Liberar `rst_n=1`
3. Verificar: `start_out=0`, `reset_out=0`, `data_out=0x00000000`

**Resultado esperado:** todos os sinais de saída em zero.

**O que falha se errar:** qualquer teste subsequente pode
produzir falso-positivo por estado residual.

---

### TC-REG-02 — Escrita em CTRL[0] gera start_out=1

**Motivação:**
O bit 0 do registrador CTRL é o único mecanismo pelo qual
o ARM pode iniciar uma inferência. Se não funcionar, o
sistema nunca sai do IDLE independente do software.

**Sequência:**
1. `write_en=1, addr=32'h00, data_in=32'h00000001`
2. Verificar `start_out=1` no ciclo seguinte
3. `write_en=1, addr=32'h00, data_in=32'h00000000`
4. Verificar `start_out=0`

**Resultado esperado:** `start_out` segue `data_in[0]`.

---

### TC-REG-03 — Escrita em CTRL[1] gera reset_out=1

**Motivação:**
O bit 1 do CTRL permite ao ARM abortar e reiniciar o
co-processador a qualquer momento. Fundamental para
recuperação de erros sem reinicializar toda a FPGA.

**Sequência:**
1. `write_en=1, addr=32'h00, data_in=32'h00000002`
2. Verificar `reset_out=1`
3. `write_en=1, addr=32'h00, data_in=32'h00000000`
4. Verificar `reset_out=0`

**Resultado esperado:** `reset_out` segue `data_in[1]`.

---

### TC-REG-04 — Escrita em IMG gera pixel_data, pixel_addr e we_img_out

**Motivação:**
O registrador IMG é o canal de transferência da imagem do
ARM para a ram_img. Os 10 bits baixos são o endereço do pixel
(0..783) e os 8 bits seguintes são o valor (0..255).
Um erro de mapeamento de bits faria todos os pixels serem
escritos no endereço 0 ou com valor errado.

**Sequência:**
1. `write_en=1, addr=32'h08, data_in=32'h0001FAB`
   (pixel_addr=0x1AB=427, pixel_data=0x00=0)

   Nota: data_in[9:0]=pixel_addr, data_in[17:10]=pixel_data
   Exemplo concreto: addr=100 (0x64), dado=200 (0xC8):
   data_in = {14'b0, 8'hC8, 10'h064} = 32'h00032064

2. Verificar `pixel_addr=10'h064`, `pixel_data=8'hC8`, `we_img_out=1`
3. No ciclo seguinte: verificar `we_img_out=0`
   (pulso de 1 ciclo apenas)

**Resultado esperado:** pixel_addr e pixel_data corretos,
we_img_out pulsa por exatamente 1 ciclo.

---

### TC-REG-05 — we_img_out dura exatamente 1 ciclo

**Motivação:**
Se we_img_out persistir por mais de 1 ciclo, o mesmo pixel
seria escrito múltiplas vezes na ram_img, corrompendo
pixels subsequentes. A FSM conta exatamente 784 escritas —
pulsos extras quebrariam esse contador.

**Sequência:**
1. Escrever em IMG uma vez
2. Monitorar we_img_out por 3 ciclos
3. Verificar: ciclo 1=1, ciclo 2=0, ciclo 3=0

**Resultado esperado:** `we_img_out=1` apenas no ciclo da escrita.

---

### TC-REG-06 — Leitura de STATUS retorna campo correto

**Motivação:**
O ARM faz polling em STATUS para saber quando a inferência
terminou. Se STATUS retornar valor errado, o ARM pode ler
RESULT antes do cálculo terminar (lixo) ou nunca detectar
DONE (travamento).

**Sequência:**
1. Forçar externamente `status_in=2'b10` (DONE) e `pred_in=4'd7`
2. `read_en=1, addr=32'h04`
3. Verificar `data_out[1:0]=2'b10` (DONE) e `data_out[5:2]=4'd7`

**Resultado esperado:** `data_out = 32'h000000BE`
(bits[1:0]=10, bits[5:2]=0111 → 0b...0001_1110 = 0x1E... verificar cálculo).

**Nota:** calcule o valor exato de data_out conforme o
mapeamento de bits definido para STATUS antes de escrever
o testbench.

---

### TC-REG-07 — Leitura de RESULT retorna pred correto

**Motivação:**
RESULT é a saída final do sistema — o dígito previsto.
Verifica que os 4 bits de pred são mapeados corretamente
nos bits baixos de data_out sem contaminação dos bits altos.

**Sequência:**
1. Forçar `pred_in=4'd9` (dígito 9)
2. `read_en=1, addr=32'h0C`
3. Verificar `data_out=32'h00000009`

**Resultado esperado:** `data_out = 32'h00000009`.

---

### TC-REG-08 — Leitura de CYCLES retorna contador correto

**Motivação:**
CYCLES permite ao ARM medir a latência de inferência em
ciclos de clock. Verifica que o valor do contador é
passado integralmente para data_out sem truncamento.

**Sequência:**
1. Forçar `cycles_in=32'h000003E8` (1000 ciclos)
2. `read_en=1, addr=32'h10`
3. Verificar `data_out=32'h000003E8`

**Resultado esperado:** `data_out = 32'h000003E8`.

---

### TC-REG-09 — Leitura em endereço inválido retorna zero

**Motivação:**
O barramento MMIO do ARM pode gerar acessos a endereços
não mapeados. Retornar lixo causaria comportamento
imprevisível no driver. Zero é o comportamento seguro
e previsível definido pelo contrato.

**Sequência:**
1. `read_en=1, addr=32'hFF` (endereço não mapeado)
2. Verificar `data_out=32'h00000000`

**Resultado esperado:** `data_out = 32'h00000000`.

---

### TC-REG-10 — Escrita em endereço inválido não afeta registradores

**Motivação:**
Escrita em endereço errado não deve corromper nenhum
registrador válido. Verifica que o decodificador de
endereço tem cobertura completa com else implícito.

**Sequência:**
1. Escrever valores conhecidos em CTRL, IMG
2. `write_en=1, addr=32'hAA, data_in=32'hDEADBEEF`
3. Ler CTRL e STATUS
4. Verificar que os valores originais não foram alterados

**Resultado esperado:** registradores válidos inalterados.

---

## Módulo 2: fsm_ctrl.v

### Comportamento esperado (contrato do módulo)

```
FSM de 7 estados com dois contadores internos (i, j, k).

Reset assíncrono (rst_n=0):
  current_state → IDLE
  i, j, k → 0
  todos os sinais de controle → 0

Transições principais:
  IDLE        → LOAD_IMG     quando start=1
  LOAD_IMG    → CALC_HIDDEN  quando j=783 e último pixel gravado
  CALC_HIDDEN → CALC_OUTPUT  quando i=127 e j=783
  CALC_OUTPUT → ARGMAX       quando k=9 e i=127
  ARGMAX      → DONE         quando argmax_done=1
  DONE        → IDLE         automaticamente após 1 ciclo
  Qualquer    → ERROR        quando overflow detectado

Sinais de controle ativos por estado:
  LOAD_IMG:    we_img=1, addr_img=j
  CALC_HIDDEN: mac_en=1, addr_img=j, addr_w={i,j}
               ao fim de cada neurônio: mac_clr=1, we_hidden=1, h_capture=1
  CALC_OUTPUT: mac_en=1, addr_hidden=i, addr_beta={k,i}
               ao fim de cada classe: mac_clr=1
  ARGMAX:      argmax_en=1
  DONE:        done_out=1
```

---

### TC-FSM-01 — Reset assíncrono leva ao estado IDLE

**Motivação:**
O reset é o ponto de partida de toda verificação da FSM.
Se o estado inicial não for IDLE, a FSM pode começar a
calcular sem imagem válida, produzindo lixo como resultado.

**Sequência:**
1. `rst_n=0` por 2 ciclos (pode estar em qualquer estado)
2. `rst_n=1`
3. Verificar `current_state=IDLE`
4. Verificar todos os sinais de controle em zero:
   `we_img=0, mac_en=0, mac_clr=0, we_hidden=0, argmax_en=0`

**Resultado esperado:** estado IDLE, todos os controles=0.

---

### TC-FSM-02 — IDLE permanece em IDLE sem start

**Motivação:**
A FSM não deve avançar espontaneamente. Se transicionar
sem start=1, uma inferência fantasma seria iniciada com
imagem indefinida na ram_img.

**Sequência:**
1. Reset → IDLE
2. Manter `start=0` por 10 ciclos
3. Verificar `current_state=IDLE` em todos os 10 ciclos

**Resultado esperado:** estado IDLE mantido por 10 ciclos.

---

### TC-FSM-03 — IDLE → LOAD_IMG quando start=1

**Motivação:**
Transição fundamental do sistema. Verifica que um único
pulso de start=1 é suficiente para iniciar o carregamento
da imagem.

**Sequência:**
1. Reset → IDLE
2. `start=1` por 1 ciclo
3. `start=0`
4. Verificar `current_state=LOAD_IMG` no ciclo seguinte

**Resultado esperado:** transição para LOAD_IMG confirmada.

---

### TC-FSM-04 — LOAD_IMG: we_img=1 e addr_img=j corretos

**Motivação:**
Durante LOAD_IMG, a FSM deve apresentar o endereço correto
(j) para a ram_img e manter we_img=1 para cada pixel.
Se addr_img estiver errado, os pixels seriam gravados nas
posições erradas — a imagem ficaria embaralhada.

**Sequência:**
1. Entrar em LOAD_IMG via start=1
2. Verificar nos primeiros 5 ciclos:
   - Ciclo 1: `we_img=1, addr_img=0`
   - Ciclo 2: `we_img=1, addr_img=1`
   - Ciclo 3: `we_img=1, addr_img=2`
   - Ciclo 4: `we_img=1, addr_img=3`
   - Ciclo 5: `we_img=1, addr_img=4`

**Resultado esperado:** addr_img incrementa 1 por ciclo.

---

### TC-FSM-05 — LOAD_IMG → CALC_HIDDEN após 784 pixels

**Motivação:**
A FSM deve permanecer em LOAD_IMG por exatamente 784 ciclos
(j=0..783) e então transicionar. 783 ciclos = ainda carregando.
785 ciclos = saiu tarde, perdeu um pixel. O timing é crítico.

**Sequência:**
1. Entrar em LOAD_IMG
2. Verificar que no ciclo 783 ainda está em LOAD_IMG
3. Verificar que no ciclo 784 transicionou para CALC_HIDDEN

**Resultado esperado:**
- Ciclo 783: `current_state=LOAD_IMG`
- Ciclo 784: `current_state=CALC_HIDDEN`

---

### TC-FSM-06 — CALC_HIDDEN: mac_en=1 e endereços corretos

**Motivação:**
Durante CALC_HIDDEN, a FSM deve alimentar a MAC com os
endereços corretos de ram_img e rom_pesos a cada ciclo.
Um erro de endereço faria a MAC multiplicar valores errados
— a inferência estaria computando h com pesos de outro neurônio.

**Sequência:**
1. Entrar em CALC_HIDDEN
2. Verificar nos primeiros 3 ciclos:
   - `mac_en=1`
   - `addr_img=j` incrementando (0, 1, 2...)
   - `addr_w={i,j}` com i=0 fixo e j incrementando

**Resultado esperado:** mac_en=1, endereços corretos e
sincronizados com os contadores i e j.

---

### TC-FSM-07 — CALC_HIDDEN: mac_clr e we_hidden ao fim de cada neurônio

**Motivação:**
Ao concluir os 784 MACs de um neurônio, a FSM deve:
(1) capturar o resultado em ram_hidden (we_hidden=1),
(2) limpar o acumulador (mac_clr=1) para o próximo neurônio.
Se mac_clr não ocorrer, o acumulador carrega o resultado
do neurônio anterior — todos os neurônios ficariam errados
exceto o primeiro.

**Sequência:**
1. Entrar em CALC_HIDDEN
2. Avançar 784 ciclos (j vai de 0 a 783)
3. No ciclo 784 (j=783, fim do neurônio 0):
   Verificar `mac_clr=1`, `we_hidden=1`, `h_capture=1`
4. No ciclo 785: verificar `mac_clr=0`, `we_hidden=0`
   e j=0 (reiniciado para o próximo neurônio)

**Resultado esperado:** mac_clr e we_hidden pulsam por
exatamente 1 ciclo ao fim de cada neurônio.

---

### TC-FSM-08 — CALC_HIDDEN → CALC_OUTPUT após 128 neurônios

**Motivação:**
A FSM deve permanecer em CALC_HIDDEN por exatamente
128 × 784 = 100.352 ciclos de MAC antes de transicionar.
Transição prematura deixaria neurônios sem calcular.
Transição tardia desperdiçaria ciclos.

**Sequência:**
1. Entrar em CALC_HIDDEN
2. Verificar que no ciclo 100.351 ainda está em CALC_HIDDEN
3. Verificar que no ciclo 100.352 transicionou para CALC_OUTPUT

**Resultado esperado:**
- `current_state=CALC_HIDDEN` até i=127, j=783
- `current_state=CALC_OUTPUT` quando i=127 e j=783

**Nota:** este teste pode ser acelerado em simulação usando
um parâmetro de profundidade reduzida (ex: 4 neurônios × 4
pixels) para não simular 100k ciclos.

---

### TC-FSM-09 — CALC_OUTPUT: endereços rom_beta e ram_hidden corretos

**Motivação:**
Durante CALC_OUTPUT, a FSM deve ler ram_hidden[i] e
rom_beta[k][i] para cada par (k, i). Um erro nos endereços
faria a camada de saída calcular β errado, produzindo
scores incorretos independente de h estar certo.

**Sequência:**
1. Entrar em CALC_OUTPUT
2. Verificar nos primeiros 3 ciclos:
   - `mac_en=1`
   - `addr_hidden=i` incrementando (0, 1, 2...)
   - `addr_beta={k,i}` com k=0 fixo e i incrementando

**Resultado esperado:** endereços corretos e sincronizados
com os contadores k e i.

---

### TC-FSM-10 — CALC_OUTPUT → ARGMAX após 10 classes

**Motivação:**
Após calcular os 10 scores y[0..9], a FSM deve transicionar
para ARGMAX. Transição antes de k=9 deixaria classes sem
calcular — o argmax compararia scores inválidos.

**Sequência:**
1. Entrar em CALC_OUTPUT
2. Verificar transição para ARGMAX quando k=9 e i=127

**Resultado esperado:** `current_state=ARGMAX` após
10 × 128 = 1280 ciclos de MAC em CALC_OUTPUT.

---

### TC-FSM-11 — ARGMAX → DONE quando argmax_done=1

**Motivação:**
O bloco argmax sinaliza done após comparar os 10 scores.
A FSM deve detectar esse pulso e transicionar para DONE
no ciclo seguinte. Se ignorar argmax_done, o sistema
travaria em ARGMAX para sempre.

**Sequência:**
1. Entrar em ARGMAX
2. Assertar `argmax_done=1` por 1 ciclo
3. Verificar `current_state=DONE` no ciclo seguinte

**Resultado esperado:** transição para DONE confirmada.

---

### TC-FSM-12 — DONE: done_out=1 e result correto disponível

**Motivação:**
No estado DONE, o banco de registradores deve apresentar
o resultado em RESULT e STATUS=DONE para que o ARM
detecte o fim e leia o dígito previsto.

**Sequência:**
1. Chegar ao estado DONE com `pred=4'd5`
2. Verificar `done_out=1`, `status_out=2'b10` (DONE)
3. Verificar `result_out=4'd5`

**Resultado esperado:** done_out=1, STATUS=DONE, RESULT=5.

---

### TC-FSM-13 — DONE → IDLE automaticamente após 1 ciclo

**Motivação:**
O estado DONE deve durar exatamente 1 ciclo — tempo
suficiente para o ARM detectar via polling e ler RESULT.
Se DONE persistir indefinidamente, a FSM não estaria
pronta para uma nova inferência sem reset explícito.

**Sequência:**
1. Chegar ao estado DONE
2. Verificar `current_state=DONE` no ciclo N
3. Verificar `current_state=IDLE` no ciclo N+1

**Resultado esperado:** DONE dura exatamente 1 ciclo.

---

### TC-FSM-14 — ERROR: overflow da MAC leva ao estado ERROR

**Motivação:**
Se a MAC detectar overflow durante CALC_HIDDEN ou
CALC_OUTPUT, o resultado seria inválido. A FSM deve
abandonar o cálculo e ir para ERROR em vez de reportar
um dígito incorreto como resultado válido.

**Sequência:**
1. Entrar em CALC_HIDDEN
2. Assertar `overflow=1` (sinal da MAC)
3. Verificar `current_state=ERROR` no ciclo seguinte
4. Verificar `status_out=2'b11` (ERROR)

**Resultado esperado:** transição para ERROR, STATUS=ERROR.

---

### TC-FSM-15 — ERROR → IDLE via reset externo

**Motivação:**
Uma vez em ERROR, a FSM não deve tentar se recuperar
sozinha — isso poderia gerar comportamento imprevisível.
O único caminho de saída é um reset explícito via CTRL[1].

**Sequência:**
1. Forçar estado ERROR
2. Assertar `reset_out=1` (via CTRL[1] do reg_bank)
3. Verificar `current_state=IDLE`

**Resultado esperado:** IDLE após reset, pronto para
nova inferência.

---

### TC-FSM-16 — Contador de ciclos (CYCLES) incrementa corretamente

**Motivação:**
CYCLES permite ao ARM medir a latência de inferência.
O contador deve começar em 0 no início de LOAD_IMG e
parar (congelar) quando a FSM chega em DONE.
Um contador que não para em DONE retornaria latência
maior que a real.

**Sequência:**
1. Reset → cycles=0
2. start=1 → entra em LOAD_IMG → cycles começa a incrementar
3. Após N ciclos, verificar cycles=N
4. Chegar em DONE
5. Verificar que cycles congela (não incrementa mais)
6. Ler cycles → deve ser exatamente N_total

**Resultado esperado:** cycles=N durante operação,
cycles=N_total congelado em DONE.

---

### TC-FSM-17 — Duas inferências consecutivas: sem contaminação

**Motivação:**
O sistema deve classificar múltiplas imagens em sequência
sem que o resultado de uma contamine a próxima. Verifica
que os contadores i, j, k são zerados ao retornar ao IDLE
e que ram_hidden aceita sobrescrita corretamente.

**Sequência:**
1. Primeira inferência completa → pred=X
2. FSM retorna a IDLE automaticamente
3. Segunda inferência completa com imagem diferente → pred=Y
4. Verificar que RESULT=Y (não contaminado por X)

**Resultado esperado:** RESULT da segunda inferência
é independente da primeira.

---

### TC-FSM-18 — Reset no meio de CALC_HIDDEN aborta e volta ao IDLE

**Motivação:**
O ARM pode precisar abortar uma inferência em andamento
(por exemplo, se enviar a imagem errada). Verifica que
reset_out=1 durante qualquer estado leva imediatamente
ao IDLE e zera todos os contadores.

**Sequência:**
1. Entrar em CALC_HIDDEN (i=5, j=300)
2. Assertar `reset_out=1`
3. Verificar `current_state=IDLE`, `i=0`, `j=0`, `k=0`
4. Verificar `mac_en=0`, `we_hidden=0`

**Resultado esperado:** IDLE imediato, contadores zerados,
controles desativados.

---

## Resumo dos casos de teste por módulo

| Módulo    | Total | Funcionalidade        | Transições          | Robustez               |
|-----------|----|----------------------|---------------------|------------------------|
| reg_bank  | 10 | TC-REG-02..08        | TC-REG-04,05        | TC-REG-01,09,10        |
| fsm_ctrl  | 18 | TC-FSM-03..06,09,11  | TC-FSM-05,08,10,13  | TC-FSM-01,02,14..18    |
| **Total** | **28** | | | |

---

## Ordem de implementação recomendada (TDD)

```
1. reg_bank.v
   → mais simples: lógica combinacional de decodificação
   → sem dependência de outros módulos desta fase
   → deve passar antes de qualquer teste de FSM

2. fsm_ctrl.v
   → depende de reg_bank estar funcional
   → implementar e testar estado por estado na ordem:
     IDLE → LOAD_IMG → CALC_HIDDEN → CALC_OUTPUT → ARGMAX → DONE → ERROR
   → não implementar o próximo estado sem o anterior passando
```

> **Regra de ouro:** um teste falhando na FSM geralmente
> indica um erro de timing (contador errado) ou um sinal
> de controle ativo no estado errado. Use as waveforms
> do GTKWave para inspecionar ciclo a ciclo.

---

## Pré-requisitos antes de escrever os testbenches

Antes de implementar qualquer módulo desta fase, os seguintes
artefatos das fases anteriores devem estar 100% validados:

- [ ] Todos os TC-IMG, TC-WGT, TC-BIAS, TC-BETA, TC-HID passando
- [ ] mac_unit.v validada (todos os TC-MAC passando)
- [ ] pwl_activation.v validada (todos os TC-PWL passando)
- [ ] argmax_block.v validado (todos os TC-ARG passando)
- [ ] Mapa de registradores MMIO definido e documentado no README
- [ ] Diagrama da FSM (estados + transições) desenhado e revisado
      pela equipe antes de escrever uma linha de Verilog
