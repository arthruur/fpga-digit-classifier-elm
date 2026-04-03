// =============================================================================
// elm_accel.v — Top-level do co-processador ELM
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1 · Marco 1 / Fase 5
//
// Histórico de alterações:
//   v1 — ROM inicializadas via $readmemh (pesos no bitstream).
//   v2 — rom_pesos e rom_bias convertidas para RAM; STORE_WEIGHTS (0x14)
//        e STORE_BIAS (0x18) adicionados ao reg_bank.
//   v3 — rom_beta convertida para RAM; STORE_BETA (0x1C) adicionado.
//        ISA completa: STORE_IMG, STORE_WEIGHTS, STORE_BIAS, STORE_BETA,
//        START, STATUS. Modelo ELM totalmente configurável em runtime.
//
// Instancia e interconecta todos os submódulos:
//   reg_bank, fsm_ctrl, mac_unit, pwl_activation, argmax_block,
//   ram_img, ram_pesos, ram_beta, ram_bias, ram_hidden
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
//   0x00 CTRL         W  bit[0]=start, bit[1]=reset
//   0x04 STATUS       R  bits[1:0]=estado, bits[5:2]=pred
//   0x08 IMG          W  bits[9:0]=pixel_addr, bits[17:10]=pixel_data
//   0x0C RESULT       R  bits[3:0]=pred (0..9)
//   0x10 CYCLES       R  ciclos de clock desde START até DONE
//   0x14 WEIGHTS_DATA W  bits[15:0]=peso Q4.12  (ponteiro auto-incremental)
//   0x18 BIAS_DATA    W  bits[15:0]=bias Q4.12  (ponteiro auto-incremental)
//   0x1C BETA_DATA    W  bits[15:0]=peso β Q4.12 (ponteiro auto-incremental)
// =============================================================================

module elm_accel #(
    parameter INIT_FILE     = "",
    parameter PRELOADED_IMG = 0
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

wire        start_pulse;
wire        reset_cmd;
wire  [9:0] pixel_addr;
wire  [7:0] pixel_data;
wire        we_img_rb;

// STORE_WEIGHTS
wire        we_pesos_rb;
wire [16:0] waddr_pesos_rb;
wire [15:0] wdata_pesos_rb;

// STORE_BIAS
wire        we_bias_rb;
wire  [6:0] waddr_bias_rb;
wire [15:0] wdata_bias_rb;

// STORE_BETA
wire        we_beta_rb;
wire [10:0] waddr_beta_rb;
wire [15:0] wdata_beta_rb;

// ============================================================================
// Seção 2 — Sinais internos: fsm_ctrl
// ============================================================================

wire        we_img_fsm;
wire  [9:0] addr_img;
wire        we_hidden;
wire  [6:0] addr_hidden;
wire [16:0] addr_w;
wire  [6:0] addr_bias;
wire [10:0] addr_beta;
wire        mac_en;
wire        mac_clr;
wire        bias_cycle;
wire        h_capture;
wire        argmax_en;
wire  [1:0] status_out_fsm;
wire  [3:0] result_out_fsm;
wire [31:0] cycles_out_fsm;
wire        done_out_fsm;
wire        calc_output_active;
wire  [3:0] k_out;

// ============================================================================
// Seção 3 — Sinais internos: memórias
// ============================================================================

wire  [7:0] img_data;
wire [15:0] weight_data;
wire [15:0] bias_data;
wire [15:0] beta_data;
wire [15:0] h_rdata;

// ============================================================================
// Seção 4 — Sinais internos: datapath
// ============================================================================

wire [15:0] acc_out;
wire        overflow;
wire [15:0] pwl_out;
wire  [3:0] max_idx;
wire        argmax_done;

// ============================================================================
// Seção 5 — Conversão pixel → Q4.12
// ============================================================================

wire [15:0] pixel_q412 = {4'b0000, img_data, 4'b0000};

// ============================================================================
// Seção 6 — Mux de entradas da MAC
// ============================================================================

wire [15:0] mac_a_in = bias_cycle         ? bias_data   :
                       calc_output_active ? h_rdata     :
                       pixel_q412;

wire [15:0] mac_b_in = bias_cycle         ? 16'h1000    :
                       calc_output_active ? beta_data   :
                       weight_data;

// ============================================================================
// Seção 7 — Endereço da ram_img (mux escrita/leitura)
// ============================================================================

wire [9:0] ram_img_addr = we_img_rb ? pixel_addr : addr_img;

// ============================================================================
// Seção 8 — Buffer de scores y[0..9]
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
// ============================================================================

reg argmax_en_prev;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) argmax_en_prev <= 1'b0;
    else        argmax_en_prev <= argmax_en;
end

wire argmax_start_pulse = argmax_en && !argmax_en_prev;
wire argmax_enable      = argmax_en && !argmax_start_pulse;

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
    .clk          (clk),
    .rst_n        (rst_n),
    .addr         (addr),
    .write_en     (write_en),
    .read_en      (read_en),
    .data_in      (data_in),
    .status_in    (status_out_fsm),
    .pred_in      (result_out_fsm),
    .cycles_in    (cycles_out_fsm),
    .data_out     (data_out),
    .start_out    (start_pulse),
    .reset_out    (reset_cmd),
    .pixel_addr   (pixel_addr),
    .pixel_data   (pixel_data),
    .we_img_out   (we_img_rb),
    .we_pesos_out (we_pesos_rb),
    .waddr_pesos  (waddr_pesos_rb),
    .wdata_pesos  (wdata_pesos_rb),
    .we_bias_out  (we_bias_rb),
    .waddr_bias   (waddr_bias_rb),
    .wdata_bias   (wdata_bias_rb),
    .we_beta_out  (we_beta_rb),
    .waddr_beta   (waddr_beta_rb),
    .wdata_beta   (wdata_beta_rb)
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

// ---------- ram_pesos --------------------------------------------------------
// Porta de leitura controlada pela FSM (addr_w).
// Porta de escrita controlada pelo reg_bank (STORE_WEIGHTS — 0x14).
// Separação temporal garantida: ARM escreve antes de START.
ram_pesos u_ram_pesos (
    .clk      (clk),
    .addr_r   (addr_w),
    .data_out (weight_data),
    .we_w     (we_pesos_rb),
    .addr_w   (waddr_pesos_rb),
    .data_w   (wdata_pesos_rb)
);

// ---------- ram_bias ---------------------------------------------------------
// Porta de leitura controlada pela FSM (addr_bias).
// Porta de escrita controlada pelo reg_bank (STORE_BIAS — 0x18).
// Nota: b_q.txt é idêntico entre variantes de modelo; re-envio não necessário.
ram_bias u_ram_bias (
    .clk      (clk),
    .addr_r   (addr_bias),
    .data_out (bias_data),
    .we_w     (we_bias_rb),
    .addr_w   (waddr_bias_rb),
    .data_w   (wdata_bias_rb)
);

// ---------- ram_beta ---------------------------------------------------------
// Antes: rom_beta (ROM no bitstream).
// Agora: ram_beta — STORE_BETA (0x1C) permite trocar o modelo em runtime.
// β é o único parâmetro que varia entre variantes ELM treinadas.
// Porta de leitura controlada pela FSM (addr_beta).
// Porta de escrita controlada pelo reg_bank (STORE_BETA — 0x1C).
ram_beta u_ram_beta (
    .clk      (clk),
    .addr_r   (addr_beta),
    .data_out (beta_data),
    .we_w     (we_beta_rb),
    .addr_w   (waddr_beta_rb),
    .data_w   (wdata_beta_rb)
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
    .max_val (),
    .done    (argmax_done)
);

endmodule
