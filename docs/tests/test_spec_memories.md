# Especificação de Testes — Fase 3: Memórias elm_accel
## Abordagem TDD (Test-Driven Development)

> **Como usar este documento**
> Cada caso de teste aqui descrito tem um `ID` único que é referenciado
> diretamente nos testbenches (ex: `// TC-IMG-01`). Leia a justificativa
> de cada caso antes de implementar o módulo — o objetivo do TDD é que
> os testes guiem as decisões de implementação, não o contrário.
>
> **Ordem obrigatória:** escreva TODOS os testbenches de um módulo antes
> de escrever uma linha do módulo em si. Só avance para o próximo módulo
> quando todos os testes do atual passarem.

---

## Convenções

**Larguras de dados por memória:**

| Memória       | Posições  | Bits/posição | Tipo  | Arquivo de init |
|---------------|-----------|--------------|-------|-----------------|
| ram_img       | 784       | 8 bits       | RAM   | — (escrita em runtime) |
| rom_pesos     | 128 × 784 = 100.352 | 16 bits | ROM | w_in.mif |
| rom_bias      | 128       | 16 bits      | ROM   | bias.mif        |
| rom_beta      | 10 × 128 = 1.280    | 16 bits | ROM | beta.mif |
| ram_hidden    | 128       | 16 bits      | RAM   | — (escrita em runtime) |

**Endereçamento composto (ROM de pesos):**

```
rom_pesos: addr = {neuron_idx[6:0], pixel_idx[9:0]}  → 17 bits
rom_beta:  addr = {class_idx[3:0],  hidden_idx[6:0]} → 11 bits
```

**Formato Q4.12 (16 bits signed) — para memórias de 16 bits:**

| Valor float | Inteiro | Hex    |
|-------------|---------|--------|
| +1.0        | 4096    | 0x1000 |
| +0.5        | 2048    | 0x0800 |
| 0.0         | 0       | 0x0000 |
| -0.5        | -2048   | 0xF800 |
| -1.0        | -4096   | 0xF000 |
| +7.9997 (MAX) | 32767 | 0x7FFF |
| -8.0 (MIN)  | -32768  | 0x8000 |

**Critério de PASS:** igualdade bit a bit (`===`) em Verilog para
todos os casos, sem tolerância — memórias devem ser exatas.

---

## Módulo 1: ram_img.v

### Comportamento esperado (contrato do módulo)

```
BRAM síncrona de porta única, 784 posições × 8 bits.

A cada borda de subida do clock:
  SE we = 1  →  mem[addr] ← data_in   (escrita)
  SEMPRE     →  data_out  ← mem[addr] (leitura registrada)

Leitura tem latência de 1 ciclo (síncrona).
we = 0 não altera o conteúdo da memória.
Não há reset assíncrono — conteúdo indefinido até primeira escrita.
```

**Portas do módulo:**
```verilog
module ram_img (
    input        clk,
    input        we,
    input  [9:0] addr,     // 0..783
    input  [7:0] data_in,
    output reg [7:0] data_out
);
```

---

### TC-IMG-01 — Escrita e leitura simples no endereço 0

**Motivação:**
O caso mais básico possível. Se escrever e ler no endereço 0
não funcionar, nenhum outro teste tem valor. Verifica que
a BRAM foi inferida corretamente pelo Quartus.

**Sequência:**
1. Ciclo 1: `we=1, addr=0, data_in=0xAB`
2. Ciclo 2: `we=0, addr=0`
3. Ciclo 3: verificar `data_out === 0xAB`

**Resultado esperado:** `data_out = 0xAB` no ciclo 3.

**O que falha se errar:** a BRAM não foi sintetizada corretamente
ou a latência de leitura está sendo ignorada.

---

### TC-IMG-02 — Escrita e leitura no endereço máximo (783)

**Motivação:**
Verifica que o endereço de 10 bits cobre corretamente o último
pixel. Um erro de truncamento no addr poderia fazer addr=783
ser interpretado como addr=271 (783 & 0xFF), por exemplo.

**Sequência:**
1. Ciclo 1: `we=1, addr=783, data_in=0xFF`
2. Ciclo 2: `we=0, addr=783`
3. Ciclo 3: verificar `data_out === 0xFF`

**Resultado esperado:** `data_out = 0xFF`.

---

### TC-IMG-03 — we=0 não sobrescreve dado existente

