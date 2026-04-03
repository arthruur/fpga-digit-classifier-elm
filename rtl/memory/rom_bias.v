// =============================================================================
// Módulo: rom_bias.v
// Função: Armazena os 128 biases (b) da camada oculta da ELM.
//         Um bias por neurônio, 16 bits cada (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço direto (7 bits):
//   addr = neuron_idx[6:0]  →  0..127
//
// Arquivo de inicialização: bias.hex
//   Formato: $readmemh — um valor hex por linha, sem cabeçalho.
//   Gerado por: scripts/gen_hex.py a partir de b_q.txt
//
// Referência: test_spec_memories.md — Módulo 3 (TC-BIAS-01 a TC-BIAS-03)
// =============================================================================

module rom_bias (
    input            clk,
    input      [6:0] addr,        // neuron_idx: 0..127
    output reg [15:0] data_out    // bias b[neurônio] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]  → cada posição guarda 16 bits (bias em formato Q4.12)
    // [127:0] → 128 posições, uma por neurônio da camada oculta
    // -------------------------------------------------------------------------
    reg [15:0] mem [127:0];

    // -------------------------------------------------------------------------
    // Inicialização com os biases reais (Q4.12)
    //
    // bias.hex: 128 linhas, uma por neurônio.
    //   linha 0   → b[0]   = bias do neurônio 0
    //   linha 127 → b[127] = bias do neurônio 127
    // -------------------------------------------------------------------------
	`ifndef SYNTHESIS
		 initial $readmemh("bias.hex", mem);
	`endif
    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono, latência de 1 ciclo.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
