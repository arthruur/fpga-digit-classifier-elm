# **Documentação Técnica: Módulo ram\_img (ram\_img.v)**

**Projeto:** elm\_accel — Co-processador ELM em FPGA

**Disciplina:** TEC 499 · MI Sistemas Digitais · UEFS 2026.1

**Marco:** 1 / Fase 3

## **1\. Visão Geral**

O módulo ram\_img.v é o ponto de entrada de dados do co-processador elm\_accel. Sua responsabilidade é receber e armazenar temporariamente os 784 bytes que representam uma imagem MNIST de 28×28 pixels em escala de cinza, disponibilizando-os sequencialmente para o datapath durante a inferência.

**Características Principais da Arquitetura:**

* **Tipo:** BRAM síncrona de porta única (*single-port synchronous RAM*), 784 posições × 8 bits.
* **Inferência pelo Quartus:** O padrão de declaração `reg [7:0] mem [783:0]` combinado com o bloco `always @(posedge clk)` é reconhecido automaticamente pelo Quartus Prime e sintetizado como bloco de memória embarcada (BRAM M10K do Cyclone V), evitando o desperdício de centenas de flip-flops.
* **Comportamento Read-Before-Write:** Quando escrita e leitura ocorrem simultaneamente no mesmo endereço, o valor retornado em `data_out` é o dado *anterior* à escrita do ciclo corrente. Esse comportamento é o padrão de BRAM do Quartus e deve ser considerado pela FSM de controle.
* **Latência de Leitura:** 1 ciclo de clock (comportamento síncrono). O endereço é apresentado no ciclo N e o dado está disponível no ciclo N+1.

### 1.1. Fundamentos Teóricos: Por que BRAM em vez de Flip-Flops?

Uma imagem MNIST ocupa 784 bytes = 6.272 bits. Implementar essa memória com flip-flops individuais consumiria 6.272 LUTs/FFs do Cyclone V — um desperdício proibitivo para uma única memória de trabalho.

Os blocos M10K do Cyclone V são células de memória dedicadas (10.240 bits cada) que não competem com os recursos lógicos gerais do dispositivo. Um único bloco M10K acomoda os 784 bytes da imagem com folga, liberando toda a malha lógica para a FSM, a unidade MAC e a LUT de ativação.

O padrão sintetizável reconhecido pelo Quartus para inferência de BRAM exige exatamente dois elementos: (1) a declaração `reg [DADOS] mem [PROFUNDIDADE]` fora de qualquer bloco procedural, e (2) a leitura do dado dentro de um bloco `always @(posedge clk)`. A ausência de qualquer uma dessas condições força a síntese em flip-flops.

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Todas as operações (leitura e escrita) ocorrem na borda de subida. |
| we | Entrada | 1 bit | **Write Enable.** Se `1`, o byte `data_in` é gravado na posição `addr` na próxima borda de subida. Se `0`, a memória é preservada. |
| addr | Entrada | 10 bits | **Endereço.** Indexa as 784 posições (0 a 783). Os 10 bits cobrem até 1023 — os endereços 784 a 1023 não correspondem a pixels válidos e não devem ser acessados pela FSM. |
| data\_in | Entrada | 8 bits | **Dado de Escrita.** Valor do pixel a ser armazenado, no intervalo 0 (preto) a 255 (branco). |
| data\_out | Saída | 8 bits | **Dado de Leitura.** Valor do pixel na posição `addr`, disponível 1 ciclo após a apresentação do endereço. |

## **3\. Arquitetura e Lógica do Circuito**

### **3.1. Escrita Condicional (Write Enable)**

O sinal `we` atua como um guardião da memória. Durante o estado `LOAD_IMG` da FSM, `we` é ativado para que o driver (Marco 2) possa transferir os 784 pixels byte a byte. Nos demais estados (`CALC_HIDDEN`, `CALC_OUTPUT`, `ARGMAX`), `we` permanece em `0`, tornando a ram\_img efetivamente somente leitura — o datapath pode ler pixels quantas vezes precisar sem risco de corrupção.