**Motivação:**
Garante que a memória só escreve quando explicitamente
habilitada. Um erro de lógica de we poderia fazer qualquer
ciclo de clock sobrescrever a memória.

**Sequência:**
1. Escrever `0x55` no addr=10
2. Ciclo seguinte: `we=0, addr=10, data_in=0xAA` (tentativa de sobrescrita)
3. Ler addr=10
4. Verificar que `data_out === 0x55` (não 0xAA)

**Resultado esperado:** `data_out = 0x55`.

---

### TC-IMG-04 — Leitura tem latência de exatamente 1 ciclo

**Motivação:**
BRAMs síncronas retornam o dado no ciclo SEGUINTE ao endereço.
Se o testbench (ou a FSM) ler no mesmo ciclo da apresentação
do endereço, obterá lixo. Este teste documenta e verifica
esse comportamento explicitamente.

**Sequência:**
1. Ciclo 1: `we=1, addr=5, data_in=0x42`
2. Ciclo 2: `we=0, addr=5` — dado NÃO deve estar disponível ainda
3. Ciclo 3: verificar `data_out === 0x42`

**Nota:** no ciclo 2, `data_out` pode ter qualquer valor — não é falha.
O PASS é verificado apenas no ciclo 3.

---

### TC-IMG-05 — Escrita sequencial de 784 pixels e verificação por amostragem

**Motivação:**
Simula o comportamento real do estado LOAD_IMG da FSM:
784 escritas consecutivas, uma por ciclo. Verificar por
amostragem (posições 0, 100, 391, 500, 783) garante que
não há aliasing de endereço nem falha de escrita esporádica.

**Sequência:**
1. Loop: para addr = 0 a 783, escrever `data_in = addr[7:0]`
   (valor = índice truncado para 8 bits, padrão verificável)
2. Ler e verificar as posições: 0→0x00, 100→0x64, 391→0x87,
   500→0xF4, 783→0x0F

**Resultado esperado:** todas as 5 posições amostradas corretas.

---

### TC-IMG-06 — Sobrescrita: nova escrita substitui valor anterior

**Motivação:**
A imagem deve ser substituída a cada nova inferência. Se a
memória não aceitar sobrescrita, o sistema classificaria
sempre a primeira imagem enviada.

**Sequência:**
1. Escrever `0x10` no addr=50
2. Escrever `0xBE` no addr=50 (sobrescrita)
3. Ler addr=50
4. Verificar `data_out === 0xBE`

**Resultado esperado:** `data_out = 0xBE`.

---

## Módulo 2: rom_pesos.v

### Comportamento esperado (contrato do módulo)

```
ROM síncrona de porta única, 100.352 posições × 16 bits.
Inicializada com w_in.mif em tempo de síntese.

A cada borda de subida do clock:
  data_out ← mem[addr]  (leitura registrada, latência 1 ciclo)

Sem escrita em runtime. we não existe neste módulo.
Endereço composto: addr = {neuron_idx[6:0], pixel_idx[9:0]} → 17 bits.
```

**Portas do módulo:**
```verilog
module rom_pesos (
    input         clk,
    input  [16:0] addr,   // {neuron_idx[6:0], pixel_idx[9:0]}
    output reg [15:0] data_out
);
```

---

### TC-WGT-01 — Leitura do peso W[0][0] (neurônio 0, pixel 0)

**Motivação:**
Verifica que a ROM foi inicializada e que o endereço base
(0x00000) retorna o valor correto do MIF. É o teste de
sanidade fundamental da ROM.

**Pré-requisito:** gerar `w_in.mif` e anotar o valor esperado
em W[0][0] antes de escrever este teste.

**Sequência:**
1. Ciclo 1: `addr = {7'd0, 10'd0}` (neurônio 0, pixel 0)
2. Ciclo 2: verificar `data_out === W_IN_0_0` (valor do MIF)

**Resultado esperado:** `data_out = <valor do MIF na posição 0>`.

---

### TC-WGT-02 — Leitura do peso W[0][783] (neurônio 0, último pixel)

**Motivação:**
Verifica que os bits baixos do endereço (pixel_idx) chegam
a 783 sem truncamento. Um addr de 16 bits em vez de 17
cortaria o bit mais significativo de pixel_idx.

**Sequência:**
1. `addr = {7'd0, 10'd783}`
2. Verificar `data_out === W_IN_0_783`

---

### TC-WGT-03 — Leitura do peso W[127][0] (último neurônio, pixel 0)

