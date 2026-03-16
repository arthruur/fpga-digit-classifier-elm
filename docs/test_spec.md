# Especificação de Testes — Datapath elm_accel
## Abordagem TDD (Test-Driven Development)

> **Como usar este documento**
> Cada caso de teste aqui descrito tem um `ID` único que é referenciado
> diretamente nos testbenches (ex: `// TC-MAC-01`). Leia a justificativa
> de cada caso antes de implementar o módulo — o objetivo do TDD é que
> os testes guiem as decisões de implementação, não o contrário.

---

## Convenções

**Formato Q4.12 (16 bits signed):**

| Valor float | Inteiro | Hex    |
|-------------|---------|--------|
| +1.0        | 4096    | 0x1000 |
| +0.5        | 2048    | 0x0800 |
| +0.25       | 1024    | 0x0400 |
| 0.0         | 0       | 0x0000 |
| -0.25       | -1024   | 0xFC00 |
| -0.5        | -2048   | 0xF800 |
| -1.0        | -4096   | 0xF000 |
| +7.9997 (MAX) | 32767 | 0x7FFF |
| -8.0 (MIN)  | -32768  | 0x8000 |

**Critério de PASS:** igualdade bit a bit (`===`) em Verilog, a menos que
o caso de teste especifique tolerância explícita.

---

## Módulo 1: mac_unit.v

### Comportamento esperado (contrato do módulo)

```
A cada borda de subida do clock:
  SE mac_clr = 1  →  acc = 0  (prioridade máxima)
  SE mac_en  = 1  →  acc = saturar(acc + truncar(a × b))
  SENÃO           →  acc mantém valor anterior
```

O truncamento replica `product[27:12]` do produto Q8.24.
A saturação clipa o resultado para o range [0x8000, 0x7FFF].

---

### TC-MAC-01 — Reset síncrono limpa o acumulador

**Motivação:**
O reset é a base de toda verificação. Se o módulo não inicializa
corretamente, nenhum outro teste tem valor — qualquer resultado
inicial pode ser resíduo de estado indefinido.

**Sequência:**
1. Aplicar `rst_n = 0` por 2 ciclos
2. Liberar `rst_n = 1`
3. Verificar `acc_out == 0x0000`

**Resultado esperado:** `acc_out = 0x0000`, `overflow = 0`

**O que falha se errar:** todos os testes seguintes ficam
suspeitos de falso-positivo.

---

### TC-MAC-02 — mac_clr tem prioridade sobre mac_en

**Motivação:**
A especificação diz que mac_clr tem prioridade. Se isso não for
verdade, a FSM pode tentar limpar o acumulador e acumular ao mesmo
tempo sem resultado previsível. Este teste verifica o contrato
explicitamente antes de qualquer lógica de controle.

**Sequência:**
1. Acumular `a = 0x1000 (+1.0), b = 0x1000 (+1.0)` por 1 ciclo
   (acc deve ser 0x1000)
2. No mesmo ciclo, assertar `mac_clr = 1` E `mac_en = 1`
   com quaisquer `a, b`
3. Verificar `acc_out == 0x0000`

**Resultado esperado:** mac_clr vence, acc retorna a 0.

---

### TC-MAC-03 — mac_en = 0 mantém o acumulador estável

**Motivação:**
O acumulador deve ser um registrador estável. Se mudar com
mac_en = 0, há regressão de lógica de enable ou glitch de síntese.
Verifica o estado "hold" do módulo.

**Sequência:**
1. Acumular `+1.0 × +1.0` por 1 ciclo → acc = 0x1000
2. Desabilitar mac_en por 5 ciclos com `a, b` quaisquer
3. Verificar `acc_out == 0x1000` em todos os 5 ciclos

**Resultado esperado:** acc_out inalterado.

---

### TC-MAC-04 — Produto simples: 1.0 × 1.0 = 1.0

**Motivação:**
Caso canônico. Verifica que multiplicação e truncamento
básicos estão corretos. Se `1.0 × 1.0 ≠ 1.0`, o mecanismo
de product[27:12] está implementado errado.

**Cálculo esperado:**
```
a = 0x1000 = 4096
b = 0x1000 = 4096
produto = 4096 × 4096 = 16.777.216  (0x01000000, Q8.24)
produto[27:12] = 0x01000000 >> 12 = 4096 = 0x1000  (Q4.12)
acc = 0 + 4096 = 4096 = 0x1000
```

**Resultado esperado:** `acc_out = 0x1000` após 1 ciclo de mac_en.

---

### TC-MAC-05 — Produto simples: 0.5 × 0.5 = 0.25

