// =============================================================================
// mac_unit.v — Unidade MAC (Multiplica-Acumula) em Ponto Fixo Q4.12
// =============================================================================
// Projeto  : elm_accel — Co-processador ELM em FPGA
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
// Marco    : 1 / Fase 2
//
// Descrição:
//   Realiza acc = acc + (a * b) em ponto fixo Q4.12 (16 bits, signed).
//   O produto intermediário tem 32 bits; resultado truncado para Q4.12
//   extraindo os bits [27:12] (descarta os 12 bits fracionários inferiores).
//
// Correção aplicada (v2):
//   A detecção de overflow do acumulador foi corrigida de [31:28] para [31:15].
//   Justificativa: acc_internal acumula valores Q4.12 sign-extendidos em 32 bits.
//   Para que acc_next[15:0] seja um Q4.12 válido, os bits [31:15] devem ser
//   todos iguais (extensão de sinal). Verificar apenas [31:28] só detectava
//   overflows acima de 2^28, deixando somar incorretamente valores entre
//   32768 e 268.435.455 sem saturar.
//
// Formato Q4.12:
//   bit 15       : sinal
//   bits [14:12] : parte inteira (3 bits, range 0..7)
//   bits [11:0]  : parte fracionária (12 bits, resolução 1/4096)
//   Intervalo    : [-8.0, +7.999755...]
//
// Interface:
//   clk      — clock do sistema
//   rst_n    — reset síncrono ativo-baixo
//   mac_en   — habilita acumulação (acc <= acc + produto)
//   mac_clr  — limpa acumulador sincronamente (prioridade sobre mac_en)
//   a, b     — operandos Q4.12 signed (16 bits)
//   acc_out  — acumulador de saída Q4.12 (16 bits signed)
//   overflow — flag de 1 ciclo quando saturação ocorre
//
// Saturação:
//   Overflow positivo → acc_out = 16'h7FFF (+7.999...)
//   Overflow negativo → acc_out = 16'h8000 (-8.0)
// =============================================================================

module mac_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mac_en,
    input  wire        mac_clr,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] acc_out,
    output reg         overflow
);

    // ── Sinais internos ───────────────────────────────────────────────────────

    wire signed [31:0] product;        // produto completo Q8.24
    wire signed [15:0] product_q4_12;  // produto truncado para Q4.12
    wire signed [31:0] acc_next;       // próximo valor do acumulador
    reg  signed [31:0] acc_internal;   // acumulador interno 32 bits Q4.12 ext.
    reg  is_saturated;   // Flag para travar o acumulador pós-saturação.


    // ── Multiplicação 16×16 → 32 bits ────────────────────────────────────────
    assign product = $signed(a) * $signed(b);

    // Verificação de overflow DO PRODUTO individual.
    // O produto Q8.24 cabe em Q4.12 somente se os bits [31:27] são extensão
    // de sinal de bit[27]. Para positivo: bits [31:27] = 5'b00000.
    wire prod_ovf_pos = (product[31:27] != 5'b00000) && !product[31];
    wire prod_ovf_neg = (product[31:27] != 5'b11111) &&  product[31];

    // Produto saturado antes da acumulação
    assign product_q4_12 = prod_ovf_pos ? 16'h7FFF :
                           prod_ovf_neg ? 16'h8000 :
                           product[27:12];

    // ── Acumulação: produto Q4.12 sign-extendido somado ao acumulador ────────
    assign acc_next = acc_internal + {{16{product_q4_12[15]}}, product_q4_12};

    // ── Detecção de overflow DO ACUMULADOR ───────────────────────────────────
    // CORREÇÃO: verificar bits [31:15], não [31:28].
    //
    // acc_internal armazena valores Q4.12 extendidos para 32 bits.
    // Para que acc_next[15:0] seja o valor Q4.12 correto, os bits [31:15]
    // devem ser todos iguais ao bit 15 (extensão de sinal válida).
    //
    // Positivo sem overflow: bits [31:15] = 17'b0_0000_0000_0000_0000
    // Negativo sem overflow: bits [31:15] = 17'b1_1111_1111_1111_1111
    //
    // Antes (ERRADO): verificava apenas [31:28] — só detectava overflow
    // acima de 2^28 (~268 mi), deixando valores em [32768, 268M] passarem
    // sem saturação, produzindo acc_out errado (wrap-around silencioso).
    wire acc_ovf_pos = (acc_next[31:15] != 17'b0_0000_0000_0000_0000) && !acc_next[31];
    wire acc_ovf_neg = (acc_next[31:15] != 17'b1_1111_1111_1111_1111) &&  acc_next[31];

    wire overflow_pos = prod_ovf_pos | acc_ovf_pos;
    wire overflow_neg = prod_ovf_neg | acc_ovf_neg;
    wire overflow_det = overflow_pos | overflow_neg;

// ── Lógica sequencial ─────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst_n) begin
            acc_internal <= 32'b0;
            acc_out      <= 16'b0;
            overflow     <= 1'b0;
            is_saturated <= 1'b0; // Limpa a flag no reset

        end else if (mac_clr) begin
            acc_internal <= 32'b0;
            acc_out      <= 16'b0;
            overflow     <= 1'b0;
            is_saturated <= 1'b0; // Limpa a flag no clear

        end else if (mac_en) begin
            
            // Se já saturou antes, congela o estado numérico (estado terminal)
            if (is_saturated) begin
                overflow <= 1'b0; // O pino de overflow é pulso de 1 ciclo, então deve descer
            end else begin
                // Só avalia nova acumulação se não estiver saturado
                overflow <= overflow_det;
                
                if (overflow_pos) begin
                    // Saturação positiva
                    acc_internal <= 32'h00007FFF;
                    acc_out      <= 16'h7FFF;
                    is_saturated <= 1'b1; // Trava o módulo para os próximos ciclos

                end else if (overflow_neg) begin
                    // Saturação negativa
                    acc_internal <= 32'hFFFF8000;
                    acc_out      <= 16'h8000;
                    is_saturated <= 1'b1; // Trava o módulo para os próximos ciclos

                end else begin
                    // Acumulação normal
                    acc_internal <= acc_next;
                    acc_out      <= acc_next[15:0];
                end
            end

        end else begin
            overflow <= 1'b0;
        end
    end

endmodule
