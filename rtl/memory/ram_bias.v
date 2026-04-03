// =============================================================================
// ram_bias.v — Biases b da camada oculta da ELM
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Histórico:
//   v1 (rom_bias.v) — ROM inicializada via $readmemh; sem porta de escrita.
//   v2 (ram_bias.v) — Convertida para RAM de porta dupla:
//                     escrita pelo ARM via MMIO (STORE_BIAS),
//                     leitura pela FSM durante CALC_HIDDEN.
//
// Capacidade:
//   128 biases de 16 bits (Q4.12) — um por neurônio da camada oculta.
//   Uso de M10K: 128 × 16 bits = 2.048 bits — cabe em menos de 1 bloco M10K.
//
// Endereçamento (LEITURA — porta da FSM):
//   addr_r = neuron_idx[6:0]  →  0..127
//   Direto — sem padding necessário (128 = 2^7 exato).
//
// Endereçamento (ESCRITA — porta do ARM):
//   addr_w = ponteiro auto-incremental mantido em reg_bank.v
//   Ponteiro avança 0→1→...→127 a cada write em BIAS_DATA (0x18).
//   Ordem esperada: b[0], b[1], ..., b[127] — 128 writes no total.
//   Saturação em 127: writes além desse limite são ignorados pelo reg_bank.
//
// Separação temporal escrita/leitura:
//   O ARM executa todos os STORE_BIAS antes de escrever START.
//   A FSM só lê durante CALC_HIDDEN. Sem sobreposição — sem hazard.
//
// Nota sobre os pesos:
//   Os arquivos b_q.txt (bias) são idênticos para as variantes de modelo
//   com diferentes funções de ativação. Apenas beta_q.txt varia entre elas.
//   Portanto, uma vez carregados os biases, eles são válidos para qualquer
//   variante sem necessidade de reescrita.
//
// Referência de porta:
//   Porta de leitura  → controlada por fsm_ctrl (addr_r, data_out)
//   Porta de escrita  → controlada por reg_bank  (we_w, addr_w, data_w)
// =============================================================================

module ram_bias (
    input  wire       clk,

    // ── Porta de leitura (FSM — CALC_HIDDEN) ─────────────────────────────────
    input  wire [6:0] addr_r,      // neuron_idx: 0..127
    output reg [15:0] data_out,    // b[neurônio] em Q4.12

    // ── Porta de escrita (ARM — STORE_BIAS) ───────────────────────────────────
    input  wire       we_w,        // write enable: 1 = escreve neste ciclo
    input  wire [6:0] addr_w,      // ponteiro vindo do reg_bank (0..127)
    input  wire [15:0] data_w      // bias Q4.12 enviado pelo ARM
);

    // ── Declaração da memória ─────────────────────────────────────────────────
    reg [15:0] mem [127:0];

    // ── Porta de escrita — síncrona ───────────────────────────────────────────
    always @(posedge clk) begin
        if (we_w)
            mem[addr_w] <= data_w;
    end

    // ── Porta de leitura — síncrona, latência 1 ciclo ─────────────────────────
    // Idêntica à rom_bias original — a FSM não precisa de nenhuma adaptação.
    always @(posedge clk) begin
        data_out <= mem[addr_r];
    end

endmodule