**Motivação:**
Verifica que a fração é preservada corretamente. Um erro
de 1 bit no truncamento deslocaria o resultado para 0.125 ou 0.5.

**Cálculo esperado:**
```
a = 0x0800 = 2048
b = 0x0800 = 2048
produto = 2048 × 2048 = 4.194.304  (0x00400000, Q8.24)
produto[27:12] = 0x00400000 >> 12 = 1024 = 0x0400  (+0.25 em Q4.12)
acc = 0 + 1024 = 0x0400
```

**Resultado esperado:** `acc_out = 0x0400`.

---

### TC-MAC-06 — Produto com negativo: +1.0 × −1.0 = −1.0

**Motivação:**
Verifica que a multiplicação signed está correta. Um erro
comum é usar operadores não-signed, que invertem o resultado
para valores negativos.

**Cálculo esperado:**
```
a = 0x1000 = +4096
b = 0xF000 = −4096
produto = +4096 × −4096 = −16.777.216 (0xFF000000, Q8.24 signed)
produto[27:12] = 0xFF000000 >> 12 = −4096 = 0xF000 (−1.0 em Q4.12)
acc = 0 + (−4096) = 0xF000
```

**Resultado esperado:** `acc_out = 0xF000`.

---

### TC-MAC-07 — Produto entre dois negativos: −1.0 × −1.0 = +1.0

**Motivação:**
Sinal de sinal = positivo. Um erro de implementação signed
poderia dobrar o sinal negativo ou perder o bit de sinal.

**Resultado esperado:** `acc_out = 0x1000`.

---

### TC-MAC-08 — Acumulação de múltiplas parcelas

**Motivação:**
A essência da MAC é acumular. Testa que 4 acumulações
consecutivas produzem a soma correta, sem perda de parcela
ou acumulação dupla.

**Sequência:**
```
Ciclo 1: +1.0 × +0.25 → parcela = +0.25  →  acc = +0.25
Ciclo 2: +1.0 × +0.50 → parcela = +0.50  →  acc = +0.75
Ciclo 3: +1.0 × +0.25 → parcela = +0.25  →  acc = +1.00
Ciclo 4: +1.0 × +0.25 → parcela = +0.25  →  acc = +1.25
```

**Resultado esperado:** `acc_out = 0x1400` (+1.25 = 5120/4096).

---

### TC-MAC-09 — Acumulação resulta em zero (cancelamento)

**Motivação:**
Verifica que positivos e negativos se cancelam. Um erro de
complemento de 2 pode causar off-by-one em torno de zero.

**Sequência:**
```
Ciclo 1: +1.0 × +1.0 → acc = +1.0
Ciclo 2: +1.0 × −1.0 → acc = 0.0
```

**Resultado esperado:** `acc_out = 0x0000`.

---

### TC-MAC-10 — Saturação positiva: resultado excede +7.999

**Motivação:**
Sem saturação, o wrap-around produz um valor negativo grande
(ex: +8.0 → −8.0 em Q4.12). Isso é catastrófico para a
inferência. Este é o teste mais crítico de robustez da MAC.

**Sequência:**
```
Ciclo 1..8: a = 0x1000 (+1.0), b = 0x1000 (+1.0)
  → acc deve ser +1, +2, +3, +4, +5, +6, +7, então saturar em +7.999
```

Após a 8ª acumulação, acc estaria em +8.0 — fora do range Q4.12.
Verificar que `acc_out = 0x7FFF` e `overflow = 1`.

**Resultado esperado:** `acc_out = 0x7FFF`, `overflow = 1` (pelo menos 1 ciclo).

---

### TC-MAC-11 — Saturação negativa: resultado menor que −8.0

**Motivação:**
Simétrico ao TC-MAC-10 para o lado negativo. Necessário
para verificar ambos os ramos do código de saturação.

**Sequência:**
```
Ciclo 1..8: a = 0x1000 (+1.0), b = 0xF000 (−1.0)
  → acc: −1, −2, −3, −4, −5, −6, −7, satura em −8.0
```

**Resultado esperado:** `acc_out = 0x8000`, `overflow = 1`.

---

### TC-MAC-12 — Saturação é permanente até mac_clr

**Motivação:**
Uma vez saturado, o acumulador não deve "sair" da saturação
por conta de uma próxima acumulação pequena. Overflow é um
estado terminal que exige reset explícito da FSM.

**Sequência:**
1. Saturar positivamente (via TC-MAC-10)
2. Acumular `+1.0 × −0.25` (que normalmente reduziria o acc)
3. Verificar que `acc_out` ainda é `0x7FFF`
4. Assertar mac_clr
5. Verificar `acc_out = 0x0000`

