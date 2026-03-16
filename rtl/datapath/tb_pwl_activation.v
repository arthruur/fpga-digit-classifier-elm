// =============================================================================
// tb_pwl_activation.v  —  Testbench TDD para pwl_activation.v
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Módulo combinacional: sem clock nos testes TC-PWL-01..16.
// Valores de referência calculados inline pela função pwl_ref (Verilog),
// que replica a mesma lógica do DUT. Sem dependência de arquivo externo.
// =============================================================================
`timescale 1ns/1ps

module tb_pwl_activation;

reg  signed [15:0] x_in;
wire signed [15:0] y_out;

pwl_activation dut (.x_in(x_in), .y_out(y_out));

integer pass_count, fail_count;

// ── Verificação exata ─────────────────────────────────────────────────────────
task check_exact;
    input [127:0] id;
    input signed [15:0] x_val, expected;
    begin
        x_in = x_val; #3;
        if (y_out === expected) begin
            $display("  [PASS] %s  x=%0d  y=%0d", id, $signed(x_val), $signed(y_out));
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s  x=%0d  got=%0d  exp=%0d",
                id, $signed(x_val), $signed(y_out), $signed(expected));
            fail_count = fail_count + 1;
        end
    end
endtask

// ── Verificação de continuidade ───────────────────────────────────────────────
task check_continuity;
    input [127:0] id;
    input signed [15:0] x_bp;
    input integer max_delta;
    reg signed [15:0] y_before, y_at;
    integer delta;
    begin
        x_in = x_bp - 1; #3; y_before = y_out;
        x_in = x_bp;     #3; y_at     = y_out;
        delta = $signed(y_at) - $signed(y_before);
        if (delta < 0) delta = -delta;
        if (delta <= max_delta) begin
            $display("  [PASS] %s  delta=%0d LSBs", id, delta);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s  delta=%0d > %0d", id, delta, max_delta);
            fail_count = fail_count + 1;
        end
    end
endtask

// ── Referência PWL inline (mesma lógica do DUT) ───────────────────────────────
function signed [15:0] pwl_ref;
    input signed [15:0] xi;
    reg signed [15:0] xa, yp;
    reg x_neg;
    reg [15:0] shr1, shr2, shr3, shr4, shr9;
    begin
        x_neg = xi[15];
        xa    = x_neg ? (-xi) : xi;
        shr1  = xa >> 1; shr2 = xa >> 2; shr3 = xa >> 3;
        shr4  = xa >> 4; shr9 = xa >> 9;
        if      (xa >= 16'h2000) yp = 16'h1000;
        else if (xa >= 16'h1800) yp = shr3 + shr9 + 16'h0BF4;
        else if (xa >= 16'h1000) yp = shr2 + shr4 + 16'h0780;
        else if (xa >= 16'h0800) yp = shr1 + shr3 + 16'h0280;
        else if (xa >= 16'h0400) yp = (xa - shr3) + 16'h0078;
        else                     yp = xa;
        pwl_ref = x_neg ? (-yp) : yp;
    end
endfunction

integer i, err, max_err, total_err, n_pts;
real mae;
reg signed [15:0] xp2, xn2, yp2, yn2;

initial begin
    $dumpfile("tb_pwl_activation.vcd");
    $dumpvars(0, tb_pwl_activation);
    pass_count = 0; fail_count = 0; x_in = 0;

    $display("\n====================================================");
    $display("  Testbench TDD: pwl_activation.v");
    $display("====================================================");

    // TC-PWL-01
    $display("\n--- TC-PWL-01: x=0 -> y=0 ---");
    check_exact("TC-PWL-01", 16'h0000, 16'h0000);

    // TC-PWL-02..06: Interior de cada segmento
    $display("\n--- TC-PWL-02..06: Interior de segmentos ---");
    check_exact("TC-PWL-02", 16'h0200, pwl_ref(16'h0200));
    check_exact("TC-PWL-03", 16'h0600, pwl_ref(16'h0600));
    check_exact("TC-PWL-04", 16'h0C00, pwl_ref(16'h0C00));
    check_exact("TC-PWL-05", 16'h1400, pwl_ref(16'h1400));
    check_exact("TC-PWL-06", 16'h1C00, pwl_ref(16'h1C00));

    // TC-PWL-07..10: Continuidade
    $display("\n--- TC-PWL-07..10: Continuidade nos breakpoints (max 8 LSBs) ---");
    check_continuity("TC-PWL-07", 16'h0400, 8);
    check_continuity("TC-PWL-08", 16'h0800, 8);
    check_continuity("TC-PWL-09", 16'h1000, 8);
    check_continuity("TC-PWL-10", 16'h1800, 8);

    // TC-PWL-11: Saturação positiva
    $display("\n--- TC-PWL-11: Saturacao positiva ---");
    check_exact("TC-PWL-11a", 16'h2000, 16'h1000);
    check_exact("TC-PWL-11b", 16'h2001, 16'h1000);
    check_exact("TC-PWL-11c", 16'h7FFF, 16'h1000);

    // TC-PWL-12: Saturação negativa
    $display("\n--- TC-PWL-12: Saturacao negativa ---");
    check_exact("TC-PWL-12a", 16'hE000, 16'hF000);
    check_exact("TC-PWL-12b", 16'hDFFF, 16'hF000);
    check_exact("TC-PWL-12c", 16'h8000, 16'hF000);

    // TC-PWL-13..16: Função ímpar
    $display("\n--- TC-PWL-13..16: Funcao impar f(-x)==-f(x) ---");
    begin : impar
        reg signed [15:0] xpos [0:3];
        integer j;
        xpos[0] = 16'h0600; xpos[1] = 16'h0C00;
        xpos[2] = 16'h1400; xpos[3] = 16'h1C00;
        for (j = 0; j < 4; j = j + 1) begin
            x_in = xpos[j];        #3; yp2 = y_out;
            x_in = -$signed(xpos[j]); #3; yn2 = y_out;
            if ($signed(yp2) === -$signed(yn2)) begin
                $display("  [PASS] TC-PWL-1%0d  x=%0d  f(x)=%0d  -f(-x)=%0d",
                    3+j, $signed(xpos[j]), $signed(yp2), -$signed(yn2));
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] TC-PWL-1%0d  f(x)=%0d  -f(-x)=%0d",
                    3+j, $signed(yp2), -$signed(yn2));
                fail_count = fail_count + 1;
            end
        end
    end

    // TC-PWL-17: Coerência interna (256 pontos)
    $display("\n--- TC-PWL-17: Coerencia interna 256 pontos ---");
    total_err = 0; n_pts = 0; max_err = 0;
    for (i = -16384; i < 16384; i = i + 128) begin
        x_in = i[15:0]; #3;
        err  = $signed(y_out) - $signed(pwl_ref(i[15:0]));
        if (err < 0) err = -err;
        if (err > max_err) max_err = err;
        total_err = total_err + err;
        n_pts = n_pts + 1;
    end
    mae = $itor(total_err) / ($itor(n_pts) * 4096.0);
    if (max_err == 0) begin
        $display("  [PASS] TC-PWL-17  MAE=0 (coerencia perfeita com pwl_ref)");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] TC-PWL-17  MaxAE=%0d LSBs  MAE=%f", max_err, mae);
        fail_count = fail_count + 1;
    end

    $display("\n====================================================");
    $display("  RESULTADO: %0d PASS  /  %0d FAIL", pass_count, fail_count);
    $display("  STATUS: %s",
        (fail_count==0) ? "TODOS OS TESTES PASSARAM" : "IMPLEMENTACAO INCOMPLETA");
    $display("====================================================\n");
    $finish;
end
endmodule
