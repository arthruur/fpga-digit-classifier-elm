// =============================================================================
// Módulo: rom_pesos.v
// Função: Armazena os pesos W_in da camada oculta da ELM.
//         128 neurônios × 784 pixels = 100.352 pesos de 16 bits (Q4.12).
// Tipo: ROM síncrona de porta única — sem escrita em runtime.
//
// Endereço composto (17 bits):
//   addr = {neuron_idx[6:0], pixel_idx[9:0]}
//
// Referência: test_spec_memories.md — Módulo 2 (TC-WGT-01 a TC-WGT-06)
//
// NOTA SOBRE O ARQUIVO MIF:
//   Quando o professor fornecer os pesos treinados, gere o arquivo w_in.mif
//   com o script gen_mif.py e substitua a inicialização sintética abaixo
//   pelo comando: $readmemh("w_in.mif", mem);
// =============================================================================

module rom_pesos (
    input             clk,
    input      [16:0] addr,       // {neuron_idx[6:0], pixel_idx[9:0]}
    output reg [15:0] data_out    // peso W[neuron][pixel] em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]      → cada posição guarda 16 bits (peso em formato Q4.12)
    // [100351:0]  → 100.352 posições = 128 neurônios × 784 pixels
    //
    // O Quartus infere isso como BRAM automaticamente — o mesmo padrão
    // da ram_img, só que muito maior e sem lógica de escrita.
    // -------------------------------------------------------------------------
    reg [15:0] mem [100351:0];

    // -------------------------------------------------------------------------
    // Inicialização com padrão sintético
    //
    // Como os pesos reais ainda não foram fornecidos pelo professor,
    // inicializamos com um padrão matemático verificável:
    //
    //   mem[addr] = addr[15:0]  (valor = índice truncado para 16 bits)
    //
    // Isso permite ao testbench calcular o valor esperado de qualquer
    // posição sem precisar do arquivo MIF.
    //
    // Quando os pesos reais chegarem, substitua este bloco por:
    //   initial $readmemh("w_in.mif", mem);
    // -------------------------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < 100352; i = i + 1)
            mem[i] = i[15:0];
    end

    // -------------------------------------------------------------------------
    // Lógica de leitura — bloco síncrono
    //
    // Idêntica à ram_img: a cada borda de subida do clock, o valor em
    // mem[addr] é capturado em data_out.
    //
    // Latência: 1 ciclo de clock.
    // Ciclo N:   apresenta addr
    // Ciclo N+1: data_out tem o valor de mem[addr]
    //
    // Não há lógica de escrita — ROM não tem we.
    // O conteúdo é definido apenas pela inicialização acima.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        data_out <= mem[addr];
    end

endmodule
