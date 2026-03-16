// =============================================================================
// tb_datapath.v
// Testbench integrado do datapath: PWL + Argmax
//
// O que este testbench valida:
//   1. PWL: verifica que pwl_activation produz h[j] = pwl(z_h[j]) para os
//           128 neurônios da camada oculta, comparando com h_ref.hex
//   2. Argmax: verifica que argmax_block retorna o índice correto para os
//              10 escores y[0..9] de z_output.hex
//   3. Pipeline: verifica que a predição final bate com pred_ref.txt
//
// Dependências (geradas por gen_golden.py, devem estar na mesma pasta):
//   z_hidden.hex  — pré-ativações da camada oculta (128 × Q4.12)
//   h_ref.hex     — referência de h pós-PWL (128 × Q4.12)
//   z_output.hex  — escores da camada de saída (10 × Q4.12)
//   pred_ref.txt  — não lido diretamente (pred hardcoded do script Python)
//
// Nota de arquitetura:
//   A camada de saída y = β·h NÃO tem ativação. Os escores são lineares
//   e podem assumir qualquer valor em Q4.12 (positivo ou negativo).
//   O argmax opera sobre esses escores brutos.
// =============================================================================

`timescale 1ns/1ps
`define SIMULATION

module tb_datapath;

// ---------------------------------------------------------------------------
// PARÂMETROS
// ---------------------------------------------------------------------------
parameter N_HIDDEN  = 128;
parameter N_OUTPUT  = 10;
parameter CLK_HALF  = 5;  // clock de 100 MHz (período 10 ns)

// Predição esperada — DEVE corresponder ao pred impresso por gen_golden.py.
// Após rodar gen_golden.py, atualize este valor com a predição impressa.
// Exemplo: se gen_golden.py imprimir "PREDIÇÃO FINAL: 1", use 4'd1 aqui.
parameter [3:0] EXPECTED_PRED = 4'd1;  // ← atualizar após rodar gen_golden.py

// ---------------------------------------------------------------------------
// CLOCK E RESET
// ---------------------------------------------------------------------------
reg clk, rst_n;
always #CLK_HALF clk = ~clk;

// ---------------------------------------------------------------------------
// MEMÓRIAS DE REFERÊNCIA
// ---------------------------------------------------------------------------
reg signed [15:0] z_hidden_mem [0:N_HIDDEN-1];   // pré-ativações ocultas
reg signed [15:0] h_ref_mem    [0:N_HIDDEN-1];   // h esperado pós-PWL
reg signed [15:0] z_output_mem [0:N_OUTPUT-1];   // escores de saída

// ---------------------------------------------------------------------------
// INSTÂNCIAS DOS MÓDULOS
// ---------------------------------------------------------------------------

// --- PWL Activation ---
reg  signed [15:0] pwl_x_in;
wire signed [15:0] pwl_y_out;

pwl_activation u_pwl (
    .x_in  (pwl_x_in),
    .y_out (pwl_y_out)
);

// --- Argmax Block ---
reg        argmax_start;
reg        argmax_enable;
reg signed [15:0] argmax_y_in;
reg  [3:0] argmax_k_in;
wire [3:0] argmax_max_idx;
wire signed [15:0] argmax_max_val;
wire       argmax_done;

argmax_block u_argmax (
    .clk     (clk),
    .rst_n   (rst_n),
    .start   (argmax_start),
    .enable  (argmax_enable),
    .y_in    (argmax_y_in),
    .k_in    (argmax_k_in),
    .max_idx (argmax_max_idx),
    .max_val (argmax_max_val),
    .done    (argmax_done)
);

// ---------------------------------------------------------------------------
// VARIÁVEIS DE CONTAGEM E RESULTADO
// ---------------------------------------------------------------------------
integer i;
integer pwl_pass, pwl_fail;
integer pwl_diff;
integer pred_result;

// Função para exibir Q4.12 como float
function real q412_to_float;
    input signed [15:0] val;
    q412_to_float = $itor($signed(val)) / 4096.0;
endfunction

