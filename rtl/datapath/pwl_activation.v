// =============================================================================
// pwl_activation.v
// Aproximação Piecewise Linear do tanh(x) em Q4.12
//
// Baseado em: Liu et al., "Cost effective Tanh activation function circuits
// based on fast piecewise linear logic", Microelectronics Journal, 2023.
//
// Representação: Q4.12 signed — 16 bits
//   Bit 15    : sinal
//   Bits 14:12: parte inteira (3 bits) — faixa [-8, 7]
//   Bits 11:0 : parte fracionária (12 bits) — resolução 1/4096 ≈ 0.000244
//
// Arquitetura:
//   - Lógica combinacional PURA (zero registradores, zero BRAMs)
//   - Latência: 0 ciclos de clock (resultado disponível no mesmo ciclo)
//   - Explora propriedade de função ímpar: implementa x>=0 e espelha para x<0
//   - 5 segmentos no semiplano positivo, seleção por MUX combinacional
//   - Slopes implementados como shift-and-add (sem multiplicadores)
//   - MAE teórico ≈ 0.0049 (vs. tanh exato em float64)
//
// Faixa de entrada: Q4.12 signed, útil em [-4.0, +4.0]
//   Saturação: x ≤ -4.0 → y = -1.0 | x ≥ +4.0 → y = +1.0
//
// Constantes Q4.12 importantes:
//   +1.0  = 16'h1000 = 4096
//   -1.0  = 16'hF000 = -4096 (complemento de 2)
//   +4.0  = 16'h4000 = 16384
//   -4.0  = 16'hC000 = -16384
//   +2.0  = 16'h2000 = 8192
//   -2.0  = 16'hE000 = -8192
//   +0.25 = 16'h0400 = 1024
//   +0.5  = 16'h0800 = 2048
//   +1.5  = 16'h1800 = 6144
// =============================================================================

module pwl_activation (
    input  wire signed [15:0] x_in,   // Entrada em Q4.12
    output wire signed [15:0] y_out   // Saída  em Q4.12, range [-1.0, +1.0]
);

// ---------------------------------------------------------------------------
// CONSTANTES Q4.12
// ---------------------------------------------------------------------------
localparam signed [15:0] POS_ONE    =  16'h1000;  //  +1.0
localparam signed [15:0] NEG_ONE    =  16'hF000;  //  -1.0
localparam signed [15:0] POS_4      =  16'h4000;  //  +4.0
localparam signed [15:0] NEG_4      =  16'hC000;  //  -4.0
localparam signed [15:0] POS_2      =  16'h2000;  //  +2.0
localparam signed [15:0] NEG_2      =  16'hE000;  //  -2.0
localparam signed [15:0] POS_1      =  16'h1000;  //  +1.0  (reuso)
localparam signed [15:0] POS_1P5    =  16'h1800;  //  +1.5
localparam signed [15:0] POS_0P5    =  16'h0800;  //  +0.5
localparam signed [15:0] POS_0P25   =  16'h0400;  //  +0.25

// Interceptos dos segmentos positivos em Q4.12 (da Eq. 6 do artigo):
// Seg2: +0.02935791015625 ≈ round(0.02936 * 4096) = 120
localparam signed [15:0] B2 = 16'h0078;  // +0.02936  (120/4096)
// Seg3: +0.15625 = 640/4096
localparam signed [15:0] B3 = 16'h0280;  // +0.15625  (640/4096)
// Seg4: +0.453125 = 1856/4096
localparam signed [15:0] B4 = 16'h0780; // +0.453125 (1856/4096)
// Seg5: +0.716796875 = 2935/4096
localparam signed [15:0] B5 = 16'h0BF4; // +0.71680  (2935/4096)

// ---------------------------------------------------------------------------
// PASSO 1: Trabalhar com o valor absoluto de x
//   tanh é função ímpar: tanh(-x) = -tanh(x)
//   Implementamos apenas x >= 0 e espelhamos ao final
// ---------------------------------------------------------------------------
wire x_neg;
wire signed [15:0] x_abs;

assign x_neg = x_in[15];                           // 1 se x < 0

