// =============================================================================
// Módulo: rom_beta.v
// Função: Armazena os pesos β da camada de saída da ELM.
//         10 classes × 128 neurônios ocultos = 1.280 pesos de 16 bits (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço composto (11 bits):
//   addr = {class_idx[3:0], hidden_idx[6:0]}
//
//   Cálculo: addr = class_idx * 128 + hidden_idx
//   β[0][0]   → {4'd0, 7'd0}   = 0
//   β[0][127] → {4'd0, 7'd127} = 127
//   β[1][0]   → {4'd1, 7'd0}   = 128
//   β[9][127] → {4'd9, 7'd127} = 1279  (endereço máximo)
//
// Nota sobre profundidade:
//   2^11 = 2048, mas apenas 1280 posições são usadas.
//   O endereço máximo válido é 1279 < 2047, portanto sem out-of-bounds.
//   mem é declarado com 1280 entradas para ser preciso e poupar recursos.
//
// Arquivo de inicialização: beta.hex
//   Formato: $readmemh — um valor hex por linha, sem cabeçalho.
//   Gerado por: scripts/gen_hex.py a partir de beta_q.txt
//
// Referência: test_spec_memories.md — Módulo 4 (TC-BETA-01 a TC-BETA-04)
// =============================================================================

module rom_beta (
    input             clk,
    input      [10:0] addr,       // {class_idx[3:0], hidden_idx[6:0]}
    output reg [15:0] data_out    // peso β[classe][neurônio] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]   → cada posição guarda 16 bits (peso β em Q4.12)
    // [1279:0] → 1280 posições = 10 classes × 128 neurônios
    // -------------------------------------------------------------------------
    reg [15:0] mem [1279:0];

    // -------------------------------------------------------------------------
    // Inicialização com os pesos β reais (Q4.12)
    //
    // beta.hex: 1280 linhas.
    //   linha 0    → β[0][0]   (classe 0, neurônio oculto 0)
    //   linha 127  → β[0][127]
    //   linha 128  → β[1][0]
    //   linha 1279 → β[9][127]
    // -------------------------------------------------------------------------
    initial $readmemh("beta.hex", mem);

    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono, latência de 1 ciclo.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
