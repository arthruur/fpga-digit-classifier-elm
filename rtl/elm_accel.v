// =============================================================================
// elm_accel.v — Top-level do co-processador ELM
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1 · Marco 1 / Fase 5
//
// Instancia e interconecta todos os submódulos:
//   reg_bank, fsm_ctrl, mac_unit, pwl_activation, argmax_block,
//   ram_img, rom_pesos, rom_bias, rom_beta, ram_hidden
//
// Fluxo de dados — camada oculta (CALC_HIDDEN):
//   mac_a = pixel_q412  (pixel << 4, range [0x0000, 0x0FF0])
//   mac_b = weight_data (W_in[i][j] em Q4.12)
//   ... após 784 acumulações:
//   mac_a = bias_data   (b[i] em Q4.12)    ← ciclo de bias (bias_cycle=1)
//   mac_b = 16'h1000    (+1.0 em Q4.12)
//   h[i]  = pwl_out     (PWL combinacional sobre acc_out)
//   → escrito em ram_hidden[i] quando we_hidden=1
//
// Fluxo de dados — camada de saída (CALC_OUTPUT):
//   mac_a = h_rdata     (h[i] lido de ram_hidden)
//   mac_b = beta_data   (β[i][k] em Q4.12, layout: addr = i*10 + k)
//   ... após 128 acumulações:
//   y[k]  = acc_out     (linear, sem ativação)
//   → capturado em y_buf[k] quando mac_clr=1 e we_hidden=0
//
// Fluxo de dados — argmax (ARGMAX):
//   y_buf[0..9] apresentados um por ciclo ao argmax_block
//   argmax_done pulsa quando os 10 scores foram comparados
//   max_idx → result_out → registrador RESULT
//
// Interface MMIO (via reg_bank):
//   0x00 CTRL   W  bit[0]=start, bit[1]=reset
//   0x04 STATUS R  bits[1:0]=estado, bits[5:2]=pred
//   0x08 IMG    W  bits[9:0]=pixel_addr, bits[17:10]=pixel_data
//   0x0C RESULT R  bits[3:0]=pred (0..9)
//   0x10 CYCLES R  ciclos de clock desde START até DONE
// =============================================================================

module elm_accel #(
    // Passados para ram_img e fsm_ctrl no modo demo standalone.
    // Defaults = 0/"" preservam o comportamento original (escrita via MMIO).
    parameter INIT_FILE     = "",   // arquivo HEX de pixels pré-carregados
    parameter PRELOADED_IMG = 0     // 1 = pula LOAD_IMG
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    input  wire        write_en,
    input  wire        read_en,
    input  wire [31:0] data_in,
    output wire [31:0] data_out
);

// ============================================================================
// Seção 1 — Sinais internos: reg_bank
// ============================================================================

wire        start_pulse;        // pulso de 1 ciclo: inicia inferência
wire        reset_cmd;          // nível: aborta FSM
wire  [9:0] pixel_addr;         // endereço do pixel escrito pelo ARM
wire  [7:0] pixel_data;         // valor do pixel (0..255)
wire        we_img_rb;          // write enable da ram_img (vindo do ARM)

// Sinais de status lidos pela FSM e repassados ao reg_bank
wire  [1:0] status_wire;
wire  [3:0] result_wire;
wire [31:0] cycles_wire;

// ============================================================================
// Seção 2 — Sinais internos: fsm_ctrl
// ============================================================================

wire        we_img_fsm;         // (gerado pela FSM, não usado no we — ver Seção 5)
wire  [9:0] addr_img;           // endereço de leitura da ram_img (CALC_HIDDEN)
wire        we_hidden;          // write enable da ram_hidden
wire  [6:0] addr_hidden;        // endereço da ram_hidden
wire [16:0] addr_w;             // endereço da rom_pesos
wire  [6:0] addr_bias;          // endereço da rom_bias
wire [10:0] addr_beta;          // endereço da rom_beta (layout: i*10 + k)
wire        mac_en;             // habilita acumulação
wire        mac_clr;            // limpa acumulador
wire        bias_cycle;         // 1 no ciclo do bias (mac_a←bias, mac_b←1.0)
wire        h_capture;          // coincide com we_hidden — marcado para clareza
wire        argmax_en;          // habilita comparação no argmax_block
wire  [1:0] status_out_fsm;
wire  [3:0] result_out_fsm;
wire [31:0] cycles_out_fsm;
wire        done_out_fsm;
wire        calc_output_active; // 1 durante CALC_OUTPUT
wire  [3:0] k_out;              // índice de classe atual (0..9)

// ============================================================================
// Seção 3 — Sinais internos: memórias
// ============================================================================

