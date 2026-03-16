// =============================================================================
// tb_mac_unit.v  —  Testbench TDD para mac_unit.v
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Cada teste corresponde a um caso descrito em test_spec.md.
// Todos os testes DEVEM FALHAR antes da implementação do módulo.
// Rodar com: vlog mac_unit.v tb_mac_unit.v && vsim -c tb_mac_unit -do "run -all"
// =============================================================================
`timescale 1ns/1ps

module tb_mac_unit;

// ── DUT ──────────────────────────────────────────────────────────────────────
reg        clk, rst_n, mac_en, mac_clr;
reg  [15:0] a, b;
wire [15:0] acc_out;
wire        overflow;

mac_unit dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .mac_en  (mac_en),
    .mac_clr (mac_clr),
    .a       (a),
    .b       (b),
    .acc_out (acc_out),
    .overflow(overflow)
);

// ── Clock 100 MHz ─────────────────────────────────────────────────────────────
always #5 clk = ~clk;

// ── Contadores de pass/fail ───────────────────────────────────────────────────
integer pass_count, fail_count;

// ── Tarefa de verificação ─────────────────────────────────────────────────────
task check;
    input [127:0] test_id;   // nome do teste (string comprimida)
    input [15:0]  expected;
    input         expected_ovf;
    begin
        if (acc_out === expected && overflow === expected_ovf) begin
            $display("  [PASS] %s", test_id);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s", test_id);
            if (acc_out !== expected)
                $display("         acc_out:   got 0x%04X (%0d)  expected 0x%04X (%0d)",
                    acc_out, $signed(acc_out), expected, $signed(expected));
            if (overflow !== expected_ovf)
                $display("         overflow:  got %b  expected %b", overflow, expected_ovf);
            fail_count = fail_count + 1;
        end
    end
endtask

// ── Macro para avançar 1 ciclo ────────────────────────────────────────────────
task tick;
    begin
        @(posedge clk); #1;
    end
endtask

// ── Estado neutro entre testes ────────────────────────────────────────────────
task idle_state;
    begin
        mac_en  = 0;
        mac_clr = 0;
        a       = 16'h0000;
        b       = 16'h0000;
    end
endtask

// ── Reset completo ────────────────────────────────────────────────────────────
task do_reset;
    begin
        rst_n = 0;
        idle_state;
        tick; tick;
        rst_n = 1;
        tick;
    end
endtask

// ─────────────────────────────────────────────────────────────────────────────
// SEQUÊNCIA DE TESTES
// ─────────────────────────────────────────────────────────────────────────────
initial begin
    $dumpfile("tb_mac_unit.vcd");
    $dumpvars(0, tb_mac_unit);

    clk        = 0;
    pass_count = 0;
    fail_count = 0;

    $display("\n====================================================");
    $display("  Testbench TDD: mac_unit.v");
    $display("====================================================");

    // =========================================================================
    // TC-MAC-01: Reset síncrono limpa o acumulador
    // =========================================================================
    $display("\n--- TC-MAC-01: Reset limpa acumulador ---");
    do_reset;
    check("TC-MAC-01", 16'h0000, 1'b0);

    // =========================================================================
    // TC-MAC-02: mac_clr tem prioridade sobre mac_en
    // =========================================================================
    $display("\n--- TC-MAC-02: mac_clr > mac_en ---");
    do_reset;
    // Acumular +1.0
    mac_en = 1; a = 16'h1000; b = 16'h1000; tick;
    // Assertar ambos simultaneamente
    mac_clr = 1; mac_en = 1; a = 16'h7FFF; b = 16'h7FFF; tick;
    mac_clr = 0; mac_en = 0; tick;
    check("TC-MAC-02", 16'h0000, 1'b0);

    // =========================================================================
    // TC-MAC-03: mac_en=0 mantém acumulador estável
    // =========================================================================
    $display("\n--- TC-MAC-03: mac_en=0 mantém acc ---");
    do_reset;
    // Acumular +1.0
    mac_en = 1; a = 16'h1000; b = 16'h1000; tick;
    mac_en = 0; a = 16'h7FFF; b = 16'h7FFF;
    // Verificar por 5 ciclos
    begin : tc03_loop
        integer i;
        for (i = 0; i < 5; i = i + 1) begin
            tick;
            if (acc_out !== 16'h1000 || overflow !== 1'b0) begin
                $display("  [FAIL] TC-MAC-03 no ciclo %0d: acc=0x%04X", i, acc_out);
                fail_count = fail_count + 1;
                disable tc03_loop;
            end
        end
        $display("  [PASS] TC-MAC-03");
        pass_count = pass_count + 1;
    end

    // =========================================================================
    // TC-MAC-04: 1.0 × 1.0 = 1.0
    // =========================================================================
    $display("\n--- TC-MAC-04: +1.0 × +1.0 = +1.0 ---");
    do_reset;
    mac_en = 1; a = 16'h1000; b = 16'h1000; tick;
    mac_en = 0; tick;
    check("TC-MAC-04", 16'h1000, 1'b0);

    // =========================================================================
    // TC-MAC-05: 0.5 × 0.5 = 0.25
    // =========================================================================
    $display("\n--- TC-MAC-05: +0.5 × +0.5 = +0.25 ---");
    do_reset;
    mac_en = 1; a = 16'h0800; b = 16'h0800; tick;
    mac_en = 0; tick;
    check("TC-MAC-05", 16'h0400, 1'b0);

    // =========================================================================
    // TC-MAC-06: +1.0 × −1.0 = −1.0
    // =========================================================================
    $display("\n--- TC-MAC-06: +1.0 × -1.0 = -1.0 ---");
    do_reset;
    mac_en = 1; a = 16'h1000; b = 16'hF000; tick;
    mac_en = 0; tick;
    check("TC-MAC-06", 16'hF000, 1'b0);

    // =========================================================================
    // TC-MAC-07: −1.0 × −1.0 = +1.0
    // =========================================================================
    $display("\n--- TC-MAC-07: -1.0 × -1.0 = +1.0 ---");
    do_reset;
    mac_en = 1; a = 16'hF000; b = 16'hF000; tick;
    mac_en = 0; tick;
    check("TC-MAC-07", 16'h1000, 1'b0);

    // =========================================================================
    // TC-MAC-08: Acumulação de 4 parcelas
    // Esperado: +0.25 + 0.50 + 0.25 + 0.25 = +1.25 = 0x1400 = 5120
    // =========================================================================
    $display("\n--- TC-MAC-08: Acumulacao de 4 parcelas = +1.25 ---");
    do_reset;
    mac_en = 1;
    a = 16'h1000; b = 16'h0400; tick;  // +1.0 × +0.25 = +0.25
    a = 16'h1000; b = 16'h0800; tick;  // +1.0 × +0.50 = +0.50 → acc = 0.75
    a = 16'h1000; b = 16'h0400; tick;  // +1.0 × +0.25        → acc = 1.00
    a = 16'h1000; b = 16'h0400; tick;  // +1.0 × +0.25        → acc = 1.25
    mac_en = 0; tick;
    check("TC-MAC-08", 16'h1400, 1'b0);

    // =========================================================================
    // TC-MAC-09: +1.0 + (-1.0) = 0
    // =========================================================================
    $display("\n--- TC-MAC-09: Cancelamento: +1.0 + (-1.0) = 0 ---");
    do_reset;
    mac_en = 1;
    a = 16'h1000; b = 16'h1000; tick;  // acc = +1.0
    a = 16'h1000; b = 16'hF000; tick;  // acc = 0.0
    mac_en = 0; tick;
    check("TC-MAC-09", 16'h0000, 1'b0);

    // =========================================================================
    // TC-MAC-10: Saturação positiva
    // 8 acumulações de +1.0 × +1.0. Na 8ª, acc tentaria +8.0 → satura em 0x7FFF
    // =========================================================================
    $display("\n--- TC-MAC-10: Saturacao positiva em +7.999 ---");
    do_reset;
    mac_en = 1; a = 16'h1000; b = 16'h1000;
    begin : tc10_loop
        integer i;
        for (i = 0; i < 8; i = i + 1) tick;
    end
    mac_en = 0; tick;
    if (acc_out === 16'h7FFF) begin
        $display("  [PASS] TC-MAC-10: acc_out=0x7FFF (saturado)");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] TC-MAC-10: acc_out=0x%04X  esperado=0x7FFF", acc_out);
        fail_count = fail_count + 1;
    end

    // =========================================================================
    // TC-MAC-11: Saturação negativa
    // 8 acumulações de +1.0 × −1.0 → satura em 0x8000
    // =========================================================================
    $display("\n--- TC-MAC-11: Saturacao negativa em -8.0 ---");
    do_reset;
    mac_en = 1; a = 16'h1000; b = 16'hF000;
    begin : tc11_loop
        integer i;
        for (i = 0; i < 8; i = i + 1) tick;
    end
    mac_en = 0; tick;
    if (acc_out === 16'h8000) begin
        $display("  [PASS] TC-MAC-11: acc_out=0x8000 (saturado)");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] TC-MAC-11: acc_out=0x%04X  esperado=0x8000", acc_out);
        fail_count = fail_count + 1;
    end

    // =========================================================================
    // TC-MAC-12: Saturação é permanente até mac_clr
    // =========================================================================
    $display("\n--- TC-MAC-12: Saturacao permanece ate mac_clr ---");
    do_reset;
    // Saturar positivamente
    mac_en = 1; a = 16'h1000; b = 16'h1000;
    begin : tc12_sat
        integer i;
        for (i = 0; i < 8; i = i + 1) tick;
    end
    // Tentar reduzir com -0.25
    a = 16'h1000; b = 16'hFC00;  // +1.0 × −0.25
    tick;
    // Deve continuar saturado
    mac_en = 0; tick;
    if (acc_out === 16'h7FFF) begin
        $display("  [PASS] TC-MAC-12a: acc permanece saturado apos acumulacao");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] TC-MAC-12a: acc=0x%04X, deveria ser 0x7FFF", acc_out);
        fail_count = fail_count + 1;
    end
    // Agora limpar
    mac_clr = 1; tick; mac_clr = 0; tick;
    if (acc_out === 16'h0000) begin
        $display("  [PASS] TC-MAC-12b: mac_clr limpa saturacao");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] TC-MAC-12b: acc=0x%04X apos clr", acc_out);
        fail_count = fail_count + 1;
    end

    // =========================================================================
    // TC-MAC-13: Produto menor que 1 LSB Q4.12 → truncado para zero
    // a = b = 0x0001 (+1/4096). produto = 1 × 1 = 1. product[27:12] = 0.
    // =========================================================================
    $display("\n--- TC-MAC-13: Truncamento abaixo da resolucao ---");
    do_reset;
    mac_en = 1; a = 16'h0001; b = 16'h0001; tick;
    mac_en = 0; tick;
    check("TC-MAC-13", 16'h0000, 1'b0);

    // =========================================================================
    // TC-MAC-14: mac_clr e nova acumulação imediata
    // =========================================================================
    $display("\n--- TC-MAC-14: mac_clr e nova acumulacao imediata ---");
    do_reset;
    // Acumular +2.0
    mac_en = 1; a = 16'h2000; b = 16'h1000; tick;  // +2.0 × +1.0 = +2.0
    mac_en = 0; tick;
    // Limpar
    mac_clr = 1; tick; mac_clr = 0;
    // Acumular imediatamente no ciclo seguinte
    mac_en = 1; a = 16'h0800; b = 16'h1000; tick;  // +0.5 × +1.0 = +0.5
    mac_en = 0; tick;
    check("TC-MAC-14", 16'h0800, 1'b0);

    // =========================================================================
    // RESULTADO FINAL
    // =========================================================================
    $display("\n====================================================");
    $display("  RESULTADO: %0d PASS  /  %0d FAIL", pass_count, fail_count);
    if (fail_count == 0)
        $display("  STATUS: TODOS OS TESTES PASSARAM");
    else
        $display("  STATUS: IMPLEMENTACAO INCOMPLETA — corrigir falhas");
    $display("====================================================\n");

    $finish;
end

endmodule
