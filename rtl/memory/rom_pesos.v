// =============================================================================
// Módulo: rom_pesos.v
// Função: Armazena os pesos W_in da camada oculta da ELM.
//         128 neurônios × 784 pixels = 100.352 pesos de 16 bits (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço composto (17 bits):
//   addr = {neuron_idx[6:0], pixel_idx[9:0]}
//
//   Cálculo: addr = neuron_idx * 1024 + pixel_idx
//
//   ATENÇÃO — layout padded:
//     A ROM tem profundidade 2^17 = 131.072 entradas.
//     Para cada neurônio n, as posições n*1024+784 a n*1024+1023 ficam
//     sem uso (zero). Isso torna o endereçamento uma simples concatenação
//     de bits, evitando multiplicador na FSM.
//
//     Comparação de profundidade:
//       Linear  (n*784+p): 100.352 entradas — menor, mas exige multiplicador
//       Padded  (n*1024+p):131.072 entradas — maior, mas endereço = concat ✓
//
// Arquivo de inicialização: w_in.hex
//   Formato: $readmemh — um valor hex por linha, sem cabeçalho.
//   Gerado por: scripts/gen_hex.py a partir de W_in_q.txt
//
// Referência: test_spec_memories.md — Módulo 2 (TC-WGT-01 a TC-WGT-06)
// =============================================================================

module rom_pesos (
    input             clk,
    input      [16:0] addr,       // {neuron_idx[6:0], pixel_idx[9:0]}
    output reg [15:0] data_out    // peso W[neuron][pixel] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória — profundidade PADDED = 2^17 = 131.072
    //
    // Por que 131.072 e não 100.352?
    //   Com addr = {7 bits, 10 bits}, o valor máximo de addr é:
    //     {7'd127, 10'd783} = 127*1024 + 783 = 130.831
    //   100.352 entradas seriam insuficientes (130.831 > 100.351 → out-of-bounds).
    //
    //   Usando 2^17 = 131.072, todos os endereços válidos são cobertos.
    //   O custo extra: (131.072 - 100.352) × 16 bits ≈ 26 Kbytes desperdiçados.
    // -------------------------------------------------------------------------
    reg [15:0] mem [131071:0];

    // -------------------------------------------------------------------------
    // Inicialização com os pesos reais (Q4.12)
    //
    // w_in.hex é um arquivo de texto com uma linha por posição:
    //   linha 0       → W[0][0]   (neurônio 0, pixel 0)
    //   linha 783     → W[0][783] (neurônio 0, pixel 783)
    //   linhas 784–1023 → zeros (posições de padding)
    //   linha 1024    → W[1][0]   (neurônio 1, pixel 0)
    //   ...
    //   linha 130.048 → W[127][0]
    //   linha 130.831 → W[127][783]
    //
    // O $readmemh preenche apenas as linhas presentes no arquivo.
    // Posições não preenchidas ficam como 16'bx em simulação —
    // o arquivo w_in.hex já inclui zeros nas posições de padding.
    // -------------------------------------------------------------------------
    initial $readmemh("w_in.hex", mem);

    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono
    //
    // Latência: 1 ciclo de clock.
    // Ciclo N:   apresenta addr
    // Ciclo N+1: data_out tem o valor de mem[addr]
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