**Resultado esperado:** acc permanece em 0x7FFF até mac_clr.

---

### TC-MAC-13 — Produto próximo do limite de Q4.12: truncamento correto

**Motivação:**
Verifica que o truncamento product[27:12] não arredonda,
apenas descarta os bits inferiores (truncamento para zero).
Um erro de arredondamento causaria +1 LSB em certos valores.

**Cálculo:**
```
a = 0x0001 (+1/4096 ≈ 0.000244)
b = 0x0001
produto = 1 × 1 = 1  (Q8.24)
produto[27:12] = 1 >> 12 = 0  (abaixo da resolução Q4.12)
```

**Resultado esperado:** `acc_out = 0x0000` (produto descartado por truncamento).

---

### TC-MAC-14 — mac_clr reinicia e permite nova acumulação imediata

**Motivação:**
A FSM usa mac_clr para resetar entre neurônios. Após o clr,
o módulo deve estar pronto para acumular imediatamente no
próximo ciclo. Qualquer latência de "limpeza" quebraria o
timing da FSM.

**Sequência:**
1. Acumular para acc = +2.0
2. mac_clr = 1 por 1 ciclo → acc = 0
3. Ciclo imediatamente seguinte: mac_en = 1, a = +0.5, b = +1.0
4. Verificar `acc_out = 0x0800` (+0.5)

**Resultado esperado:** acc = 0x0800 no ciclo após o clr.

---

## Módulo 2: pwl_activation.v

### Comportamento esperado (contrato do módulo)

```
Lógica combinacional pura (sem clock, sem estado).
Para x_in → y_out disponível no mesmo ciclo.

Segmentos (sobre |x|):
  |x| >= 2.0          → y = ±1.0  (saturação)
  1.5 <= |x| < 2.0    → y = (1/8 + 1/512)·|x| + 0.717
  1.0 <= |x| < 1.5    → y = (1/4 + 1/16)·|x| + 0.453
  0.5 <= |x| < 1.0    → y = (1/2 + 1/8)·|x| + 0.156
  0.25 <= |x| < 0.5   → y = (1 - 1/8)·|x| + 0.029
  0.0 <= |x| < 0.25   → y = |x|  (identidade)
  Sinal: y = -y se x < 0  (função ímpar)
```

---

### TC-PWL-01 — Entrada zero: saída exatamente zero

**Motivação:**
tanh(0) = 0 por definição matemática. Este é o ponto de
referência absoluto. Se errar aqui, o segmento 1 ou a
lógica de sinal está quebrada.

**Entrada:** `x_in = 0x0000`
**Saída esperada:** `y_out = 0x0000`

---

### TC-PWL-02 a TC-PWL-06 — Interior de cada segmento positivo

**Motivação:**
Verifica a fórmula de cada segmento com um valor bem no meio
do intervalo, longe dos breakpoints. Um erro de intercepto
ou slope errado aparece claramente aqui.

| ID | x (float) | x (hex) | y esperado (calc.) | y (hex) |
|----|-----------|---------|-------------------|---------|
| TC-PWL-02 | +0.125 | 0x0200 | 0.125 (seg1: y=x) | 0x0200 |
| TC-PWL-03 | +0.375 | 0x0600 | 7/8×0.375+0.029 = 0.357 | 0x05B8 |
| TC-PWL-04 | +0.75  | 0x0C00 | 5/8×0.75+0.156 = 0.625 | 0x0A00 |
| TC-PWL-05 | +1.25  | 0x1400 | 5/16×1.25+0.453 = 0.844 | 0x0D80 |
| TC-PWL-06 | +1.75  | 0x1C00 | ≈1/8×1.75+0.717 = 0.936 | 0x0EF0 |

**Nota:** calcular y esperado em Python com `pwl_tanh_q412()` antes
de escrever os valores no testbench.

---

### TC-PWL-07 a TC-PWL-10 — Breakpoints: continuidade

**Motivação:**
No breakpoint exato (ex: x = 0.5), o segmento seguinte entra
em vigor. O valor 1 LSB antes do breakpoint e o valor exato
no breakpoint não devem diferir mais do que o permitido pela
continuidade da função (≤ 8 LSBs). Um salto grande indica
que os interceptos B2..B5 são inconsistentes.

