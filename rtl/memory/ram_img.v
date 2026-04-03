// =============================================================================
// Módulo: ram_img.v
// Função: Armazena os 784 pixels (28x28) da imagem a ser classificada.
// Tipo: BRAM síncrona de porta única, 784 posições x 8 bits.
//
// Referência: test_spec_memories.md — Módulo 1 (TC-IMG-01 a TC-IMG-06)
// =============================================================================

module ram_img #(
    // Arquivo HEX para pré-carregar a imagem no bitstream.
    // Deixe "" (vazio) para o comportamento original (escrita via MMIO).
    // No modo demo, passe o caminho do img_test.hex gerado pelo golden model.
    parameter INIT_FILE = "img_test.hex"
)(
    input            clk,       // clock
    input            we,        // write enable: 1 = escreve, 0 = só lê
    input      [9:0] addr,      // endereço: 0 a 783 (10 bits)
    input      [7:0] data_in,   // pixel a escrever (0..255)
    output reg [7:0] data_out   // pixel lido
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    // -------------------------------------------------------------------------
    reg [7:0] mem [783:0];

    // -------------------------------------------------------------------------
    // Inicialização opcional com arquivo HEX (modo demo / standalone).
    // O Quartus usa $readmemh no bloco initial para inicializar M10K com
    // o conteúdo do arquivo — equivalente ao parâmetro INIT_FILE de altsyncram.
    // Quando INIT_FILE = "", o initial não é executado e a RAM começa em X
    // (comportamento original: pixels chegam via MMIO antes do START).
    // -------------------------------------------------------------------------
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

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