// ---------------------------------------------------------------------------
// SEQUÊNCIA PRINCIPAL DE TESTES
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_datapath.vcd");
    $dumpvars(0, tb_datapath);

    // Carregar memórias de referência
    $readmemh("z_hidden.hex", z_hidden_mem);
    $readmemh("h_ref.hex",    h_ref_mem);
    $readmemh("z_output.hex", z_output_mem);

    // Inicialização
    clk           = 0;
    rst_n         = 0;
    argmax_start  = 0;
    argmax_enable = 0;
    argmax_y_in   = 0;
    argmax_k_in   = 0;
    pwl_x_in      = 0;
    pwl_pass      = 0;
    pwl_fail      = 0;

    // Reset
    @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    // ─────────────────────────────────────────────────────────────────────
    // TESTE 1: PWL — verifica h[j] = pwl_tanh(z_h[j]) para 128 neurônios
    // ─────────────────────────────────────────────────────────────────────
    $display("\n=== TESTE 1: Verificação PWL para camada oculta (128 neurônios) ===");

    for (i = 0; i < N_HIDDEN; i = i + 1) begin
        // Alimentar z_hidden[i] na PWL (combinacional — sem clock)
        pwl_x_in = z_hidden_mem[i];
        #2;  // esperar estabilização combinacional

        // Comparar com referência
        pwl_diff = $signed(pwl_y_out) - $signed(h_ref_mem[i]);
        if (pwl_diff < 0) pwl_diff = -pwl_diff;

        if (pwl_diff == 0) begin
            pwl_pass = pwl_pass + 1;
        end
        else begin
            pwl_fail = pwl_fail + 1;
            $display("  [FAIL] Neurônio %0d: z_h=%d (%f)  h_verilog=%d (%f)  h_ref=%d (%f)  diff=%d",
                i,
                $signed(z_hidden_mem[i]), q412_to_float(z_hidden_mem[i]),
                $signed(pwl_y_out),       q412_to_float(pwl_y_out),
                $signed(h_ref_mem[i]),    q412_to_float(h_ref_mem[i]),
                pwl_diff);
        end
    end

    if (pwl_fail == 0)
        $display("  [PASS] Todos os %0d neurônios: h_verilog == h_ref bit a bit", N_HIDDEN);
    else
        $display("  [FAIL] %0d/%0d neurônios com discrepância vs. golden model",
            pwl_fail, N_HIDDEN);

    // Mostrar primeiros 5 neurônios como amostra
    $display("\n  Amostra dos primeiros 5 neurônios:");
    $display("  %-6s  %-10s  %-10s  %-10s  %-6s",
        "j", "z_h (Q4.12)", "z_h (float)", "h (float)", "Status");
    for (i = 0; i < 5; i = i + 1) begin
        pwl_x_in = z_hidden_mem[i]; #2;
        $display("  %-6d  %-10d  %-10.5f  %-10.5f  %s",
            i,
            $signed(z_hidden_mem[i]),
            q412_to_float(z_hidden_mem[i]),
            q412_to_float(pwl_y_out),
            ($signed(pwl_y_out) === $signed(h_ref_mem[i])) ? "OK" : "FAIL");
    end

    @(posedge clk); #1;

    // ─────────────────────────────────────────────────────────────────────
    // TESTE 2: Argmax — verifica predição correta sobre z_output[0..9]
    // ─────────────────────────────────────────────────────────────────────
    $display("\n=== TESTE 2: Argmax sobre escores de saída y[0..9] ===");
    $display("  (Escores são lineares: y = β·h, SEM ativação)");
    $display("\n  Escores carregados:");
    for (i = 0; i < N_OUTPUT; i = i + 1)
        $display("  y[%0d] = %6d  (%8.5f)", i,
            $signed(z_output_mem[i]), q412_to_float(z_output_mem[i]));

    // Pulso de start
    @(posedge clk); #1;
    argmax_start  = 1;
    argmax_enable = 0;
    @(posedge clk); #1;
    argmax_start = 0;

    // Alimentar os 10 escores, 1 por ciclo
    for (i = 0; i < N_OUTPUT; i = i + 1) begin
        @(posedge clk); #1;
        argmax_y_in   = z_output_mem[i];
        argmax_k_in   = i[3:0];
        argmax_enable = 1;
    end

    // Aguardar done
    @(posedge clk); #1;
    argmax_enable = 0;

    // done deve ter sido assertado no último ciclo de enable
    // Aguardar 1 ciclo extra para leitura estável
    @(posedge clk); #1;

    pred_result = argmax_max_idx;

    $display("\n  max_idx  = %0d  (predição do hardware)", pred_result);
    $display("  max_val  = %0d  (%0.5f)", $signed(argmax_max_val),
             q412_to_float(argmax_max_val));
    $display("  Esperado = %0d", EXPECTED_PRED);

    if (pred_result == EXPECTED_PRED)
        $display("  [PASS] pred_hardware == pred_golden (%0d)", EXPECTED_PRED);
    else
        $display("  [FAIL] pred_hardware=%0d != pred_golden=%0d",
            pred_result, EXPECTED_PRED);

    // ─────────────────────────────────────────────────────────────────────
    // TESTE 3: Argmax com empate (dois valores iguais) — robustez
    // Comportamento esperado: retorna o índice MENOR (primeiro encontrado)
    // ─────────────────────────────────────────────────────────────────────
    $display("\n=== TESTE 3: Robustez do Argmax (empate) ===");

    @(posedge clk); #1;
    argmax_start  = 1;
    argmax_enable = 0;
    @(posedge clk); #1;
    argmax_start = 0;

    // Escores com empate em y[3] e y[7] (ambos = 0x1000 = +1.0)
    begin : teste3_scores
        reg signed [15:0] scores [0:9];
        integer j;
        scores[0] = 16'h0100;   // +0.0625
        scores[1] = 16'hFF00;   // -0.25
        scores[2] = 16'h0200;   // +0.125
        scores[3] = 16'h1000;   // +1.0  ← primeiro máximo
        scores[4] = 16'hF000;   // -1.0
        scores[5] = 16'h0400;   // +0.25
        scores[6] = 16'h0800;   // +0.5
        scores[7] = 16'h1000;   // +1.0  ← empate
        scores[8] = 16'h0300;   // +0.1875
        scores[9] = 16'h0600;   // +0.375

        for (j = 0; j < 10; j = j + 1) begin
            @(posedge clk); #1;
            argmax_y_in   = scores[j];
            argmax_k_in   = j[3:0];
            argmax_enable = 1;
        end
    end

    @(posedge clk); #1;
    argmax_enable = 0;
    @(posedge clk); #1;

    $display("  Empate entre y[3]=+1.0 e y[7]=+1.0");
    $display("  max_idx = %0d  (esperado: 3 — primeiro encontrado)", argmax_max_idx);
    if (argmax_max_idx == 4'd3)
        $display("  [PASS] Empate resolvido corretamente (índice menor)");
    else
        $display("  [WARN] Empate retornou índice %0d (aceitável se > é usado; FAIL se < esperado)",
            argmax_max_idx);

    // ─────────────────────────────────────────────────────────────────────
    // TESTE 4: Argmax com todos escores negativos
    // Comportamento esperado: retorna o índice do menos negativo
    // ─────────────────────────────────────────────────────────────────────
    $display("\n=== TESTE 4: Argmax com todos escores negativos ===");

    @(posedge clk); #1;
    argmax_start  = 1;
    argmax_enable = 0;
    @(posedge clk); #1;
    argmax_start = 0;

    begin : teste4_scores
        reg signed [15:0] neg_scores [0:9];
        integer j;
        // Verificação dos valores hex em Q4.12 signed:
        // 0xF000 = -4096 → -4096/4096 = -1.000
        // 0xE000 = -8192 → -8192/4096 = -2.000
        // 0xFF00 =  -256 →  -256/4096 = -0.0625  ← MÍNIMO negativo (máximo!)
        // 0xC000 =-16384 →-16384/4096 = -4.000
        // 0xF800 = -2048 → -2048/4096 = -0.500
        // 0xF400 = -3072 → -3072/4096 = -0.750
        // 0xF200 = -3584 → -3584/4096 = -0.875
        // 0xD000 =-12288 →-12288/4096 = -3.000
        // 0xFC00 = -1024 → -1024/4096 = -0.250
        // 0xFE00 =  -512 →  -512/4096 = -0.125
        // Máximo: índice 2 (y[2] = -0.0625 é o menos negativo)
        neg_scores[0] = 16'hF000;  // -1.0000
        neg_scores[1] = 16'hE000;  // -2.0000
        neg_scores[2] = 16'hFF00;  // -0.0625 ← MÁXIMO (menos negativo)
        neg_scores[3] = 16'hC000;  // -4.0000
        neg_scores[4] = 16'hF800;  // -0.5000
        neg_scores[5] = 16'hF400;  // -0.7500
        neg_scores[6] = 16'hF200;  // -0.8750
        neg_scores[7] = 16'hD000;  // -3.0000
        neg_scores[8] = 16'hFC00;  // -0.2500
        neg_scores[9] = 16'hFE00;  // -0.1250

        for (j = 0; j < 10; j = j + 1) begin
            @(posedge clk); #1;
            argmax_y_in   = neg_scores[j];
            argmax_k_in   = j[3:0];
            argmax_enable = 1;
        end
    end

    @(posedge clk); #1;
    argmax_enable = 0;
    @(posedge clk); #1;

    // Máximo correto: índice 2 (valor -0.0625 = 0xFF00 = -256 em Q4.12)
    // O índice 9 vale -0.125 — mais negativo que -0.0625, portanto não é o max.
    $display("  Escores todos negativos. Maximo em y[2] = -0.0625 (0xFF00 = -256)");
    $display("  max_idx = %0d  max_val = %0.5f  (esperado: idx=2, val=-0.0625)",
        argmax_max_idx, q412_to_float(argmax_max_val));
    if (argmax_max_idx == 4'd2)
        $display("  [PASS] Argmax signed correto com escores negativos");
    else
        $display("  [FAIL] Erro na comparacao signed (esperado idx=2)");

    // ─────────────────────────────────────────────────────────────────────
    // RESUMO FINAL
    // ─────────────────────────────────────────────────────────────────────
    $display("\n=== RESUMO ===");
    $display("  Teste 1 (PWL 128 neurônios): %s  (%0d pass / %0d fail)",
        (pwl_fail == 0) ? "PASS" : "FAIL", pwl_pass, pwl_fail);
    $display("  Teste 2 (Argmax real):        %s  (pred=%0d esperado=%0d)",
        (pred_result == EXPECTED_PRED) ? "PASS" : "FAIL",
        pred_result, EXPECTED_PRED);
    $display("  Teste 3 (Empate):             Ver acima");
    $display("  Teste 4 (Negativos):          %s",
        (argmax_max_idx == 4'd2) ? "PASS" : "FAIL");
    $display("");

    $finish;
end

endmodule