| ID | Breakpoint | x antes (hex) | x no BP (hex) | Delta máximo aceito |
|----|------------|--------------|---------------|---------------------|
| TC-PWL-07 | x = 0.25 | 0x03FF | 0x0400 | ≤ 8 LSBs |
| TC-PWL-08 | x = 0.50 | 0x07FF | 0x0800 | ≤ 8 LSBs |
| TC-PWL-09 | x = 1.00 | 0x0FFF | 0x1000 | ≤ 60 LSBs |
| TC-PWL-10 | x = 1.50 | 0x17FF | 0x1800 | ≤ 80 LSBs |

---

### TC-PWL-11 — Saturação positiva: x >= 2.0 → y = +1.0

**Motivação:**
Qualquer valor acima do limite deve retornar exatamente +1.0.
Testa três pontos: o exato limite, ligeiramente acima, e o
valor máximo representável.

**Entradas:** `0x2000` (+2.0), `0x2001` (+2.000244), `0x7FFF` (+7.999)
**Saída esperada em todos:** `y_out = 0x1000` (+1.0)

---

### TC-PWL-12 — Saturação negativa: x <= −2.0 → y = −1.0

**Motivação:**
Simétrico ao TC-PWL-11. Verifica que a propriedade de função
ímpar é aplicada corretamente nas saturações.

**Entradas:** `0xE000` (−2.0), `0xDFFF` (−2.000244), `0x8000` (−8.0)
**Saída esperada em todos:** `y_out = 0xF000` (−1.0)

---

### TC-PWL-13 a TC-PWL-16 — Propriedade de função ímpar: f(−x) = −f(x)

**Motivação:**
Esta propriedade não é apenas uma otimização de hardware —
ela é matematicamente correta para tanh. Se quebrar, toda
a simetria da rede é comprometida. O teste compara
diretamente f(x) e f(−x) para 4 valores representativos.

| ID | x positivo | x negativo | Condição |
|----|------------|------------|----------|
| TC-PWL-13 | 0x0600 (+0.375) | 0xFA00 (−0.375) | y(x) == −y(−x) |
| TC-PWL-14 | 0x0C00 (+0.75)  | 0xF400 (−0.75)  | y(x) == −y(−x) |
| TC-PWL-15 | 0x1400 (+1.25)  | 0xEC00 (−1.25)  | y(x) == −y(−x) |
| TC-PWL-16 | 0x1C00 (+1.75)  | 0xE400 (−1.75)  | y(x) == −y(−x) |

**Tolerância:** igualdade bit a bit (a lógica de inversão é exata).

---

### TC-PWL-17 — Varredura completa: MAE dentro do limite

**Motivação:**
Testa a precisão global com os 256 valores de −4.0 a +4.0
em passos de 0.03125 (passo de 128 LSBs Q4.12). Para cada
ponto, o testbench calcula o erro |y_verilog − tanh_real|
e verifica que o MAE final não excede 0.010.

**Como gerar os valores de referência:** rodar `gen_tanh_ref.py`
que produz `tanh_ref.hex` com os valores quantizados.

**Critério:** MAE ≤ 0.010 sobre todos os pontos testados.

---

## Módulo 3: argmax_block.v

### Comportamento esperado (contrato do módulo)

```
Entradas sequenciais: a cada ciclo com enable=1, consume
um escore y_in com índice k_in.
Após 10 enables: done=1 por 1 ciclo, max_idx = índice do maior.
Comparação é SIGNED — valores negativos são tratados corretamente.
start reinicia a busca (max_val = mínimo possível, max_idx = 0).
```

---

### TC-ARG-01 — Reset: estado inicial limpo

**Motivação:**
Verificar que rst_n limpa corretamente max_idx, max_val e done.
Um estado inicial indefinido pode fazer o primeiro argmax
retornar um índice residual de uma inferência anterior.

**Resultado esperado:** após reset, `max_idx = 0`, `done = 0`.

---

### TC-ARG-02 — Máximo no primeiro elemento (índice 0)

**Motivação:**
Caso extremo: o maior valor aparece no primeiro ciclo.
Verifica que max_idx não é incorretamente sobrescrito pelos
9 ciclos seguintes de valores menores.

**Escores:** `y = [+2.0, +1.0, +0.5, 0.0, −0.5, −1.0, +0.25, +0.75, −0.25, +1.5]`
**Resultado esperado:** `max_idx = 0`, `max_val = 0x2000` (+2.0)

---

### TC-ARG-03 — Máximo no último elemento (índice 9)

**Motivação:**
Caso extremo oposto. Verifica que o comparador não descarta
o último escore antes de assertar done.

**Escores:** `y = [−1.0, −0.5, 0.0, +0.5, +1.0, +0.75, +0.25, −0.25, +1.5, +2.0]`
**Resultado esperado:** `max_idx = 9`, `max_val = 0x2000`

---

