# Especificação de Testes — Fase 5: Integração Top-Level
## Abordagem TDD (Test-Driven Development)

> **Como usar este documento**
> Cada caso de teste tem um `ID` único referenciado diretamente no
> testbench (`tb_elm_accel.v`). O testbench simula o comportamento do
> ARM/HPS realizando uma inferência completa via MMIO, sem instanciar
> o HPS real.

---

## Convenções

**Mapa de registradores MMIO (32 bits cada):**

| Offset | Nome | Acesso | Descrição |
|--------|------|--------|-----------|
| 0x00 | CTRL | W | bit[0]=start, bit[1]=reset |
| 0x04 | STATUS | R | bits[1:0]=estado, bits[5:2]=pred |
| 0x08 | IMG | W | bits[9:0]=pixel_addr, bits[17:10]=pixel_data |
| 0x0C | RESULT | R | bits[3:0]=pred (0..9) |
| 0x10 | CYCLES | R | ciclos desde START até DONE |

**Codificação de STATUS[1:0]:**

| Valor | Significado |
|-------|-------------|
| 2'b00 | IDLE |
| 2'b01 | BUSY |
| 2'b10 | DONE |
| 2'b11 | ERROR |

**Arquivos de entrada (gerados por `elm_golden.py`):**

| Arquivo | Conteúdo | Formato |
|---------|----------|---------|
| `img_test.hex` | 784 pixels da imagem de teste | 8 bits por linha |
| `pred_ref.hex` | Dígito esperado (golden model Q4.12) | 4 bits, 1 linha |

**Critério de PASS:** `pred_hardware === pred_golden` (igualdade bit a bit).
A predição do hardware deve concordar com o golden model Q4.12, não
necessariamente com o rótulo verdadeiro da imagem.

---

## Módulo: tb_elm_accel.v

### Comportamento esperado (contrato do módulo)
```
Protocolo de inferência via MMIO:

1. LOAD (pré-START):
   Para cada pixel p (0..783):
     Escrever em IMG: data_in = {14'b0, pixel_data[7:0], pixel_addr[9:0]}
   A ram_img aceita escritas a qualquer momento (FSM em IDLE).

2. START:
   Escrever CTRL = 32'h00000001  (start=1)
   Escrever CTRL = 32'h00000000  (limpa o pulso)

3. POLLING:
   Repetir até STATUS[1:0] != BUSY:
     Ler STATUS
   Se STATUS[1:0] == ERROR → inferência falhou
   Se STATUS[1:0] == DONE  → resultado disponível

4. LEITURA:
   Ler RESULT → bits[3:0] = dígito predito (0..9)
   Ler CYCLES → latência em ciclos de clock

5. VALIDAÇÃO:
   RESULT[3:0] deve ser igual a pred_ref[0]
```

---

## TC-INT-01 — Reset inicializa o sistema em IDLE

**Motivação:**
Um sistema que não inicializa corretamente pode disparar uma inferência
espúria antes mesmo do ARM carregar a imagem. Este é o pré-requisito
de todos os outros testes.

**Sequência:**
1. Aplicar `rst_n=0` por 2 ciclos
2. Liberar `rst_n=1`
3. Ler STATUS

**Resultado esperado:** `STATUS[1:0] = 2'b00` (IDLE).

---

## TC-INT-02 — Carregamento de imagem via registrador IMG

**Motivação:**
O protocolo de empacotamento `{14'b0, pixel_data, pixel_addr}` deve
ser decodificado corretamente pelo `reg_bank` e roteado para a `ram_img`
com o endereço e dado corretos. Um erro de mapeamento de bits faria
todos os pixels serem escritos no endereço 0 ou com valor errado.

**Sequência:**
1. Escrever 784 pixels via MMIO usando `img_test.hex` como fonte
2. Verificar que STATUS permanece IDLE (carregamento não dispara inferência)

**Resultado esperado:** STATUS=IDLE após 784 escritas em IMG.

---

## TC-INT-03 — START dispara a inferência

**Motivação:**
O bit CTRL[0] deve gerar um pulso de start para a FSM. Um pulso
ausente deixaria o sistema em IDLE indefinidamente; um pulso permanente
poderia reiniciar a FSM a cada ciclo.

**Sequência:**
1. Escrever `CTRL = 0x00000001` (start=1)
2. Escrever `CTRL = 0x00000000` (limpa)
3. Ler STATUS imediatamente após

