// =============================================================================
// Módulo: rom_bias.v
// Função: Armazena os 128 biases (b) da camada oculta da ELM.
//         Um bias por neurônio, 16 bits cada (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço direto (7 bits):
//   addr = neuron_idx[6:0]  →  0..127
//
// Comparação com rom_pesos:
//   rom_pesos: endereço composto de 17 bits (neurônio + pixel)
//   rom_bias:  endereço direto de 7 bits (só neurônio)
//   → muito mais simples, pois cada neurônio tem apenas 1 bias
//
// Referência: test_spec_memories.md — Módulo 3 (TC-BIAS-01 a TC-BIAS-03)
//
// NOTA SOBRE O ARQUIVO MIF:
//   Quando os pesos forem fornecidos, substitua a inicialização sintética por:
//   initial $readmemh("bias.mif", mem);
// =============================================================================

module rom_bias (
    input            clk,
    input      [6:0] addr,       // neuron_idx: 0..127
    output reg [15:0] data_out   // bias b[neurônio] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]  → cada posição guarda 16 bits (bias em formato Q4.12)
    // [127:0] → 128 posições, uma por neurônio da camada oculta
    //
    // Esta é a menor ROM do projeto — só 128 × 16 = 2048 bits no total.
    // -------------------------------------------------------------------------
    reg [15:0] mem [127:0];

    // -------------------------------------------------------------------------
    // Inicialização sintética
    //
    // Padrão verificável: mem[addr] = addr[15:0]
    // Como addr tem só 7 bits (0..127), os valores vão de 0x0000 a 0x007F.
    //
    // Substitua por: initial $readmemh("bias.mif", mem);
    // quando os pesos reais forem fornecidos.
    // -------------------------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1)
            mem[i] = i[15:0];
    end

    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono
    //
    // Idêntica à rom_pesos: latência de 1 ciclo de clock.
    // A diferença está apenas no endereço (7 bits vs 17 bits)
    // e na profundidade da memória (128 vs 100.352 posições).
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
