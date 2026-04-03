// =============================================================================
// ram_pesos.v — Pesos W_in da camada oculta da ELM
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Histórico:
//   v1 (rom_pesos.v) — ROM inicializada via $readmemh; sem porta de escrita.
//   v2 (ram_pesos.v) — Convertida para RAM de porta dupla assimétrica:
//                      escrita pelo ARM via MMIO (STORE_WEIGHTS),
//                      leitura pela FSM durante CALC_HIDDEN.
//
// Capacidade:
//   128 neurônios × 784 pixels = 100.352 pesos de 16 bits (Q4.12).
//   Profundidade alocada: 2^17 = 131.072 entradas (layout padded — ver abaixo).
//
// Layout de endereçamento (LEITURA — porta da FSM):
//   addr_r = {neuron_idx[6:0], pixel_idx[9:0]}
//   Cálculo implícito: addr_r = neuron_idx * 1024 + pixel_idx
//
//   Motivação do padding para 1024 em vez de 784:
//     Com addr = {7 bits, 10 bits}, o endereço é uma simples concatenação —
//     sem multiplicador na FSM. O custo são (1024-784)*128 = 30.720 posições
//     não utilizadas (~480 KB de M10K desperdiçado, já contabilizado na
//     síntese anterior com rom_pesos).
//
// Layout de endereçamento (ESCRITA — porta do ARM):
//   addr_w = ponteiro auto-incremental mantido em reg_bank.v
//   Ordem de escrita esperada pelo ARM:
//     W[0][0], W[0][1], ..., W[0][783],   (neurônio 0, 784 writes)
//     W[1][0], W[1][1], ..., W[1][783],   (neurônio 1, 784 writes)
//     ...
//     W[127][0], ..., W[127][783]          (neurônio 127, 784 writes)
//   Total: 100.352 writes para carregar todos os pesos.
//
//   O ponteiro em reg_bank converte o índice linear (0..100351) para o
//   endereço padded correspondente antes de apresentar addr_w:
//     neuron_idx = ptr / 784
//     pixel_idx  = ptr % 784
//     addr_w     = {neuron_idx[6:0], pixel_idx[9:0]}
//   Essa conversão requer divisão inteira — ver reg_bank.v para a
//   implementação via lookup ou contador duplo.
//
// Separação temporal escrita/leitura:
//   O ARM executa todos os STORE_WEIGHTS antes de escrever START.
//   A FSM só lê durante CALC_HIDDEN, que começa após START.
//   Não há sobreposição temporal — sem risco de hazard.
//
// Uso de recursos (estimativa, igual à rom_pesos anterior):
//   131.072 × 16 bits = 2.097.152 bits ÷ 10.240 bits/M10K ≈ 205 blocos M10K
//   (já contabilizado nos ~52% de M10K reportados pelo Quartus)
//
// Referência de porta:
//   Porta de leitura  → controlada por fsm_ctrl (addr_r, data_out)
//   Porta de escrita  → controlada por reg_bank  (we_w, addr_w, data_w)
// =============================================================================

module ram_pesos (
    input  wire        clk,

    // ── Porta de leitura (FSM — CALC_HIDDEN) ─────────────────────────────────
    input  wire [16:0] addr_r,      // {neuron_idx[6:0], pixel_idx[9:0]}
    output reg  [15:0] data_out,    // W[neurônio][pixel] em Q4.12

    // ── Porta de escrita (ARM — STORE_WEIGHTS) ────────────────────────────────
    input  wire        we_w,        // write enable: 1 = escreve neste ciclo
    input  wire [16:0] addr_w,      // endereço padded gerado pelo reg_bank
    input  wire [15:0] data_w       // peso Q4.12 enviado pelo ARM
);

    // ── Declaração da memória ─────────────────────────────────────────────────
    // Profundidade 2^17 = 131.072 — mesma da rom_pesos anterior.
    // A conversão para RAM não altera o uso de M10K: o Quartus já alocava
    // esses blocos como ROM; agora os mesmos blocos passam a ter write enable.
    reg [15:0] mem [131071:0];

    // ── Porta de escrita — síncrona ───────────────────────────────────────────
    // Ativa apenas quando we_w=1 (gerado pelo reg_bank ao receber STORE_WEIGHTS).
    // addr_w já vem no formato padded correto — reg_bank faz a conversão.
    always @(posedge clk) begin
        if (we_w)
            mem[addr_w] <= data_w;
    end

    // ── Porta de leitura — síncrona, latência 1 ciclo ─────────────────────────
    // Idêntica à rom_pesos original — a FSM não precisa de nenhuma adaptação.
    // Ciclo N:   addr_r apresentado
    // Ciclo N+1: data_out estável com W[neurônio][pixel]
    always @(posedge clk) begin
        data_out <= mem[addr_r];
    end

endmodule
