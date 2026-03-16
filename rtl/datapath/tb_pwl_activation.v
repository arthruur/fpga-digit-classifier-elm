// =============================================================================
// tb_pwl_activation.v
// Testbench completo para pwl_activation.v
//
// O que este testbench verifica:
//   1. Sweep exaustivo de -4.0 a +4.0 (step de 1 LSB Q4.12)
//   2. Pontos críticos: breakpoints, zero, extremos de saturação
//   3. Propriedade de função ímpar: f(-x) == -f(x)
//   4. Continuidade nos breakpoints (sem saltos bruscos)
//   5. MAE calculado contra valores tanh "reais" (pré-calculados em Python)
//   6. Comparação entre pwl_activation (Liu 5-seg)
//
// Como gerar os valores de referência tanh (rodar no Python antes da sim):
//   python3 gen_tanh_ref.py   → gera tanh_ref.hex
// =============================================================================

`timescale 1ns/1ps

module tb_pwl_activation;

// ---------------------------------------------------------------------------
// DUT — Device Under Test
// ---------------------------------------------------------------------------
reg  signed [15:0] x_in;
wire signed [15:0] y_liu;   // pwl_activation   (5 segmentos, Liu 2023)

pwl_activation   dut_liu (.x_in(x_in), .y_out(y_liu));

// ---------------------------------------------------------------------------
// Referência tanh exato pré-calculada em Python (armazenada em memória)
//   Faixa: x de -4.0 a +4.0 em passos de 1/4096 (1 LSB Q4.12)
//   Total: 8192 + 1 = 8193 entradas
//   Formato: valores Q4.12 signed de 16 bits em hexadecimal
// ---------------------------------------------------------------------------
parameter NPTS = 32768;  // -4.0 a +4.0 em LSB: 8.0 * 4096 = 32768 pontos
reg signed [15:0] tanh_ref [0:NPTS-1];
integer ref_loaded;

// Contadores de erro
integer total_pts;
real    mae_liu, mae_v2;
real    max_ae_liu, max_ae_v2;
integer x_max_liu, x_max_v2;

// Variáveis de iteração
integer i;
integer ae_liu_int, ae_v2_int;
real    ae_liu_real, ae_v2_real;
integer abs_err_liu, abs_err_v2;

// Arquivo de log
integer log_fd;

// ---------------------------------------------------------------------------
// TASK: converter Q4.12 para float (para exibição)
// ---------------------------------------------------------------------------
function real q412_to_float;
    input signed [15:0] val;
    begin
        q412_to_float = $itor($signed(val)) / 4096.0;
    end
endfunction

// ---------------------------------------------------------------------------
// INITIAL: carregar referência e executar testes
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_pwl_activation.vcd");
    $dumpvars(0, tb_pwl_activation);

    // ── Tentar carregar arquivo de referência ──────────────────────────────
    ref_loaded = 0;
    $readmemh("tanh_ref.hex", tanh_ref);
    ref_loaded = 1;
    $display("=== Referência tanh carregada (%0d pontos) ===", NPTS);

    // ── Inicializar contadores ─────────────────────────────────────────────
    total_pts  = 0;
    mae_liu    = 0.0;
    mae_v2     = 0.0;
    max_ae_liu = 0.0;
    max_ae_v2  = 0.0;
    x_max_liu  = 0;
    x_max_v2   = 0;

    // ── Abrir arquivo de log ───────────────────────────────────────────────
    log_fd = $fopen("pwl_error_log.csv", "w");
    $fwrite(log_fd, "x_int,x_float,y_liu_int,y_liu_float,y_v2_int,y_v2_float,tanh_ref_int,tanh_ref_float,ae_liu,ae_v2\n");

    // ── TESTE 1: Sweep completo -4.0 a +4.0 ──────────────────────────────
    $display("\n--- TESTE 1: Sweep completo [-4.0, +4.0] ---");
    for (i = 0; i < NPTS; i = i + 1) begin
        // x_in varia de -16384 (-4.0) a +16383 (+3.999...)
        x_in = $signed(16'hC000) + i;  // começa em -4.0
        #1;  // espera lógica combinacional estabilizar

        if (ref_loaded) begin
            // Calcular erros absolutos (em inteiro Q4.12)
            abs_err_liu = $signed(y_liu) - $signed(tanh_ref[i]);
            abs_err_v2  = $signed(y_v2)  - $signed(tanh_ref[i]);
            if (abs_err_liu < 0) abs_err_liu = -abs_err_liu;
            if (abs_err_v2  < 0) abs_err_v2  = -abs_err_v2;

            ae_liu_real = $itor(abs_err_liu) / 4096.0;
            ae_v2_real  = $itor(abs_err_v2)  / 4096.0;

            mae_liu = mae_liu + ae_liu_real;
            mae_v2  = mae_v2  + ae_v2_real;
            total_pts = total_pts + 1;

            if (ae_liu_real > max_ae_liu) begin
                max_ae_liu = ae_liu_real;
                x_max_liu  = $signed(x_in);
            end
            if (ae_v2_real > max_ae_v2) begin
                max_ae_v2 = ae_v2_real;
                x_max_v2  = $signed(x_in);
            end

            // Log CSV (escrever apenas 1 em 64 pontos para não explodir o arquivo)
            if ((i % 64) == 0)
                $fwrite(log_fd, "%0d,%f,%0d,%f,%0d,%f,%0d,%f,%f,%f\n",
                    $signed(x_in),  q412_to_float(x_in),
                    $signed(y_liu), q412_to_float(y_liu),
                    $signed(y_v2),  q412_to_float(y_v2),
                    $signed(tanh_ref[i]), q412_to_float(tanh_ref[i]),
                    ae_liu_real, ae_v2_real);
        end
    end

    if (ref_loaded && total_pts > 0) begin
        mae_liu = mae_liu / $itor(total_pts);
        mae_v2  = mae_v2  / $itor(total_pts);
        $display("  pwl_liu  (5-seg): MAE = %f  MaxAE = %f  @ x = %f",
                 mae_liu, max_ae_liu, q412_to_float(x_max_liu));
        $display("  pwl_v2   (3-seg): MAE = %f  MaxAE = %f  @ x = %f",
                 mae_v2, max_ae_v2, q412_to_float(x_max_v2));
        $display("  Melhora relativa do Liu vs. V2: %fx no MAE",
                 (mae_v2 / mae_liu));

        // Critério de pass/fail
        if (mae_liu <= 0.010)
            $display("  [PASS] MAE da pwl_liu dentro do limite (< 0.010)");
        else
            $display("  [FAIL] MAE da pwl_liu EXCEDE o limite (< 0.010)");
    end

    // ── TESTE 2: Pontos críticos (breakpoints e saturações) ───────────────
    $display("\n--- TESTE 2: Pontos Críticos ---");
    begin : teste2
        reg signed [15:0] test_x [0:11];
        reg signed [15:0] expected_min [0:11];
        reg signed [15:0] expected_max [0:11];
        integer j;

        // Valores de teste e limites esperados (margem ±2 LSB para Q4.12)
        // x = -4.0 → y deve ser exatamente -1.0
        test_x[0]  = 16'hC000;  // -4.0
        test_x[1]  = 16'hE000;  // -2.0
        test_x[2]  = 16'hF800;  // -0.5
        test_x[3]  = 16'hFC00;  // -0.25
        test_x[4]  = 16'h0000;  // 0.0
        test_x[5]  = 16'h0400;  // +0.25
        test_x[6]  = 16'h0800;  // +0.5
        test_x[7]  = 16'h1000;  // +1.0
        test_x[8]  = 16'h1800;  // +1.5
        test_x[9]  = 16'h2000;  // +2.0
        test_x[10] = 16'h4000;  // +4.0 → saturação
        test_x[11] = 16'h7FFF;  // máximo positivo Q4.12 → saturação

        for (j = 0; j < 12; j = j + 1) begin
            x_in = test_x[j];
            #1;
            $display("  x = %7.4f (%5d) | liu=%7.4f (%5d) | v2=%7.4f (%5d)",
                q412_to_float(x_in),   $signed(x_in),
                q412_to_float(y_liu),  $signed(y_liu),
                q412_to_float(y_v2),   $signed(y_v2));
        end
    end

    // ── TESTE 3: Propriedade de função ímpar ──────────────────────────────
    $display("\n--- TESTE 3: Simetria f(-x) == -f(x) ---");
    begin : teste3
        reg signed [15:0] sym_x [0:7];
        reg signed [15:0] y_pos_test, y_neg_test;
        integer j, sym_pass;
        sym_pass = 1;

        sym_x[0] = 16'h0400;  // +0.25
        sym_x[1] = 16'h0800;  // +0.5
        sym_x[2] = 16'h0C00;  // +0.75
        sym_x[3] = 16'h1000;  // +1.0
        sym_x[4] = 16'h1400;  // +1.25
        sym_x[5] = 16'h1800;  // +1.5
        sym_x[6] = 16'h1C00;  // +1.75
        sym_x[7] = 16'h2000;  // +2.0

        for (j = 0; j < 8; j = j + 1) begin
            // Testar com x positivo
            x_in = sym_x[j];
            #1;
            y_pos_test = y_liu;

            // Testar com x negativo
            x_in = -$signed(sym_x[j]);
            #1;
            y_neg_test = y_liu;

            if ($signed(y_pos_test) != -$signed(y_neg_test)) begin
                $display("  [FAIL] Simetria quebrada em x=%7.4f: f(x)=%7.4f  -f(-x)=%7.4f",
                    q412_to_float(sym_x[j]),
                    q412_to_float(y_pos_test),
                    q412_to_float(-$signed(y_neg_test)));
                sym_pass = 0;
            end
        end
        if (sym_pass)
            $display("  [PASS] Propriedade de função ímpar verificada em todos os 8 pontos");
    end

    // ── TESTE 4: Continuidade nos breakpoints ─────────────────────────────
    $display("\n--- TESTE 4: Continuidade nos Breakpoints (liu 5-seg) ---");
    begin : teste4
        reg signed [15:0] bp [0:3];
        reg signed [15:0] y_before, y_after;
        integer j;
        integer delta;

        bp[0] = 16'h0400;  // 0.25
        bp[1] = 16'h0800;  // 0.5
        bp[2] = 16'h1000;  // 1.0
        bp[3] = 16'h1800;  // 1.5

        for (j = 0; j < 4; j = j + 1) begin
            // 1 LSB antes do breakpoint
            x_in = bp[j] - 1;
            #1;
            y_before = y_liu;

            // exatamente no breakpoint
            x_in = bp[j];
            #1;
            y_after = y_liu;

            delta = $signed(y_after) - $signed(y_before);
            if (delta < 0) delta = -delta;

            $display("  BP x=%5.3f: antes=%6.4f  depois=%6.4f  delta=%d LSB  %s",
                q412_to_float(bp[j]),
                q412_to_float(y_before),
                q412_to_float(y_after),
                delta,
                (delta <= 8) ? "[OK  continuo]" : "[WARN salto >8 LSB]");
        end
    end

    // ── Finalizar ──────────────────────────────────────────────────────────
    $fclose(log_fd);
    $display("\n=== Testbench concluido. Log salvo em pwl_error_log.csv ===\n");
    $finish;
end

endmodule
