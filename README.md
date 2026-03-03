# FPGA Digit Classifier (ELM)

## Descrição do Projeto
[cite_start]Este projeto implementa um sistema classificador de dígitos numéricos embarcado em uma arquitetura SoC (System-on-Chip) heterogênea, composta por um processador ARM e um acelerador de hardware em FPGA[cite: 24]. [cite_start]O sistema utiliza uma rede neural do tipo *Extreme Learning Machine* (ELM) para realizar a inferência de imagens MNIST[cite: 33, 49].

[cite_start]O desenvolvimento abrange desde a arquitetura de hardware de baixo nível até a camada de aplicação, incluindo um driver de dispositivo customizado para o sistema operacional Linux[cite: 95, 111].

## Arquitetura e Tech Stack
[cite_start]O sistema foi desenvolvido para a plataforma **DE1-SoC** [cite: 20] e utiliza:
* [cite_start]**Hardware (FPGA/RTL):** Verilog, FSM de controle, datapath MAC (Multiplica-Acumula) e aritmética de ponto fixo Q4.12[cite: 84, 88, 93].
* [cite_start]**Comunicação:** Interface via MMIO (*Memory-Mapped I/O*) para controle e troca de dados entre o HPS (ARM) e o acelerador[cite: 41, 109].
* [cite_start]**Driver:** Implementação em Assembly ARM/C para interface kernel/userspace[cite: 97, 108].
* [cite_start]**Aplicação:** Aplicação CLI em C para validação, métricas de performance (latência, throughput) e *benchmarking*[cite: 111, 116].

## Estrutura do Repositório
```text
/
├── README.md           # Essencial: levantamento de requisitos, instruções de instalação [cite: 150, 173]
├── docs/               # Relatórios, manuais e baremas
├── rtl/                # Código Verilog do IP elm_accel e FSM [cite: 140]
├── sim/                # Testbenches e scripts de automação [cite: 147]
├── driver/             # Código Assembly ARM do Driver Linux [cite: 105, 166]
├── app/                # Código da aplicação em C [cite: 111, 183]
└── scripts/            # Scripts para compilação (Makefile) e testes