wire  [7:0] img_data;           // pixel lido de ram_img
wire [15:0] weight_data;        // peso W_in[i][j] lido de rom_pesos
wire [15:0] bias_data;          // bias b[i] lido de rom_bias
wire [15:0] beta_data;          // peso β[i][k] lido de rom_beta
wire [15:0] h_rdata;            // ativação h[i] lida de ram_hidden

// ============================================================================
// Seção 4 — Sinais internos: datapath
// ============================================================================

wire [15:0] acc_out;            // saída Q4.12 do acumulador MAC
wire        overflow;           // flag de saturação da MAC
wire [15:0] pwl_out;            // saída Q4.12 da PWL combinacional
wire  [3:0] max_idx;            // índice do maior score (argmax_block)
wire        argmax_done;        // pulso: todos os 10 scores comparados

// ============================================================================
// Seção 5 — Conversão pixel → Q4.12
//
// pixel/255 ≈ pixel/256 = pixel << 4
//   pixel=0   → 0x0000 (0.000 em Q4.12)
//   pixel=128 → 0x0800 (0.500 em Q4.12)
//   pixel=255 → 0x0FF0 (0.996 em Q4.12)
//
// O erro de 0.004 em relação a /255 é irrelevante: com z já saturando
// na maioria dos neurônios, o argmax final é insensível a esse desvio.
// ============================================================================

wire [15:0] pixel_q412 = {4'b0000, img_data, 4'b0000};

// ============================================================================
// Seção 6 — Mux de entradas da MAC
//
// Prioridade (bias_cycle tem prioridade sobre calc_output_active):
//
//   bias_cycle=1:
//     mac_a ← bias_data     (b[i] em Q4.12)
//     mac_b ← 16'h1000      (+1.0 em Q4.12)
//     Efeito: acc += b[i] × 1.0  →  argumento completo da PWL
//
//   calc_output_active=1, bias_cycle=0:
//     mac_a ← h_rdata       (h[i] de ram_hidden)
//     mac_b ← beta_data     (β[i][k] de rom_beta)
//     Efeito: acc += β[i][k] × h[i]
//
//   default (CALC_HIDDEN, ciclo normal):
//     mac_a ← pixel_q412    (x[j] convertido)
//     mac_b ← weight_data   (W_in[i][j] de rom_pesos)
//     Efeito: acc += W_in[i][j] × x[j]
// ============================================================================

wire [15:0] mac_a_in = bias_cycle         ? bias_data   :
                       calc_output_active ? h_rdata     :
                       pixel_q412;

wire [15:0] mac_b_in = bias_cycle         ? 16'h1000    :
                       calc_output_active ? beta_data   :
                       weight_data;

// ============================================================================
// Seção 7 — Endereço da ram_img (mux escrita/leitura)
//
// A ram_img é single-port: escrita e leitura usam o mesmo barramento.
//   Escrita (we_img_rb=1): ARM controla o endereço via pixel_addr
//   Leitura (we_img_rb=0): FSM controla o endereço via addr_img
//
// Como as duas fases não se sobrepõem no tempo (ARM escreve antes do
// START, FSM lê durante CALC_HIDDEN), o mux simples funciona corretamente.
// ============================================================================

wire [9:0] ram_img_addr = we_img_rb ? pixel_addr : addr_img;

// ============================================================================
// Seção 8 — Buffer de scores y[0..9]
//
// Captura acc_out ao final de cada classe durante CALC_OUTPUT.
// Condição: mac_clr=1 AND we_hidden=0
//   - mac_clr=1 sempre marca o fim de um cálculo (hidden ou output)
//   - we_hidden=0 distingue CALC_OUTPUT de CALC_HIDDEN
//     (em CALC_HIDDEN, we_hidden=1 junto com mac_clr=1)
//
// Timing: ao posedge onde mac_clr=1, acc_out ainda reflete y[k]
// (o clear só efetiva APÓS este posedge no mac_unit). ✓
// ============================================================================

reg signed [15:0] y_buf [0:9];
wire y_capture = mac_clr && !we_hidden;

integer idx;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (idx = 0; idx < 10; idx = idx + 1)
            y_buf[idx] <= 16'b0;
    end else if (y_capture) begin
        y_buf[k_out] <= acc_out;
    end
end

// ============================================================================
// Seção 9 — Controle do argmax_block
//
// argmax_start_pulse: detecta a borda de subida de argmax_en
//   → usado para resetar argmax_block e reiniciar o contador argmax_k
//
// argmax_enable: habilita comparação apenas APÓS o ciclo de start
//   → garante que o start reseta o bloco ANTES da primeira comparação
//
// argmax_k: conta 0..9 durante as 10 comparações
//   → endereça y_buf para apresentar um score por ciclo
//
// Diagrama de tempo (10 ciclos a partir da entrada em ARGMAX):
//   Ciclo 1: start=1, enable=0. Bloco reseta. argmax_k=0.
//   Ciclo 2: start=0, enable=1. y_buf[0] → bloco. argmax_k→1.
//   ...
//   Ciclo 11: enable=1. y_buf[9] → bloco. done pulsa.
// ============================================================================

