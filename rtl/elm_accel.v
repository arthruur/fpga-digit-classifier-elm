module elm_accel (
    // Sinais de Sistema
    input wire clk,
    input wire rst_n,          // Reset assíncrono, ativo em baixo

    // Barramento de Controle/Dados (Simplificado)
    input wire [31:0] addr,    // Endereço do registrador
    input wire write_en,       // Sinal de escrita (Write Enable)
    input wire read_en,        // Sinal de leitura (Read Enable)
    input wire [31:0] data_in, // Dados vindos do ARM
    output reg [31:0] data_out // Dados enviados ao ARM
);

endmodule