Essa separação entre fase de carga e fase de leitura é uma decisão arquitetural deliberada: a porta única da BRAM é compartilhada no tempo entre escrita (via driver) e leitura (via MAC), cabendo à FSM garantir que nunca ocorram simultaneamente.

### **3.2. Leitura Síncrona e Latência de 1 Ciclo**

A leitura é registrada: o endereço `addr` é amostrado na borda de subida do clock e o dado correspondente aparece em `data_out` apenas no ciclo seguinte. Esse comportamento é inerente às BRAMs síncronas e exige que a FSM "adiante" o endereço do próximo pixel em relação ao ciclo em que o valor é efetivamente necessário pela MAC.

Em termos de pipeline:

* **Ciclo N:** FSM apresenta `addr = pixel_idx`
* **Ciclo N+1:** `data_out` contém `mem[pixel_idx]`, MAC processa o valor

### **3.3. Comportamento Read-Before-Write**

Quando `we=1` e a leitura ocorre no mesmo endereço que está sendo escrito, `data_out` reflete o valor *anterior* à escrita. Esse comportamento, denominado *read-before-write* (ou *read-first*), é o modo padrão das BRAMs M10K do Quartus e deve ser documentado para o desenvolvedor da FSM: se for necessário ler o pixel imediatamente após escrevê-lo no mesmo endereço, um ciclo extra de espera é obrigatório.

## **4\. Metodologia de Validação e Testbench (tb\_ram\_img.v)**

O testbench foi projetado para cobrir os comportamentos funcionais críticos do módulo, com atenção especial à latência de leitura — armadilha frequente em memórias síncronas.

* **TC-IMG-01 — Escrita e leitura no endereço 0:** *Justificativa:* Teste de sanidade fundamental. Garante que a BRAM foi instanciada corretamente e que o endereço base funciona. Usa o valor `0xAB` por ser assimétrico (diferente lendo como unsigned ou signed), facilitando a detecção de erros de extensão de sinal.

* **TC-IMG-02 — Escrita e leitura no endereço máximo (783):** *Justificativa:* Verifica que os 10 bits de endereço cobrem corretamente as 784 posições sem truncamento. Se `addr` fosse declarado com 9 bits, `10'd783` seria truncado para `9'd271`, mapeando o último pixel para uma posição errada.

* **TC-IMG-03 — `we=0` não sobrescreve dado existente:** *Justificativa:* Confirma que o guardião `we` funciona. Uma BRAM com `we` conectado permanentemente a `1` por erro de síntese sobrescreveria todos os pixels a cada ciclo de clock.

* **TC-IMG-04 — Latência de leitura é exatamente 1 ciclo:** *Justificativa:* Documenta explicitamente o comportamento síncrono. O dado não está disponível no mesmo ciclo em que o endereço é apresentado. Se a FSM ignorar esse ciclo de latência, lerá o pixel errado (o do endereço anterior).

* **TC-IMG-05 — Escrita sequencial de 784 pixels e verificação por amostragem:** *Justificativa:* Simula a operação real do estado `LOAD_IMG`. Carrega toda a imagem com o padrão `data_in = addr[7:0]` (verificável matematicamente) e valida 5 posições representativas: início (0), quartil (100), meio (391), três quartos (500) e fim (783).

* **TC-IMG-06 — Sobrescrita entre inferências:** *Justificativa:* Garante que a segunda inferência não herda pixels da primeira. Uma nova imagem deve poder sobrescrever completamente a anterior sem resíduos.

## **5\. Conclusão da Fase**

Os 6 casos de teste resultaram em PASS durante a simulação RTL. A ram\_img demonstrou correta inferência como BRAM síncrona pelo Quartus, comportamento read-before-write documentado, e isolamento total entre endereços adjacentes, estando apta para integração com a FSM de controle no módulo elm\_accel.v.