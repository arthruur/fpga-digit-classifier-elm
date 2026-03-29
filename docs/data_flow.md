# Caminho do Dado: Arquitetura e Fluxo

Este documento descreve o fluxo de dados do co-processador `elm_accel`, desde a recepção dos pixels até a predição final.

## Diagrama de Fluxo Geral

O diagrama abaixo ilustra como os dados transitam entre os módulos e as memórias durante os diferentes estados da FSM.

```mermaid
graph TD
    subgraph "HPS / ARM"
        A[Interface C/Driver]
    end

    subgraph "Camada de Interface (reg_bank)"
        B{MMIO Write 0x08}
        C[Registrador IMG]
    end

    subgraph "Armazenamento e Datapath"
        D[(ram_img)]
        E[pixel_q412]
        F[mac_unit]
        G[pwl_activation]
        H[(ram_hidden)]
    end

    subgraph "Memórias de Parâmetros (ROMs)"
        W[(rom_pesos)]
        B1[(rom_bias)]
        B2[(rom_beta)]
    end

    subgraph "Predição"
        I[Buffer y_buf]
        J[argmax_block]
        K[max_idx]
    end

    %% Fluxo Etapa 1
    A -- "Escrita Sequencial" --> B
    B -- "Endereco/Dado" --> C
    C -- "we_img" --> D

    %% Fluxo Etapa 2 & 3
    D -- "img_data (8-bit)" --> E
    E -- "mac_a (Q4.12)" --> F
    W -- "W_in (j)" --> F
    B1 -- "bias (i)" --> F
    F -- "acc_out" --> G
    G -- "we_hidden" --> H

    %% Fluxo Etapa 4
    H -- "h_rdata" --> F
    B2 -- "beta (k)" --> F
    F -- "y_capture" --> I

    %% Fluxo Etapa 5 & 6
    I -- "10 scores" --> J
    J -- "done" --> K
    K -- "result_out" --> B
    B -- "MMIO Read 0x0C" --> A

    style A fill:#f9f,stroke:#333Internal
    style D fill:#bbf,stroke:#333
    style H fill:#bbf,stroke:#333
    style W fill:#dfd,stroke:#333
    style B1 fill:#dfd,stroke:#333
    style B2 fill:#dfd,stroke:#333
```

## Descrição das Interações

1.  **Carga (HPS -> RAM)**: O HPS preenche a `ram_img` via `reg_bank`.
2.  **Hidden Layer**:
    *   Leitura de `ram_img` -> Atribuição para `pixel_q412`.
    *   `mac_unit` multiplica pixels por pesos de `rom_pesos` e soma o bias de `rom_bias`.
    *   O resultado passa por `pwl_activation` (tanh) antes de ser salvo em `ram_hidden`.
3.  **Output Layer**:
    *   Leitura de `ram_hidden` -> Multiplicação por pesos de `rom_beta`.
    *   O resultado acumulado (sem bias) é salvo no buffer `y_buf`.
4.  **Argmax**:
    *   O `argmax_block` varre o `y_buf` e encontra o índice do maior valor.
5.  **Retorno**:
    *   O índice final é disponibilizado no `reg_bank` para leitura pelo HPS.
