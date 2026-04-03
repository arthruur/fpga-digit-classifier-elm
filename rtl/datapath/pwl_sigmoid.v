// =============================================================================
// pwl_sigmoid.v
// Aproximação Piecewise Linear da Função Logística Sigmóide σ(x)
//
// Baseado em: OLIVEIRA, Janaína da Glória Moreira de. "Uma arquitetura
// reconfigurável de Rede Neural Artificial utilizando FPGA". Dissertação
// (Mestrado em Engenharia Elétrica) – Universidade Federal de Itajubá,
// Itajubá, 2017. Apêndice A.
//
// Representação: Q4.12 signed — 16 bits
//   Bit 15    : sinal
//   Bits 14:12: parte inteira (3 bits) — faixa [-8, 7]
//   Bits 11:0 : parte fracionária (12 bits) — resolução 1/4096 ≈ 0.000244
//
// Arquitetura:
//   - Lógica combinacional PURA (zero registradores, zero BRAMs)
//   - Latência: 0 ciclos de clock (resultado disponível no mesmo ciclo)
//   - Explora simetria da sigmóide: σ(-x) = 1 - σ(x)
//     (diferente do tanh: a sigmóide NÃO é função ímpar — é simétrica em 0.5)
//   - 4 segmentos no semiplano positivo, seleção por MUX combinacional
//   - Slopes implementados como shifts (sem multiplicadores)
//   - Saída em [0.0, 1.0] representada em Q4.12
//
// Segmentos PWL para x >= 0 (Apêndice A, Oliveira 2017):
//   Seg 1: y = 0.25x    + 0.5,        0.0  ≤ x < 1.0
//   Seg 2: y = 0.125x   + 0.625,      1.0  ≤ x < 2.5
//   Seg 3: y = 0.03125x + 0.859375,   2.5  ≤ x < 4.5
//   Seg 4: y = 1.0,                   x    ≥ 4.5
//
// Para x < 0: σ(-x) = 1.0 - σ(x)  → y_out = 1.0 - y_pos
//
// Constantes Q4.12 importantes:
//   +1.0      = 16'h1000 = 4096
//    0.5      = 16'h0800 = 2048
//    0.625    = 16'h0A00 = 2560
//    0.859375 = 16'h0DC0 = 3520
//   BP 1.0    = 16'h1000 = 4096
//   BP 2.5    = 16'h2800 = 10240
//   BP 4.5    = 16'h4800 = 18432
// =============================================================================

module pwl_sigmoid (
    input  wire signed [15:0] x_in,   // Entrada em Q4.12 (signed)
    output wire signed [15:0] y_out   // Saída  em Q4.12, range [0.0, +1.0]
);

// ---------------------------------------------------------------------------
// CONSTANTES Q4.12
// ---------------------------------------------------------------------------

// Interceptos dos segmentos positivos
localparam signed [15:0] B1 = 16'h0800;  // 0.5        = 2048/4096
localparam signed [15:0] B2 = 16'h0A00;  // 0.625      = 2560/4096
localparam signed [15:0] B3 = 16'h0DC0;  // 0.859375   = 3520/4096

// Saturação superior e valor 1.0
localparam signed [15:0] POS_ONE = 16'h1000;  // +1.0 = 4096

// Breakpoints (positivos) em Q4.12
localparam signed [15:0] BP1 = 16'h1000;  // 1.0  = 4096
localparam signed [15:0] BP2 = 16'h2800;  // 2.5  = 10240
localparam signed [15:0] BP3 = 16'h4800;  // 4.5  = 18432

// ---------------------------------------------------------------------------
// PASSO 1: Trabalhar com o valor absoluto de x
//   σ(-x) = 1 - σ(x) → implementamos apenas x >= 0 e invertemos ao final
// ---------------------------------------------------------------------------
wire x_neg;
wire signed [15:0] x_abs;

assign x_neg = x_in[15];  // 1 se x < 0

// Proteção contra o extremo assimétrico do complemento de 2 (0x8000)
assign x_abs = (x_in == 16'h8000) ? 16'h7FFF :
               (x_neg             ? (-x_in)   : x_in);

// ---------------------------------------------------------------------------
// PASSO 2: Calcular os slopes para cada segmento via shifts
//
//   Seg 1: slope = 0.25      → x_abs >> 2
//   Seg 2: slope = 0.125     → x_abs >> 3
//   Seg 3: slope = 0.03125   → x_abs >> 5
//
// Shifts aritméticos (>>>), mas x_abs >= 0, então equivalem a shifts lógicos.
// ---------------------------------------------------------------------------
wire signed [15:0] x_shr2, x_shr3, x_shr5;

assign x_shr2 = x_abs >>> 2;   // x / 4
assign x_shr3 = x_abs >>> 3;   // x / 8
assign x_shr5 = x_abs >>> 5;   // x / 32

// ---------------------------------------------------------------------------
// PASSO 3: Calcular saída de cada segmento (slope * x + intercept)
// ---------------------------------------------------------------------------
wire signed [15:0] y_seg1, y_seg2, y_seg3;

assign y_seg1 = x_shr2 + B1;   // 0.25x    + 0.5        (0.0 ≤ |x| < 1.0)
assign y_seg2 = x_shr3 + B2;   // 0.125x   + 0.625      (1.0 ≤ |x| < 2.5)
assign y_seg3 = x_shr5 + B3;   // 0.03125x + 0.859375   (2.5 ≤ |x| < 4.5)

// ---------------------------------------------------------------------------
// PASSO 4: Seleção do segmento por MUX combinacional (para x >= 0)
// ---------------------------------------------------------------------------
wire signed [15:0] y_pos;

assign y_pos =
    (x_abs >= BP3) ? POS_ONE :   // x >= 4.5  → saturação em 1.0
    (x_abs >= BP2) ? y_seg3  :   // 2.5 ≤ x < 4.5
    (x_abs >= BP1) ? y_seg2  :   // 1.0 ≤ x < 2.5
                     y_seg1;     // 0.0 ≤ x < 1.0

// ---------------------------------------------------------------------------
// PASSO 5: Aplicar simetria σ(-x) = 1 - σ(x)
//   Se x era negativo → y = 1.0 - y_pos
//   Se x era zero ou positivo → y = y_pos
//
//   NOTA: diferente do tanh (função ímpar: y = -y_pos),
//   a sigmóide é simétrica em relação a 0.5, não ao zero.
// ---------------------------------------------------------------------------
assign y_out = x_neg ? (POS_ONE - y_pos) : y_pos;

endmodule
