// =============================================================================
// Módulo: ram_img.v
// Função: Armazena os 784 pixels (28x28) da imagem a ser classificada.
// Tipo: BRAM síncrona de porta única, 784 posições x 8 bits.
//
// Referência: test_spec_memories.md — Módulo 1 (TC-IMG-01 a TC-IMG-06)
// =============================================================================

module ram_img (
    input            clk,       // clock
    input            we,        // write enable: 1 = escreve, 0 = só lê
    input      [9:0] addr,      // endereço: 0 a 783 (10 bits)
    input      [7:0] data_in,   // pixel a escrever (0..255)
    output reg [7:0] data_out   // pixel lido
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // Sintaxe: reg [largura_do_dado - 1 : 0] nome [quantidade_de_posicoes - 1 : 0]
    //
    // [7:0]  → cada posição guarda 8 bits (1 byte = 1 pixel em escala de cinza)
    // [783:0] → 784 posições no total (pixels de 0 a 783)
    //
    // O Quartus reconhece esse padrão e sintetiza automaticamente como BRAM,
    // em vez de usar flip-flops. Isso economiza muito recurso na FPGA.
    // -------------------------------------------------------------------------
    reg [7:0] mem [783:0];

    // -------------------------------------------------------------------------
    // Lógica de leitura e escrita — bloco síncrono
    //
    // "always @(posedge clk)" significa: execute isso a cada borda de subida
    // do clock. É o mesmo padrão que você usou nos flip-flops da calculadora.
    //
    // IMPORTANTE — latência de leitura:
    // BRAMs síncronas retornam o dado no ciclo SEGUINTE ao endereço.
    // Ciclo N:   apresenta addr
    // Ciclo N+1: data_out tem o valor de mem[addr]
    //
    // Isso é diferente de uma RAM assíncrona, onde a leitura seria imediata.
    // O testbench já está escrito levando essa latência em conta.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin

        // ---------------------------------------------------------------------
        // Escrita condicional
        //
        // Se we=1: grava data_in na posição addr da memória.
        // Se we=0: não faz nada com a memória (dado preservado).
        //
        // Isso é exatamente o write enable que discutimos — sem ele,
        // qualquer borda de clock sobrescreveria a memória.
        // ---------------------------------------------------------------------
        if (we) begin
            mem[addr] <= data_in;
        end

        // ---------------------------------------------------------------------
        // Leitura registrada (síncrona)
        //
        // A leitura acontece SEMPRE, independente de we.
        // O dado em mem[addr] é capturado no registrador data_out.
        // Por isso data_out é declarado como "output reg" e não "output wire".
        //
        // Pergunta para fixar: se we=1 e lemos o mesmo addr que estamos
        // escrevendo, qual valor aparece em data_out?
        // Resposta: o valor ANTERIOR (antes da escrita deste ciclo),
        // pois a escrita e a leitura ocorrem na mesma borda — isso se chama
        // comportamento "read-before-write" e é o padrão de BRAM do Quartus.
        // ---------------------------------------------------------------------
        data_out <= mem[addr];

    end

endmodule