**Motivação:**
Verifica que os bits altos do endereço (neuron_idx) funcionam
corretamente. Erro no campo neuron_idx faria todos os neurônios
ler pesos do neurônio 0.

**Sequência:**
1. `addr = {7'd127, 10'd0}`
2. Verificar `data_out === W_IN_127_0`

---

### TC-WGT-04 — Leitura do peso W[127][783] (posição máxima)

**Motivação:**
Endereço máximo = 17'b1_1111_1111_1111_1111 = 0x1FFFF.
Verifica que a ROM tem profundidade suficiente e que não há
overflow de endereçamento.

**Sequência:**
1. `addr = {7'd127, 10'd783}` = 17'd100351
2. Verificar `data_out === W_IN_127_783`

---

### TC-WGT-05 — Latência de leitura: 1 ciclo de clock

**Motivação:**
Idêntico ao TC-IMG-04, mas para ROM. A FSM precisa saber
que deve esperar 1 ciclo após apresentar o endereço antes
de usar o dado. Documenta e verifica esse contrato.

**Sequência:**
1. Ciclo 1: `addr = {7'd0, 10'd0}`
2. Ciclo 2: `data_out` NÃO deve ser usado (latência)
3. Ciclo 3: verificar `data_out === W_IN_0_0`

---

### TC-WGT-06 — Dois endereços consecutivos retornam valores distintos

**Motivação:**
Verifica que acessos consecutivos não retornam o mesmo valor
por inércia de registrador. Detecta erro de enable ou
registrador travado.

**Sequência:**
1. Ler W[0][0] → anotar valor A
2. Ler W[1][0] → anotar valor B
3. Verificar A !== B (assumindo que os pesos são diferentes,
   o que é garantido pelo MIF treinado)

**Nota:** este teste só é válido se W[0][0] ≠ W[1][0] no MIF.
Verificar no Python antes de escrever o testbench.

---

## Módulo 3: rom_bias.v

### Comportamento esperado (contrato do módulo)

```
ROM síncrona de porta única, 128 posições × 16 bits.
Inicializada com bias.mif em tempo de síntese.

A cada borda de subida do clock:
  data_out ← mem[addr]  (latência 1 ciclo)

Endereço direto: addr = neuron_idx[6:0] → 7 bits.
```

**Portas do módulo:**
```verilog
module rom_bias (
    input        clk,
    input  [6:0] addr,    // 0..127
    output reg [15:0] data_out
);
```

---

### TC-BIAS-01 — Leitura do bias b[0]

**Motivação:**
Sanidade básica. Verifica que a ROM de bias foi inicializada
e que o endereço 0 retorna o valor correto.

**Sequência:**
1. `addr = 7'd0`
2. Verificar `data_out === BIAS_0`

---

### TC-BIAS-02 — Leitura do bias b[127] (endereço máximo)

**Motivação:**
Verifica que os 7 bits de endereço cobrem corretamente
as 128 posições (0..127). Um erro de largura faria
addr=127 ser truncado para addr=63 (se addr fosse 6 bits).

**Sequência:**
1. `addr = 7'd127`
2. Verificar `data_out === BIAS_127`

---

### TC-BIAS-03 — Varredura completa: todos os 128 biases legíveis

**Motivação:**
Garante que não há posição inacessível ou com valor corrompido
na ROM. Lê todas as 128 posições e compara com o array
gerado pelo script Python a partir do bias.mif.

**Sequência:**
1. Loop addr = 0 a 127
2. Para cada addr, verificar `data_out === bias_ref[addr]`
   onde `bias_ref` é um array de 128 valores carregado de
   um arquivo gerado pelo script `gen_mif.py`

**Critério:** 128/128 posições corretas.

---

## Módulo 4: rom_beta.v

### Comportamento esperado (contrato do módulo)

```
ROM síncrona de porta única, 1.280 posições × 16 bits.
Inicializada com beta.mif em tempo de síntese.

A cada borda de subida do clock:
  data_out ← mem[addr]  (latência 1 ciclo)

Endereço composto: addr = {class_idx[3:0], hidden_idx[6:0]} → 11 bits.
```

**Portas do módulo:**
```verilog
module rom_beta (
    input         clk,
    input  [10:0] addr,   // {class_idx[3:0], hidden_idx[6:0]}
    output reg [15:0] data_out
);
```

---

### TC-BETA-01 — Leitura de β[0][0] (classe 0, neurônio oculto 0)

**Motivação:**
Sanidade básica da ROM beta. Verifica inicialização e
endereçamento base corretos.

