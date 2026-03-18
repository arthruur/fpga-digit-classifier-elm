// =============================================================================
// Módulo: rom_beta.v
// Função: Armazena os pesos β da camada de saída da ELM.
//         10 classes × 128 neurônios ocultos = 1.280 pesos de 16 bits (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço composto (11 bits):
//   addr = {class_idx[3:0], hidden_idx[6:0]}
//
// Comparação com rom_pesos:
//   rom_pesos: 128 neurônios × 784 pixels  → 17 bits de endereço
//   rom_beta:  10 classes   × 128 neurônios →  11 bits de endereço
//   → mesma lógica de endereço composto, escala muito menor
//
// Cálculo do endereço:
//   endereço = class_idx × 128 + hidden_idx
//   β[0][0]   → {4'd0, 7'd0}   = 0
//   β[0][127] → {4'd0, 7'd127} = 127
//   β[1][0]   → {4'd1, 7'd0}   = 128
//   β[9][127] → {4'd9, 7'd127} = 1279  (endereço máximo)
//
// Referência: test_spec_memories.md — Módulo 4 (TC-BETA-01 a TC-BETA-04)
//
// NOTA SOBRE O ARQUIVO MIF:
//   Quando os pesos forem fornecidos, substitua a inicialização sintética por:
//   initial $readmemh("beta.mif", mem);
// =============================================================================

module rom_beta (
    input             clk,
    input      [10:0] addr,       // {class_idx[3:0], hidden_idx[6:0]}
    output reg [15:0] data_out    // peso β[classe][neurônio] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]   → cada posição guarda 16 bits (peso β em formato Q4.12)
    // [1279:0] → 1.280 posições = 10 classes × 128 neurônios ocultos
    //
    // Por que 11 bits de endereço?
    //   2¹⁰ = 1024  → insuficiente para 1280 posições
    //   2¹¹ = 2048  → suficiente ✓
    //   (512 posições ficam inacessíveis — desperdício normal em hardware)
    // -------------------------------------------------------------------------
    reg [15:0] mem [1279:0];

    // -------------------------------------------------------------------------
    // Inicialização sintética
    //
    // Padrão verificável: mem[addr] = addr[15:0]
    // Como addr tem 11 bits (0..1279), os valores vão de 0x0000 a 0x04FF.
    //
    // Substitua por: initial $readmemh("beta.mif", mem);
    // quando os pesos reais forem fornecidos.
    // -------------------------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < 1280; i = i + 1)
            mem[i] = i[15:0];
    end

    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono
    //
    // Exatamente o mesmo padrão de todas as ROMs do projeto.
    // Latência de 1 ciclo de clock.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