### TC-ARG-04 — Máximo no meio (índice 5)

**Motivação:**
Verifica o comportamento geral com máximo em posição
intermediária. Testa que 5 ciclos antes atualizam corretamente
e 4 ciclos depois não sobrescrevem.

**Escores:** `y = [0.0, +0.25, +0.5, +0.75, +1.0, +1.5, +1.25, +0.5, +0.25, 0.0]`
**Resultado esperado:** `max_idx = 5`, `max_val = 0x1800`

---

### TC-ARG-05 — Todos os escores iguais: retorna índice 0

**Motivação:**
Com empate total, o hardware deve retornar o PRIMEIRO índice
encontrado (comportamento determinístico exigido para
reprodutibilidade). O comparador usa `>` (estrito), então
iguais não sobrescrevem.

**Escores:** todos `0x1000` (+1.0)
**Resultado esperado:** `max_idx = 0`

---

### TC-ARG-06 — Empate parcial: dois máximos iguais

**Motivação:**
Caso real plausível. Verifica o desempate pelo índice menor
(primeiro encontrado), que é o comportamento correto de
`>` estrito.

**Escores:** `y = [0.0, +1.0, 0.5, +1.0, 0.0, ...]` (índices 1 e 3 empatados)
**Resultado esperado:** `max_idx = 1` (primeiro encontrado)

---

### TC-ARG-07 — Todos os escores negativos

**Motivação:**
Este é o teste mais importante do argmax. A camada de saída
da ELM é linear e os escores podem ser todos negativos.
Um comparador unsigned retornaria o índice 0 (bit 15 = 0
seria interpretado como "maior"). O teste verifica que a
comparação `$signed()` está correta.

**Escores:** `y = [−4.0, −3.0, −2.0, −1.0, −0.5, −0.25, −0.75, −1.5, −2.5, −3.5]`
**Resultado esperado:** `max_idx = 5` (−0.25 é o menos negativo)

---

### TC-ARG-08 — done dura exatamente 1 ciclo

**Motivação:**
A FSM lê done como pulso de 1 ciclo e transiciona para DONE.
Se done persistir por 2+ ciclos, a FSM pode transicionar
duas vezes ou reescrever RESULT incorretamente.

**Sequência:** executar argmax completo, monitorar done por 3 ciclos após o 10º enable.
**Resultado esperado:** done = 1 apenas no ciclo imediatamente após o 10º enable.

---

### TC-ARG-09 — start reinicia corretamente durante operação

**Motivação:**
A FSM pode precisar abortar uma operação e recomeçar.
Verifica que start no meio de uma sequência reinicia max_val
ao mínimo possível, descartando os ciclos anteriores.

**Sequência:**
1. Enviar 5 escores altos (ex: +3.0)
2. Assertar start
3. Enviar 10 escores novos com max em índice 7
4. Verificar max_idx = 7 (não contaminado pelos primeiros 5)

---

### TC-ARG-10 — enable=0 entre escores não altera o estado

**Motivação:**
A FSM pode pausar a entrega de escores (por ex., se a RAM_HIDDEN
ainda não está pronta). O argmax deve "congelar" e continuar
de onde parou.

**Sequência:**
1. Enviar 3 escores com enable=1
2. Pausar: enable=0 por 4 ciclos
3. Continuar: enviar os 7 escores restantes com enable=1
4. Verificar que o resultado é idêntico ao sem pausa

---

### TC-ARG-11 — Dois argmax consecutivos: sem contaminação

**Motivação:**
Durante a inferência de imagens em sequência, o argmax é
chamado repetidamente. Verifica que o start entre duas
chamadas garante isolamento total dos resultados.

**Sequência:**
1. Primeira rodada: max em índice 3
2. start, segunda rodada: max em índice 7
3. Verificar max_idx = 7

---

## Resumo dos casos de teste por módulo

| Módulo | Total | Funcionalidade | Saturação/Limite | Robustez |
|--------|-------|---------------|-----------------|----------|
| mac_unit | 14 | TC-MAC-01..09 | TC-MAC-10..12 | TC-MAC-13..14 |
| pwl_activation | 17 | TC-PWL-01..06 | TC-PWL-11..12 | TC-PWL-07..10, 13..17 |
| argmax_block | 11 | TC-ARG-02..07 | TC-ARG-07 | TC-ARG-01, 08..11 |

**Ordem de implementação recomendada (TDD):**
1. Escrever todos os testbenches para um módulo (todos os testes falham)
2. Implementar o módulo até todos os testes passarem
3. Passar para o próximo módulo
4. Não avançar de módulo com testes falhando