**Sequência:**
1. `addr = {4'd0, 7'd0}`
2. Verificar `data_out === BETA_0_0`

---

### TC-BETA-02 — Leitura de β[9][127] (endereço máximo)

**Motivação:**
Endereço máximo = 11'b111_1111_1111 = 0x7FF = 2047.
Verifica que a ROM tem profundidade suficiente para 10×128
= 1280 posições e que o endereço máximo é acessível.

**Sequência:**
1. `addr = {4'd9, 7'd127}`
2. Verificar `data_out === BETA_9_127`

---

### TC-BETA-03 — Independência entre classes: β[0][0] ≠ β[1][0]

**Motivação:**
Verifica que o campo class_idx distingue corretamente linhas
diferentes da matriz β. Um erro no campo class_idx faria
todas as 10 classes usar os mesmos pesos.

**Sequência:**
1. Ler β[0][0] → valor A
2. Ler β[1][0] → valor B
3. Verificar A !== B (assumindo diferença no MIF treinado)

---

### TC-BETA-04 — Varredura por amostragem: 10 classes × 5 neurônios

**Motivação:**
Verificação parcial da integridade do MIF sem simular
todas as 1280 posições. Lê 50 posições estratégicas
(primeira e última de cada classe) e compara com referência.

**Posições a verificar:**
```
Para cada class_idx c em {0, 4, 9}:
  Ler β[c][0], β[c][63], β[c][127]
  Comparar com beta_ref[c][0], beta_ref[c][63], beta_ref[c][127]
```

**Critério:** 9 posições corretas (3 classes × 3 neurônios).

---

## Módulo 5: ram_hidden.v

### Comportamento esperado (contrato do módulo)

```
BRAM síncrona de porta única, 128 posições × 16 bits.

A cada borda de subida do clock:
  SE we = 1  →  mem[addr] ← data_in   (escrita)
  SEMPRE     →  data_out  ← mem[addr] (leitura registrada)

Escrita pela FSM ao fim do cálculo de cada neurônio (estado HIDDEN_LAYER).
Leitura pela FSM durante o estado OUTPUT_LAYER.
Latência de leitura: 1 ciclo.
```

**Portas do módulo:**
```verilog
module ram_hidden (
    input        clk,
    input        we,
    input  [6:0] addr,      // 0..127
    input  [15:0] data_in,
    output reg [15:0] data_out
);
```

---

### TC-HID-01 — Escrita e leitura simples no endereço 0

**Motivação:**
Sanidade básica. Idêntico ao TC-IMG-01, mas para dados
de 16 bits em Q4.12. Verifica BRAM de 16 bits inferida
corretamente.

**Sequência:**
1. Ciclo 1: `we=1, addr=0, data_in=0x1000` (+1.0 em Q4.12)
2. Ciclo 2: `we=0, addr=0`
3. Ciclo 3: verificar `data_out === 0x1000`

---

### TC-HID-02 — Escrita e leitura no endereço máximo (127)

**Motivação:**
Verifica que os 7 bits de endereço cobrem corretamente
as 128 posições. addr=127 = 7'b111_1111, caso extremo.

**Sequência:**
1. `we=1, addr=127, data_in=0xF000` (-1.0 em Q4.12)
2. Ler addr=127
3. Verificar `data_out === 0xF000`

---

### TC-HID-03 — Escrita de valor negativo Q4.12 preserva sinal

**Motivação:**
A saída da PWL pode ser negativa (ex: -0.75 = 0xF400).
Verifica que a RAM armazena e retorna corretamente valores
com bit de sinal 1 — um erro de largura de porta poderia
truncar o bit 15.

**Sequência:**
1. `we=1, addr=10, data_in=0xF400` (-0.75 em Q4.12)
2. Ler addr=10
3. Verificar `data_out === 0xF400`

---

### TC-HID-04 — Escrita sequencial de 128 neurônios

**Motivação:**
Simula o comportamento real do estado HIDDEN_LAYER:
128 escritas consecutivas, uma por neurônio. Verifica
que não há colisão de endereço ou falha de escrita.

**Sequência:**
1. Loop addr=0 a 127: `we=1, data_in = 0x1000 + addr`
   (valores distintos e verificáveis)
2. Verificar por amostragem: addr=0→0x1000, addr=64→0x1040,
   addr=127→0x107F

**Resultado esperado:** 3 posições amostradas corretas.

---