// Proteção contra o limite extremo assémitrico do complemento de 2
assign x_abs = (x_in == 16'h8000) ? 16'h7FFF : 
               (x_neg ? (-x_in) : x_in);           // |x| em Q4.12
// ---------------------------------------------------------------------------
// PASSO 2: Calcular os slopes para cada segmento via shifts
//
// Seg 1: slope = 1        → x_abs (sem shift)
// Seg 2: slope = 1 - 1/8  → x_abs - (x_abs >>> 3)
// Seg 3: slope = 1/2+1/8  → (x_abs >>> 1) + (x_abs >>> 3)
// Seg 4: slope = 1/4+1/16 → (x_abs >>> 2) + (x_abs >>> 4)
// Seg 5: slope = 1/8+1/512→ (x_abs >>> 3) + (x_abs >>> 9)
//
// Todos os shifts são aritméticos (propagam sinal), mas como x_abs >= 0,
// equivalem a shifts lógicos. Usamos >>> para garantia de síntese correta.
// ---------------------------------------------------------------------------
wire signed [15:0] x_shr1, x_shr2, x_shr3, x_shr4, x_shr9;

assign x_shr1 = x_abs >>> 1;   // x/2
assign x_shr2 = x_abs >>> 2;   // x/4
assign x_shr3 = x_abs >>> 3;   // x/8
assign x_shr4 = x_abs >>> 4;   // x/16
assign x_shr9 = x_abs >>> 9;   // x/512

// Termos de slope para cada segmento (todos em Q4.12)
wire signed [15:0] slope1_term;  // slope=1
wire signed [15:0] slope2_term;  // slope=7/8
wire signed [15:0] slope3_term;  // slope=5/8
wire signed [15:0] slope4_term;  // slope=5/16
wire signed [15:0] slope5_term;  // slope≈1/8

assign slope1_term = x_abs;                     // 1 * |x|
assign slope2_term = x_abs - x_shr3;            // (1 - 1/8)*|x|
assign slope3_term = x_shr1 + x_shr3;           // (1/2 + 1/8)*|x|
assign slope4_term = x_shr2 + x_shr4;           // (1/4 + 1/16)*|x|
assign slope5_term = x_shr3 + x_shr9;           // (1/8 + 1/512)*|x|

// ---------------------------------------------------------------------------
// PASSO 3: Calcular saída de cada segmento (slope*x + intercept)
//   Saturação implícita: seg0 → NEG_ONE, seg6 → POS_ONE
// ---------------------------------------------------------------------------
wire signed [15:0] y_seg1, y_seg2, y_seg3, y_seg4, y_seg5;

assign y_seg1 = slope1_term;              // y = |x|                (0 ≤ |x| < 0.25)
assign y_seg2 = slope2_term + B2;         // y = 7/8*|x| + 0.02936 (0.25 ≤ |x| < 0.5)
assign y_seg3 = slope3_term + B3;         // y = 5/8*|x| + 0.15625 (0.5 ≤ |x| < 1.0)
assign y_seg4 = slope4_term + B4;         // y = 5/16*|x|+ 0.45313 (1.0 ≤ |x| < 1.5)
assign y_seg5 = slope5_term + B5;         // y ≈ 1/8*|x| + 0.71680 (1.5 ≤ |x| < 2.0)

// ---------------------------------------------------------------------------
// PASSO 4: Seleção do segmento por MUX combinacional
//   Comparação apenas com valores positivos (trabalhamos em |x|)
//   Breakpoints em Q4.12: 0.25=1024, 0.5=2048, 1.0=4096, 1.5=6144, 2.0=8192
//
//   NOTA: faixa original do artigo é [0,2). Para FPGA com Q4.12 e pesos ELM,
//   estendemos a saturação para |x| >= 2.0 → y = +1.0 (aproximação válida
//   pois tanh(2.0) = 0.9640 ≈ 1.0 para a maioria das aplicações).
//   Se maior precisão for necessária para |x| ∈ [2,4), substituir por
//   saturação suave adicional.
// ---------------------------------------------------------------------------
wire signed [15:0] y_pos;  // Saída para x >= 0

assign y_pos =
    (x_abs >= POS_4)    ? POS_ONE   :   // |x| >= 4.0 → saturação +1
    (x_abs >= POS_2)    ? POS_ONE   :   // |x| >= 2.0 → aproximação ≈ +1
    (x_abs >= POS_1P5)  ? y_seg5    :   // 1.5 ≤ |x| < 2.0
    (x_abs >= POS_1)    ? y_seg4    :   // 1.0 ≤ |x| < 1.5
    (x_abs >= POS_0P5)  ? y_seg3    :   // 0.5 ≤ |x| < 1.0
    (x_abs >= POS_0P25) ? y_seg2    :   // 0.25 ≤ |x| < 0.5
                          y_seg1;       // 0 ≤ |x| < 0.25

// ---------------------------------------------------------------------------
// PASSO 5: Aplicar propriedade de função ímpar
//   Se x era negativo → y = -y_pos
//   Se x era zero ou positivo → y = y_pos
// ---------------------------------------------------------------------------
assign y_out = x_neg ? (-y_pos) : y_pos;

endmodule