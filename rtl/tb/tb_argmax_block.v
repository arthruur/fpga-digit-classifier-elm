// =============================================================================
// tb_argmax_block.v  —  Testbench TDD para argmax_block.v
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
// =============================================================================
`timescale 1ns/1ps

module tb_argmax_block;

    // ── DUT ──────────────────────────────────────────────────────────────────
    reg               clk, rst_n, start, enable;
    reg signed [15:0] y_in;
    reg        [3:0]  k_in;
    wire       [3:0]  max_idx;
    wire              done;

    argmax_block dut (
        .clk(clk), .rst_n(rst_n), .start(start), .enable(enable),
        .y_in(y_in), .k_in(k_in), .max_idx(max_idx), .done(done)
    );

    // ── Clock & Variáveis de Teste ───────────────────────────────────────────
    always #5 clk = ~clk;

    integer pass_count, fail_count;
    reg signed [15:0] test_array [0:9]; // Array para guardar os 10 escores
    integer i;

    // ── Tarefas Auxiliares ───────────────────────────────────────────────────
    task tick; begin @(posedge clk); #1; end endtask

    task do_reset;
        begin
            rst_n = 0; start = 0; enable = 0; y_in = 0; k_in = 0;
            tick; tick;
            rst_n = 1;
            tick;
        end
    endtask

    // Alimenta os 10 valores do test_array para o DUT de forma contínua
    task feed_10_scores;
        begin
            for (i = 0; i < 10; i = i + 1) begin
                enable = 1;
                y_in   = test_array[i];
                k_in   = i;
                tick;
            end
            enable = 0; // Desliga após enviar
        end
    endtask

    // ── Verificação ──────────────────────────────────────────────────────────
    task check_result;
        input [127:0] id;
        input [3:0]   exp_idx;
        begin
            if (max_idx === exp_idx) begin
                $display("  [PASS] %s  (max_idx=%0d)", id, max_idx);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %s  got=%0d  exp=%0d", id, max_idx, exp_idx);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ── SEQUÊNCIA DE TESTES ──────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_argmax_block.vcd");
        $dumpvars(0, tb_argmax_block);
        clk = 0; pass_count = 0; fail_count = 0;

        $display("\n====================================================");
        $display("  Testbench TDD: argmax_block.v");
        $display("====================================================");

        // TC-ARG-01: Reset
        $display("\n--- TC-ARG-01: Estado Inicial ---");
        do_reset;
        if (max_idx === 4'd0 && done === 1'b0) begin
            $display("  [PASS] TC-ARG-01"); pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] TC-ARG-01"); fail_count = fail_count + 1;
        end

        // TC-ARG-02: Máximo no primeiro (idx 0)
        $display("\n--- TC-ARG-02: Maximo no indice 0 ---");
        do_reset; start = 1; tick; start = 0;
        test_array[0]=16'h2000; test_array[1]=16'h1000; test_array[2]=16'h0800; test_array[3]=16'h0000;
        test_array[4]=16'hF800; test_array[5]=16'hF000; test_array[6]=16'h0400; test_array[7]=16'h0C00;
        test_array[8]=16'hFC00; test_array[9]=16'h1800;
        feed_10_scores;
        check_result("TC-ARG-02", 4'd0);

        // TC-ARG-03: Máximo no último (idx 9)
        $display("\n--- TC-ARG-03: Maximo no indice 9 ---");
        do_reset; start = 1; tick; start = 0;
        test_array[0]=16'hF000; test_array[1]=16'hF800; test_array[2]=16'h0000; test_array[3]=16'h0800;
        test_array[4]=16'h1000; test_array[5]=16'h0C00; test_array[6]=16'h0400; test_array[7]=16'hFC00;
        test_array[8]=16'h1800; test_array[9]=16'h2000;
        feed_10_scores;
        check_result("TC-ARG-03", 4'd9);

        // TC-ARG-04: Máximo no meio (idx 5)
        $display("\n--- TC-ARG-04: Maximo no indice 5 ---");
        do_reset; start = 1; tick; start = 0;
        test_array[0]=16'h0000; test_array[1]=16'h0400; test_array[2]=16'h0800; test_array[3]=16'h0C00;
        test_array[4]=16'h1000; test_array[5]=16'h1800; test_array[6]=16'h1400; test_array[7]=16'h0800;
        test_array[8]=16'h0400; test_array[9]=16'h0000;
        feed_10_scores;
        check_result("TC-ARG-04", 4'd5);

        // TC-ARG-05: Todos iguais
        $display("\n--- TC-ARG-05: Todos os escores iguais ---");
        do_reset; start = 1; tick; start = 0;
        for(i=0; i<10; i=i+1) test_array[i] = 16'h1000;
        feed_10_scores;
        check_result("TC-ARG-05", 4'd0); // Primeiro que chegou

        // TC-ARG-06: Empate parcial (1 e 3)
        $display("\n--- TC-ARG-06: Empate parcial ---");
        do_reset; start = 1; tick; start = 0;
        for(i=0; i<10; i=i+1) test_array[i] = 16'h0000;
        test_array[1] = 16'h1000; test_array[3] = 16'h1000; // Empate nos mais altos
        feed_10_scores;
        check_result("TC-ARG-06", 4'd1);

        // TC-ARG-07: Todos negativos (Teste de Robustez Signed)
        $display("\n--- TC-ARG-07: Todos os escores negativos ---");
        do_reset; start = 1; tick; start = 0;
        test_array[0]=16'hC000; test_array[1]=16'hD000; test_array[2]=16'hE000; test_array[3]=16'hF000;
        test_array[4]=16'hF800; test_array[5]=16'hFC00; test_array[6]=16'hF400; test_array[7]=16'hE800;
        test_array[8]=16'hD800; test_array[9]=16'hC800;
        // O valor FC00 (-0.25) no índice 5 é o MAIOR valor matemático.
        feed_10_scores;
        check_result("TC-ARG-07", 4'd5);

        // TC-ARG-08: done dura exatamente 1 ciclo
        $display("\n--- TC-ARG-08: Flag done dura 1 ciclo ---");
        // Após o feed_10_scores do teste anterior, o clock já avançou 1 ciclo (onde done estava em 1)
        // e enable foi para 0. Vamos checar os próximos 2 ciclos.
        if (done === 1'b0) begin
             tick;
             if (done === 1'b0) begin
                 $display("  [PASS] TC-ARG-08"); pass_count = pass_count + 1;
             end else begin
                 $display("  [FAIL] TC-ARG-08"); fail_count = fail_count + 1;
             end
        end else begin
            $display("  [FAIL] TC-ARG-08 (done continuou 1)"); fail_count = fail_count + 1;
        end

        // TC-ARG-09: start reinicia no meio
        $display("\n--- TC-ARG-09: start aborta sequencia anterior ---");
        do_reset;
        // Envia 5 altos
        for(i=0; i<5; i=i+1) begin y_in=16'h3000; k_in=i; enable=1; tick; end
        // Aborta
        start = 1; enable=0; tick; start = 0;
        // Nova sequência com max no 7
        for(i=0; i<10; i=i+1) test_array[i] = 16'h0000;
        test_array[7] = 16'h1000;
        feed_10_scores;
        check_result("TC-ARG-09", 4'd7);

        // TC-ARG-10: enable=0 pausa sem afetar
        $display("\n--- TC-ARG-10: Pausa com enable=0 ---");
        do_reset; start = 1; tick; start = 0;
        // 3 valores (max é o index 1 = +2.0)
        enable=1; y_in=16'h0000; k_in=0; tick;
        enable=1; y_in=16'h2000; k_in=1; tick;
        enable=1; y_in=16'h0000; k_in=2; tick;
        // Pausa de 4 ciclos
        enable=0; tick; tick; tick; tick;
        // Restante (max é o index 8 = +3.0)
        for(i=3; i<10; i=i+1) begin
            enable=1; y_in=(i==8) ? 16'h3000 : 16'h0000; k_in=i; tick;
        end
        enable=0;
        check_result("TC-ARG-10", 4'd8);

        // TC-ARG-11: Dois argmax consecutivos sem vazar
        $display("\n--- TC-ARG-11: Duas sequencias limpas ---");
        do_reset; start = 1; tick; start = 0;
        for(i=0; i<10; i=i+1) test_array[i] = (i==3) ? 16'h1000 : 16'h0000;
        feed_10_scores;
        check_result("TC-ARG-11a", 4'd3);
        
        start = 1; tick; start = 0;
        for(i=0; i<10; i=i+1) test_array[i] = (i==7) ? 16'h2000 : 16'h0000;
        feed_10_scores;
        check_result("TC-ARG-11b", 4'd7);

        $display("\n====================================================");
        $display("  RESULTADO: %0d PASS  /  %0d FAIL", pass_count, fail_count);
        $display("====================================================\n");
        $finish;
    end
endmodule