### TC-HID-05 — Isolamento: escrita em addr X não afeta addr Y

**Motivação:**
Verifica que não há aliasing de endereço. Dois neurônios
com endereços diferentes devem ter valores independentes.

**Sequência:**
1. Escrever `0x0800` em addr=20
2. Escrever `0x0400` em addr=21
3. Ler addr=20 → verificar `0x0800`
4. Ler addr=21 → verificar `0x0400`

---

### TC-HID-06 — Sobrescrita: segunda inferência não contamina a primeira

**Motivação:**
Entre duas inferências, a FSM sobrescreve a RAM_HIDDEN
com os novos valores de h. Verifica que a sobrescrita
é completa e sem resíduos da inferência anterior.

**Sequência:**
1. Primeira "inferência": escrever 0xAAAA em addr=5
2. Segunda "inferência": escrever 0x5555 em addr=5
3. Ler addr=5
4. Verificar `data_out === 0x5555`

---

## Módulo 6: Verificação Integrada das Memórias

### TC-MEM-INT-01 — ram_img e rom_pesos operam em endereços simultâneos

**Motivação:**
Na implementação real, a FSM lê um pixel de ram_img e um
peso de rom_pesos no mesmo ciclo para alimentar a MAC.
Verifica que os dois módulos operam independentemente sem
interferência de barramento.

**Sequência:**
1. Carregar ram_img com padrão conhecido
2. No mesmo ciclo, apresentar addr para ram_img E addr para rom_pesos
3. Verificar que ambas as saídas estão corretas no ciclo seguinte

---

### TC-MEM-INT-02 — ram_hidden aceita escrita enquanto rom_pesos é lida

**Motivação:**
Durante HIDDEN_LAYER, a FSM escreve em ram_hidden ao fim
de cada neurônio enquanto ainda lê rom_pesos para o próximo.
Verifica que as duas operações não se interferem.

**Sequência:**
1. Ciclo 1: ler rom_pesos[addr_A], escrever ram_hidden[addr_B]
2. Verificar que ram_hidden[addr_B] tem o valor correto
3. Verificar que rom_pesos retornou o valor correto de addr_A

---

## Resumo dos casos de teste por módulo

| Módulo       | Total | Funcionalidade | Endereçamento | Robustez |
|--------------|-------|---------------|---------------|----------|
| ram_img      | 6     | TC-IMG-01,06  | TC-IMG-02,05  | TC-IMG-03,04 |
| rom_pesos    | 6     | TC-WGT-01     | TC-WGT-02..04 | TC-WGT-05,06 |
| rom_bias     | 3     | TC-BIAS-01    | TC-BIAS-02    | TC-BIAS-03 |
| rom_beta     | 4     | TC-BETA-01    | TC-BETA-02,03 | TC-BETA-04 |
| ram_hidden   | 6     | TC-HID-01,06  | TC-HID-02,04  | TC-HID-03,05 |
| integração   | 2     | TC-MEM-INT-01,02 | —          | —        |
| **Total**    | **27**| | | |

---

## Ordem de implementação recomendada (TDD)

```
1. ram_img.v       → mais simples, sem MIF, valida o padrão BRAM
2. ram_hidden.v    → idêntico ao ram_img, mas 16 bits
3. rom_bias.v      → ROM mais simples (128 posições, addr direto)
4. rom_beta.v      → ROM com endereço composto de 11 bits
5. rom_pesos.v     → ROM mais complexa (endereço composto de 17 bits)
6. Integração      → TC-MEM-INT após todos os módulos passarem
```

> **Regra de ouro:** não avance de módulo com testes falhando.
> Um teste falhando na ram_img vai propagar erro silencioso
> para todos os módulos que dependem dela.

---

## Pré-requisitos antes de escrever os testbenches

Antes de implementar qualquer módulo desta fase, os seguintes
artefatos devem estar prontos (Fase 1 do roadmap):

- [ ] `w_in.mif` gerado e revisado (valores W_IN_0_0, W_IN_0_783,
      W_IN_127_0, W_IN_127_783 anotados para uso nos TCs)
- [ ] `bias.mif` gerado (BIAS_0 e BIAS_127 anotados)
- [ ] `beta.mif` gerado (BETA_0_0 e BETA_9_127 anotados)
- [ ] Script Python `gen_mif.py` funcional para gerar os arquivos
- [ ] Array `bias_ref[128]` exportado em formato `$readmemh`
      para uso no TC-BIAS-03
