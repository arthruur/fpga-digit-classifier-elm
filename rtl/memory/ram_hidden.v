// =============================================================================
// Módulo: ram_hidden.v
// Função: Armazena os 128 valores h da camada oculta da ELM.
//         h[i] = tanh(W_in[i]·x + b[i]) — resultado de cada neurônio oculto.
// Tipo: BRAM síncrona de porta única, 128 posições x 16 bits.
//
// Escrita: pela FSM ao fim do cálculo de cada neurônio (estado CALC_HIDDEN)
// Leitura: pela FSM durante o cálculo da camada de saída (estado CALC_OUTPUT)
//
// Comparação com os outros módulos:
//   ram_img:    RAM 784×8  bits — armazena pixels      (entrada da rede)
//   ram_hidden: RAM 128×16 bits — armazena ativações   (saída da camada oculta)
//   rom_bias:   ROM 128×16 bits — mesma forma, mas ROM (valores fixos de treino)
//
// Referência: test_spec_memories.md — Módulo 5 (TC-HID-01 a TC-HID-06)
// =============================================================================

module ram_hidden (
    input             clk,        // clock
    input             we,         // write enable: 1 = escreve, 0 = só lê
    input       [6:0] addr,       // neuron_idx: 0..127
    input      [15:0] data_in,    // valor h[i] a escrever em Q4.12 (16 bits)
    output reg [15:0] data_out    // valor h[i] lido em Q4.12
);

    // -------------------------------------------------------------------------
    // Declaração da memória
    //
    // [15:0]  → cada posição guarda 16 bits (valor h em formato Q4.12)
    // [127:0] → 128 posições, uma por neurônio da camada oculta
    //
    // Idêntica em estrutura à rom_bias — mesma profundidade e largura.
    // A diferença é funcional: esta é RAM (reescrita a cada inferência),
    // enquanto rom_bias é ROM (valores fixos gravados em síntese).
    // -------------------------------------------------------------------------
    reg [15:0] mem [127:0];

    // -------------------------------------------------------------------------
    // Lógica de leitura e escrita — bloco síncrono
    //
    // Idêntico à ram_img, apenas com dados de 16 bits em vez de 8.
    //
    // Escrita condicional:
    //   we=1 → grava data_in (resultado h[i] calculado pela MAC+PWL)
    //   we=0 → memória preservada
    //
    // Leitura registrada:
    //   Acontece todo ciclo. Latência de 1 ciclo de clock.
    //   A FSM usa esse dado durante CALC_OUTPUT para multiplicar β·h.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (we) begin
            mem[addr] <= data_in;
        end

        data_out <= mem[addr];
    end

endmodule