reg argmax_en_prev;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) argmax_en_prev <= 1'b0;
    else        argmax_en_prev <= argmax_en;
end

wire argmax_start_pulse  = argmax_en && !argmax_en_prev;
wire argmax_enable       = argmax_en && !argmax_start_pulse;

reg [3:0] argmax_k;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        argmax_k <= 4'd0;
    else if (argmax_start_pulse)
        argmax_k <= 4'd0;
    else if (argmax_enable)
        argmax_k <= argmax_k + 4'd1;
end

// ============================================================================
// Seção 10 — Instâncias dos submódulos
// ============================================================================

// ---------- reg_bank ---------------------------------------------------------
reg_bank u_reg_bank (
    .clk        (clk),
    .rst_n      (rst_n),
    .addr       (addr),
    .write_en   (write_en),
    .read_en    (read_en),
    .data_in    (data_in),
    .status_in  (status_out_fsm),
    .pred_in    (result_out_fsm),
    .cycles_in  (cycles_out_fsm),
    .data_out   (data_out),
    .start_out  (start_pulse),
    .reset_out  (reset_cmd),
    .pixel_addr (pixel_addr),
    .pixel_data (pixel_data),
    .we_img_out (we_img_rb)
);

// ---------- fsm_ctrl ---------------------------------------------------------
fsm_ctrl #(
    .N_PIXELS      (784),
    .N_NEURONS     (128),
    .N_CLASSES     (10),
    .PRELOADED_IMG (PRELOADED_IMG)
) u_fsm (
    .clk                (clk),
    .rst_n              (rst_n),
    .start              (start_pulse),
    .reset              (reset_cmd),
    .we_img             (we_img_rb),
    .overflow           (overflow),
    .argmax_done        (argmax_done),
    .max_idx            (max_idx),
    .we_img_fsm         (we_img_fsm),
    .addr_img           (addr_img),
    .we_hidden          (we_hidden),
    .addr_hidden        (addr_hidden),
    .addr_w             (addr_w),
    .addr_bias          (addr_bias),
    .addr_beta          (addr_beta),
    .mac_en             (mac_en),
    .mac_clr            (mac_clr),
    .bias_cycle         (bias_cycle),
    .h_capture          (h_capture),
    .argmax_en          (argmax_en),
    .status_out         (status_out_fsm),
    .result_out         (result_out_fsm),
    .cycles_out         (cycles_out_fsm),
    .done_out           (done_out_fsm),
    .calc_output_active (calc_output_active),
    .k_out              (k_out)
);

// ---------- ram_img ----------------------------------------------------------
ram_img #(
    .INIT_FILE (INIT_FILE)
) u_ram_img (
    .clk      (clk),
    .we       (we_img_rb),
    .addr     (ram_img_addr),
    .data_in  (pixel_data),
    .data_out (img_data)
);

// ---------- rom_pesos --------------------------------------------------------
rom_pesos u_rom_pesos (
    .clk      (clk),
    .addr     (addr_w),
    .data_out (weight_data)
);

// ---------- rom_bias ---------------------------------------------------------
rom_bias u_rom_bias (
    .clk      (clk),
    .addr     (addr_bias),
    .data_out (bias_data)
);

// ---------- rom_beta ---------------------------------------------------------
rom_beta u_rom_beta (
    .clk      (clk),
    .addr     (addr_beta),
    .data_out (beta_data)
);

// ---------- ram_hidden -------------------------------------------------------
ram_hidden u_ram_hidden (
    .clk      (clk),
    .we       (we_hidden),
    .addr     (addr_hidden),
    .data_in  (pwl_out),
    .data_out (h_rdata)
);

// ---------- mac_unit ---------------------------------------------------------
mac_unit u_mac (
    .clk      (clk),
    .rst_n    (rst_n),
    .mac_en   (mac_en),
    .mac_clr  (mac_clr),
    .a        (mac_a_in),
    .b        (mac_b_in),
    .acc_out  (acc_out),
    .overflow (overflow)
);

// ---------- pwl_activation ---------------------------------------------------
// Combinacional pura: saída disponível no mesmo ciclo que acc_out
pwl_activation u_pwl (
    .x_in  (acc_out),
    .y_out (pwl_out)
);

// ---------- argmax_block -----------------------------------------------------
argmax_block u_argmax (
    .clk     (clk),
    .rst_n   (rst_n),
    .start   (argmax_start_pulse),
    .enable  (argmax_enable),
    .y_in    (y_buf[argmax_k]),
    .k_in    (argmax_k),
    .max_idx (max_idx),
    .max_val (),            // não usado no top-level
    .done    (argmax_done)
);

endmodule