// =============================================================================
// ram_beta.v — Pesos β da camada de saída da ELM
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Histórico:
//   v1 (rom_beta.v) — ROM inicializada via $readmemh; sem porta de escrita.
//   v2 (ram_beta.v) — Convertida para RAM com porta de escrita via MMIO
//                     (STORE_BETA, offset 0x1C), permitindo trocar o modelo
//                     em runtime sem resintetizar o bitstream.
//
// Motivação:
//   β é o único parâmetro que varia entre variantes de modelo ELM treinadas
//   com diferentes configurações. Com ram_beta, o ARM pode carregar um novo
//   conjunto de pesos β sem alterar W_in ou b — zero resíntese.
//
// Capacidade:
//   10 classes × 128 neurônios = 1.280 pesos de 16 bits (Q4.12).
//   Uso de M10K: 1.280 × 16 bits = 20.480 bits ≈ 2 blocos M10K
//   (já contabilizados na síntese anterior com rom_beta).
//
// Endereçamento (LEITURA — porta da FSM):
//   addr_r = {class_idx[3:0], hidden_idx[6:0]}  →  11 bits
//   Layout: β[classe][neurônio] — ordem class-major.
//   β[0][0]   → addr 0
//   β[0][127] → addr 127
//   β[1][0]   → addr 128
//   β[9][127] → addr 1279  (endereço máximo)
//
// Endereçamento (ESCRITA — porta do ARM):
//   addr_w = ponteiro linear b_ptr [10:0] mantido em reg_bank.v (0..1279).
//   Ordem esperada pelo ARM:
//     β[0][0], β[0][1], ..., β[0][127],   (classe 0, 128 writes)
//     β[1][0], β[1][1], ..., β[1][127],   (classe 1, 128 writes)
//     ...
//     β[9][0], ..., β[9][127]             (classe 9, 128 writes)
//   Total: 1.280 writes para carregar todos os pesos β.
//   Saturação em 1279: writes adicionais são ignorados pelo reg_bank.
//
// Separação temporal escrita/leitura:
//   O ARM executa todos os STORE_BETA antes de escrever START.
//   A FSM só lê durante CALC_OUTPUT. Sem sobreposição — sem hazard.
//
// Referência de porta:
//   Porta de leitura  → controlada por fsm_ctrl (addr_r, data_out)
//   Porta de escrita  → controlada por reg_bank  (we_w, addr_w, data_w)
// =============================================================================

module ram_beta (
    input  wire        clk,

    // ── Porta de leitura (FSM — CALC_OUTPUT) ─────────────────────────────────
    input  wire [10:0] addr_r,      // {class_idx[3:0], hidden_idx[6:0]}
    output reg  [15:0] data_out,    // β[classe][neurônio] em Q4.12

    // ── Porta de escrita (ARM — STORE_BETA) ───────────────────────────────────
    input  wire        we_w,        // write enable: 1 = escreve neste ciclo
    input  wire [10:0] addr_w,      // ponteiro linear vindo do reg_bank (0..1279)
    input  wire [15:0] data_w       // peso β Q4.12 enviado pelo ARM
);

    // ── Declaração da memória ─────────────────────────────────────────────────
    // 1280 posições — idêntico à rom_beta anterior.
    // A conversão para RAM não altera o uso de M10K.
    reg [15:0] mem [1279:0];

    // ── Porta de escrita — síncrona ───────────────────────────────────────────
    always @(posedge clk) begin
        if (we_w)
            mem[addr_w] <= data_w;
    end

    // ── Porta de leitura — síncrona, latência 1 ciclo ─────────────────────────
    // Idêntica à rom_beta original — a FSM não precisa de nenhuma adaptação.
    always @(posedge clk) begin
        data_out <= mem[addr_r];
    end

endmodule
