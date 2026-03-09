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
|  |  |  |  |
|  |  |  | |
|  |  | | |
|  |  | | |

## 3. Especificação de Hardware
* **Dispositivo:** DE1-SoC (Cyclone V SE).
* **Interface de Comunicação:** HPS (ARM) para FPGA via Barramento (Bridges).
* **Recursos Utilizados:** Detalhamento de LUTs, FFs, DSPs e BRAMs conforme relatório de síntese do Quartus.

## 4. Instalação e Configuração do Ambiente
Processo detalhado para replicar o ambiente de desenvolvimento:

## 5. Testes de Funcionamento e Automação
Descrição dos procedimentos de validação para garantir a integridade do IP.

* **Testbench (Simulação RTL):** Scripts automáticos comparando os resultados do hardware com o "golden model" (referência).
* **Automação:** Foram criados scripts em [Bash/Python] localizados na pasta `/scripts` para rodar o conjunto de K vetores de teste.
* **Teste de Estabilidade:** Execução de uma imagem conhecida repetidas vezes para validar a consistência do driver e do IP.


## 6. Análise de Resultados
Esta seção será preenchida com a análise crítica dos resultados obtidos, incluindo:
* **Acurácia:** Comparação do modelo ELM implementado versus modelo teórico.
* **Desempenho:** Latência média, desvio padrão e throughput (imagens/s) obtidos no benchmarking.
* **Gargalos:** Identificação de limitações na arquitetura e possíveis melhorias.
