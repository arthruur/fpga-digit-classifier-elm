// =============================================================================
// mac_unit.v — Unidade MAC (Multiplica-Acumula) em Ponto Fixo Q4.12
// =============================================================================
// Projeto  : elm_accel — Co-processador ELM em FPGA
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
// Marco    : 1 / Fase 2
//
// Descrição:
//   Realiza a operação acc = acc + (a * b) em ponto fixo Q4.12 (16 bits,
//   signed). O produto intermediário tem 32 bits; o resultado é truncado para
//   16 bits extraindo os bits [27:12], o que preserva o ponto binário Q4.12.
//   Saturação por clamp é aplicada antes da escrita no acumulador.
//
// Formato Q4.12:
//   bit 15        : sinal
//   bits [14:12]  : parte inteira (3 bits)
//   bits [11:0]   : parte fracionária (12 bits)
//   Resolução     : 1/4096 ≈ 0.000244
//   Intervalo     : [-8.0, +7.999755...]
//
// Operação de truncamento:
//   produto_completo[31:0] = a_signed * b_signed   (32 bits, Q8.24)
//   resultado_q4_12        = produto_completo[27:12] (16 bits, Q4.12)
//   Os bits [11:0] são descartados (truncamento para baixo).
//   Os bits [31:28] são usados para detecção de overflow.
//
// Interface:
//   clk      : clock do sistema
//   rst_n    : reset síncrono ativo-baixo
//   mac_en   : habilita acumulação (acc <= acc + produto) quando '1'
//   mac_clr  : limpa acumulador e acc_out sincronamente quando '1'
//              (mac_clr tem prioridade sobre mac_en)
//   a        : operando A em Q4.12 (16 bits signed)
//   b        : operando B em Q4.12 (16 bits signed)
//   acc_out  : resultado acumulado em Q4.12 (16 bits signed)
//   overflow : flag pulsada por 1 ciclo quando saturação ocorre
//
// Comportamento do clear:
//   Síncrono — na borda de subida do clock com mac_clr='1':
//     acc_internal <= 0
//     acc_out      <= 0
//   acc_out mantém o último valor acumulado até novo mac_en ou mac_clr.
//
// Saturação:
//   Se overflow positivo  → acc_out = 16'h7FFF (+7.999755 em Q4.12)
//   Se overflow negativo  → acc_out = 16'h8000 (-8.0 em Q4.12)
//   Detecção: os 4 bits superiores do acumulador 32-bit [31:28] devem ser
//   todos 0 (positivo sem overflow) ou todos 1 (negativo sem overflow).
// =============================================================================

module mac_unit (
    input  wire        clk,        // Clock do sistema
    input  wire        rst_n,      // Reset síncrono ativo-baixo
    input  wire        mac_en,     // Habilita acumulação
    input  wire        mac_clr,    // Limpa acumulador (prioridade sobre mac_en)
    input  wire [15:0] a,          // Operando A — Q4.12 signed
    input  wire [15:0] b,          // Operando B — Q4.12 signed
    output reg  [15:0] acc_out,    // Acumulador de saída — Q4.12 signed
    output reg         overflow    // Flag de saturação (1 ciclo de pulso)
);

    // -------------------------------------------------------------------------
    // Sinais internos
    // -------------------------------------------------------------------------

    // Produto completo: 16 bits × 16 bits = 32 bits (Q8.24)
    wire signed [31:0] product;

    // Acumulador interno de 32 bits para evitar perda de precisão durante
    // múltiplas acumulações antes do truncamento final
    reg signed [31:0] acc_internal;

    // Resultado truncado para Q4.12 (bits [27:12] do produto)
    wire signed [15:0] product_q4_12;

    // Próximo valor do acumulador interno após soma
    wire signed [31:0] acc_next;

    // Bits de guarda para detecção de overflow no acumulador interno
    // Bits [31:28] devem ser 4'b0000 (sem overflow positivo)
    //                     ou 4'b1111 (sem overflow negativo)
    wire overflow_pos;
    wire overflow_neg;
    wire overflow_detected;

    // -------------------------------------------------------------------------
    // Multiplicação signed 16×16 → 32 bits
    // -------------------------------------------------------------------------
    assign product = $signed(a) * $signed(b);
    
    // Verifica se a própria multiplicação estourou o formato Q4.12.
    // Para caber em Q4.12, os bits descartados [31:27] precisam ser
    // todos '0' (se positivo) ou todos '1' (se negativo).

    wire prod_ovf_pos = (product[31:27] != 5'b00000) && !product[31];
    wire prod_ovf_neg = (product[31:27] != 5'b11111) && product[31];

    assign product_q4_12 = prod_ovf_pos ? 16'h7FFF : prod_ovf_neg ? 16'h8000 : product[27:12];

    // -------------------------------------------------------------------------
    // Acumulação: soma produto truncado ao acumulador interno
    // -------------------------------------------------------------------------
    assign acc_next = acc_internal + {{16{product_q4_12[15]}}, product_q4_12};

    // -------------------------------------------------------------------------
    // Detecção de overflow GERAL (na multiplicação OU na acumulação).
    // -------------------------------------------------------------------------
    assign overflow_pos = prod_ovf_pos | ((acc_next[31:28] != 4'b0000) && !acc_next[31]);
    assign overflow_neg = prod_ovf_neg | ((acc_next[31:28] != 4'b1111) && acc_next[31]);
    assign overflow_detected = overflow_pos | overflow_neg;

    // -------------------------------------------------------------------------
    // Lógica sequencial — registrador do acumulador
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            // Reset síncrono: limpa tudo
            acc_internal <= 32'b0;
            acc_out      <= 16'b0;
            overflow     <= 1'b0;

        end else if (mac_clr) begin
            // Clear síncrono com prioridade máxima: zera acumulador e saída
            acc_internal <= 32'b0;
            acc_out      <= 16'b0;
            overflow     <= 1'b0;

        end else if (mac_en) begin
            // Acumulação com saturação por clamp
            overflow <= overflow_detected;

            if (overflow_pos) begin
                // Saturação positiva
                acc_internal <= 32'h00007FFF;
                acc_out      <= 16'h7FFF;

            end else if (overflow_neg) begin
                // Saturação negativa
                acc_internal <= 32'hFFFF8000;
                acc_out      <= 16'h8000;

            end else begin
                // Acumulação normal sem overflow
                acc_internal <= acc_next;
                acc_out      <= acc_next[15:0];
            end

        end else begin
            // mac_en = 0 e mac_clr = 0: mantém estado atual
            overflow <= 1'b0;
        end
    end

endmodule
