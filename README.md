# Classificador de Dígitos (ELM) - FPGA Accelerators

## 1. Levantamento de Requisitos
Esta seção descreve os objetivos do projeto, que consiste na construção de um classificador de dígitos numéricos (MNIST) para operar em um sistema heterogêneo (SoC ARM + FPGA).

* **Objetivo Geral:** Implementar inferência ELM (Extreme Learning Machine) em hardware.
* **Requisitos Funcionais:**
    * Implementar Datapath MAC, FSM de controle, ativação aproximada e Argmax em Verilog (Marco 1).
    * Desenvolver driver em Assembly ARM para controle via MMIO.
    * Desenvolver aplicação C para leitura de imagens, benchmarking e validação.
* **Restrições:** Uso de aritmética de ponto fixo (Q4.12) e integração com interface HPS da DE1-SoC.



## 2. Detalhamento de Softwares
Abaixo estão as ferramentas e versões utilizadas para o desenvolvimento e validação do sistema.

| Categoria | Software | Versão | Função |
| :--- | :--- | :--- | :--- |
| EDA Tool | Quartus Prime | [Insira aqui] | [cite_start]Síntese e implementação do RTL [cite: 165] |
| Simulação | ModelSim/Questa | [Insira aqui] | [cite_start]Testbench e validação RTL [cite: 141] |
| Compilador | GCC (ARM cross-compiler) | [Insira aqui] | Compilação do Driver e App C |
| Controle de Versão | Git | [Insira aqui] | [cite_start]Versionamento e documentação [cite: 142] |

## 3. Especificação de Hardware
[cite_start]O projeto foi desenvolvido para a plataforma de desenvolvimento educacional, garantindo que o hardware atenda aos requisitos de conectividade entre HPS e FPGA[cite: 20].

* **Dispositivo:** DE1-SoC (Cyclone V SE).
* [cite_start]**Interface de Comunicação:** HPS (ARM) para FPGA via Barramento (Bridges)[cite: 165].
* [cite_start]**Recursos Utilizados:** Detalhamento de LUTs, FFs, DSPs e BRAMs conforme relatório de síntese do Quartus[cite: 144].

## 4. Instalação e Configuração do Ambiente
Processo detalhado para replicar o ambiente de desenvolvimento:

1. **Dependências:** [Liste bibliotecas ou ferramentas de sistema necessárias].
2. [cite_start]**Configuração de Hardware:** [Descreva jumpers ou conexões físicas necessárias na DE1-SoC][cite: 156].
3. **Compilação:**
   * Para o RTL: `make rtl_build` (ou comando equivalente).
   * [cite_start]Para o Driver: `make driver_build`[cite: 105].
   * Para a Aplicação C: `make app_build`.

## 5. Testes de Funcionamento e Automação
[cite_start]Descrição dos procedimentos de validação para garantir a integridade do IP[cite: 157].

* [cite_start]**Testbench (Simulação RTL):** Scripts automáticos comparando os resultados do hardware com o "golden model" (referência)[cite: 141].
* [cite_start]**Automação:** Foram criados scripts em [Bash/Python] localizados na pasta `/scripts` para rodar o conjunto de K vetores de teste[cite: 147].
* [cite_start]**Teste de Estabilidade:** Execução de uma imagem conhecida repetidas vezes para validar a consistência do driver e do IP[cite: 107, 168].



## 6. Análise de Resultados
[cite_start]Esta seção será preenchida com a análise crítica dos resultados obtidos, incluindo[cite: 158]:
* **Acurácia:** Comparação do modelo ELM implementado versus modelo teórico.
* [cite_start]**Desempenho:** Latência média, desvio padrão e throughput (imagens/s) obtidos no benchmarking [cite: 116-120].
* **Gargalos:** Identificação de limitações na arquitetura e possíveis melhorias.
