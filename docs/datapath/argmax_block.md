# **Documentação Técnica: Módulo argmax\_block**

**Comparador Sequencial de Máxima Probabilidade (Argmax)**

## **1\. Visão Geral**

O módulo argmax\_block.v é a última etapa do caminho de dados (datapath) do co-processador ELM. A sua função é analisar os 10 escores de saída (gerados pelos neurónios da camada linear final) e determinar qual deles possui o valor mais alto. O índice (0 a 9\) desse valor máximo representa a predição final da rede neural (qual dígito a imagem representa).

**Características Principais da Arquitetura:**

* **Arquitetura Sequencial:** Em vez de instanciar 9 comparadores paralelos (o que gastaria muita área na FPGA), este módulo partilha **apenas 1 comparador lógico**. Ele avalia um escore por ciclo de relógio (clock) ao longo de 10 ciclos.  
* **Formato de Dados:** Opera com valores Q4.12 com sinal (16 bits). Como a última camada não tem ativação, os escores podem ser largamente negativos ou positivos.  
* **Tolerância a Interrupções:** Pode ser pausado (através do sinal enable) ou abortado e reiniciado (através do sinal start) a qualquer momento, sem corromper a inferência seguinte.

## **2\. Interface do Módulo**

| Porta | Direção | Largura | Descrição |
| :---- | :---- | :---- | :---- |
| clk | Entrada | 1 bit | **Relógio do sistema.** Atualiza o contador e os registos no flanco ascendente. |
| rst\_n | Entrada | 1 bit | **Reset Assíncrono (ativo-baixo).** Zera o módulo imediatamente, independentemente do clock. |
| start | Entrada | 1 bit | **Reinício de Busca.** Um pulso de 1 ciclo vindo da FSM que limpa o pódio e prepara o módulo para uma nova inferência. |
| enable | Entrada | 1 bit | **Validação de Dados.** Quando 1, indica que as portas y\_in e k\_in contêm dados válidos para serem comparados neste ciclo. |
| y\_in | Entrada | 16 bits | **Escore do Neurónio.** Valor da pontuação (Q4.12 *signed*). |
| k\_in | Entrada | 4 bits | **Índice do Neurónio.** O identificador do escore atual (varia de 0 a 9). |
| max\_idx | Saída | 4 bits | **Vencedor (Predição).** O índice que obteve a pontuação mais alta. |
| max\_val | Saída | 16 bits | **Escore Vencedor.** O valor da maior pontuação. (Útil para *debug* ou cálculo de nível de confiança). |
| done | Saída | 1 bit | **Bandeira de Conclusão.** Fica em 1 por exatamente 1 ciclo de clock após o 10º escore ser avaliado. |

## **3\. Filosofia de Funcionamento (A Lógica do Pódio)**

O comportamento do módulo pode ser comparado a um juiz a avaliar um desfile de 10 candidatos:

### **O Pódio Vazio (Inicialização Segura)**

Quando o sinal start é ativado, o módulo prepara o "pódio". O erro mais comum em blocos Argmax é inicializar o valor máximo com 0. Como a saída da rede pode ser inteiramente negativa, o módulo inicializa max\_val com a constante MIN\_Q412 (16'h8000 / \-32768). Isso garante matematicamente que o primeiro escore válido (índice 0\) vencerá a comparação inicial e ocupará o pódio.

### **A Comparação Estrita (Desempate)**

A cada ciclo em que enable é 1, o módulo compara o candidato atual (y\_in) com o rei do pódio (max\_val) usando uma comparação com sinal ($signed(y\_in) \> $signed(max\_val)).

* O uso estrito do operador maior (\>) em vez de maior-ou-igual (\>=) garante que, **em caso de empate exato entre dois escores, o primeiro candidato avaliado mantém a sua posição**. Isso torna o hardware determinístico.

### **O Contador e o Pulso Final**

Internamente, um contador (cmp\_count) regista quantos elementos já foram avaliados. Quando este atinge 9 (o 10º elemento) e o enable está ativo, o módulo entende que o desfile acabou. No ciclo seguinte, ele levanta a bandeira done \= 1 por apenas um ciclo, avisando a Máquina de Estados (FSM) que o resultado final já está disponível na porta max\_idx.

## **4\. Asserções de Validação (*Cão de Guarda*)**

O código de produção inclui um bloco de asserções protegido pela macro \`ifdef SIMULATION. Durante a fase de testes e integração, se a Máquina de Estados (FSM) apresentar um defeito e fornecer um índice inválido (k\_in \> 9) enquanto o enable estiver ativo, o módulo imprimirá um erro imediatamente na consola do simulador com o carimbo de tempo exato ($time). Esta estrutura não consome portas lógicas (LUTs/Flip-Flops) na síntese para a FPGA, operando exclusivamente como uma ferramenta de segurança para os engenheiros de verificação.