**Resultado esperado:** `STATUS[1:0] = 2'b01` (BUSY).

---

## TC-INT-04 — Polling detecta DONE dentro do timeout

**Motivação:**
O sistema deve completar a inferência em tempo finito. O timeout de
200.000 polls (cada poll consome 2 ciclos de clock) cobre
generosamente os 102.832 ciclos necessários. Um sistema que trava em
BUSY indica falha na FSM (transição bloqueada) ou nas memórias
(leitura indefinida).

**Sequência:**
1. Aguardar STATUS != BUSY com contador de polls
2. Verificar que o contador não ultrapassou o limite

**Resultado esperado:** DONE detectado em ≤ 200.000 polls, sem ERROR.

**Indicador quantitativo:** polls observados ≈ 51.416 (testbench lê
STATUS a cada ~2 ciclos, e a inferência completa leva 102.832 ciclos).

---

## TC-INT-05 — RESULT contém o dígito predito correto

**Motivação:**
Verifica o contrato completo do co-processador: da escrita da imagem
via MMIO até a leitura do dígito predito. A predição deve coincidir
com o golden model Q4.12 executado em `elm_golden.py` sobre a mesma
imagem com os mesmos pesos.

**Sequência:**
1. Executar o fluxo completo (TC-INT-01 a TC-INT-04)
2. Ler `RESULT[3:0]`
3. Comparar com `pred_ref[0]` carregado de `pred_ref.hex`

**Resultado esperado:** `RESULT[3:0] === pred_ref[0]`.

---

## TC-INT-06 — CYCLES reporta a latência correta

**Motivação:**
O contador CYCLES permite ao ARM medir a latência real de inferência.
Deve congelar no momento do DONE e reportar exatamente o número de
ciclos desde o início de LOAD_IMG.

**Valor esperado com parâmetros reais:**
```
LOAD_IMG    :    784 ciclos
CALC_HIDDEN : 100.736 ciclos  (128 × 787)
CALC_OUTPUT :   1.300 ciclos  (10  × 130)
ARGMAX      :      10 ciclos
Total       : 102.830 ciclos
```

**Resultado esperado:** `CYCLES ≈ 102.830` (±2 ciclos de margem de
leitura via polling).

---

## TC-INT-07 — STATUS retorna IDLE após DONE

**Motivação:**
O estado DONE dura exatamente 1 ciclo na FSM. Após esse ciclo, o
sistema deve estar em IDLE e pronto para uma nova inferência. Se STATUS
permanecer DONE, o ARM poderia interpretar uma nova inferência como
ainda estando concluída.

**Sequência:**
1. Detectar DONE via polling
2. Ler STATUS novamente no ciclo seguinte

**Resultado esperado:** STATUS retorna a `2'b00` (IDLE) ou permanece
em DONE apenas durante a leitura do poll que o detectou.

**Observação de implementação:** como o polling consome ≥ 2 ciclos por
leitura, STATUS já está em IDLE quando a segunda leitura ocorre. Isso
é visível no output do testbench: a leitura de RESULT mostra
`STATUS = 00`.

---

## Resumo dos casos de teste

| ID | Fase | O que verifica |
|----|------|----------------|
| TC-INT-01 | Reset | STATUS=IDLE após reset |
| TC-INT-02 | LOAD | Carregamento de 784 pixels sem efeito colateral |
| TC-INT-03 | START | CTRL[0] gera pulso de start; STATUS→BUSY |
| TC-INT-04 | POLLING | DONE detectado dentro do timeout |
| TC-INT-05 | RESULT | pred_hardware == pred_golden |
| TC-INT-06 | CYCLES | Latência correta em ciclos |
| TC-INT-07 | PÓS-DONE | STATUS retorna a IDLE |

---

## Pré-requisitos antes de executar o testbench

- [ ] Todos os módulos das Fases 2, 3 e 4 validados individualmente
- [ ] `elm_golden.py` executado para a imagem de teste escolhida
- [ ] `img_test.hex` e `pred_ref.hex` presentes em `sim/`
- [ ] `w_in.hex`, `bias.hex` e `beta.hex` gerados por `gen_hex.py`
      e presentes em `sim/`
- [ ] Float ref e Q4.12 concordam para a imagem escolhida
      (verificado pelo output de `elm_golden.py`)