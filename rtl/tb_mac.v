// =============================================================================
// tb_mac.v — Testbench da Unidade MAC (mac_unit)
// =============================================================================
// Projeto  : elm_accel — Co-processador ELM em FPGA
// Disciplina: TEC 499 · MI Sistemas Digitais · UEFS 2026.1
// Marco    : 1 / Fase 2
//
// Casos de teste cobertos (conforme roadmap):
//   TC01 — 0 × 0 = 0
//   TC02 — Valor positivo máximo Q4.12 × 1.0
//   TC03 — Overflow positivo → clamp 0x7FFF
//   TC04 — Overflow negativo → clamp 0x8000
//   TC05 — Sequência acumula-limpa-acumula (valida mac_clr)
//   TC06 — Produto de dois negativos (resultado positivo)
//   TC07 — Reset no meio de uma acumulação
//   TC08 — mac_en=0 não altera acumulador
//   TC09 — Acumulação de múltiplos valores sem overflow
//   TC10 — Clear zera acc_out (não mantém valor anterior)
//
// Como interpretar Q4.12:
//   Para converter real → Q4.12: round(valor * 4096)
//   Para converter Q4.12 → real: valor_signed / 4096.0
//   Exemplos:
//     1.0   → 16'h1000  (4096 decimal)
//     2.0   → 16'h2000
//     0.5   → 16'h0800
//    -1.0   → 16'hF000  (complemento de 2 de 4096)
//     7.999 → 16'h7FFB
//    -8.0   → 16'h8000
//
// Execução:
//   ModelSim/QuestaSim: vsim tb_mac
//   O testbench imprime PASS/FAIL para cada caso via $display.
//   Ao final, exibe contagem total de erros.
// =============================================================================

`timescale 1ns/1ps

module tb_mac;

    // -------------------------------------------------------------------------
    // Parâmetros de simulação
    // -------------------------------------------------------------------------
    parameter CLK_PERIOD = 20; // 50 MHz (20 ns por ciclo)

    // Constantes Q4.12 úteis
    parameter signed [15:0] Q_POS_MAX  = 16'h7FFF; //  +7.999755
    parameter signed [15:0] Q_NEG_MAX  = 16'h8000; //  -8.0
    parameter signed [15:0] Q_ONE      = 16'h1000; //  +1.0
    parameter signed [15:0] Q_NEG_ONE  = 16'hF000; //  -1.0
    parameter signed [15:0] Q_TWO      = 16'h2000; //  +2.0
    parameter signed [15:0] Q_HALF     = 16'h0800; //  +0.5
    parameter signed [15:0] Q_ZERO     = 16'h0000; //   0.0
    parameter signed [15:0] Q_NEG_HALF = 16'hF800; //  -0.5

    // -------------------------------------------------------------------------
    // DUT — Device Under Test
    // -------------------------------------------------------------------------
    reg        clk;
    reg        rst_n;
    reg        mac_en;
    reg        mac_clr;
    reg  [15:0] a;
    reg  [15:0] b;
    wire [15:0] acc_out;
    wire        overflow;

    mac_unit DUT (
        .clk      (clk),
        .rst_n    (rst_n),
        .mac_en   (mac_en),
        .mac_clr  (mac_clr),
        .a        (a),
        .b        (b),
        .acc_out  (acc_out),
        .overflow (overflow)
    );

    // -------------------------------------------------------------------------
    // Geração de clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Contador de erros global
    // -------------------------------------------------------------------------
    integer errors;
    integer test_num;

    // -------------------------------------------------------------------------
    // Task auxiliar: verifica resultado e imprime PASS/FAIL
    // -------------------------------------------------------------------------
    task check;
        input [15:0]    expected_acc;
        input           expected_ovf;
        input [63:0]    tc_num;
        input [255:0]   description;
        begin
            #1; // pequeno atraso para leituras estabilizarem após borda
            if (acc_out === expected_acc && overflow === expected_ovf) begin
                $display("[PASS] TC%02d — %s | acc_out=0x%04h ovf=%b",
                         tc_num, description, acc_out, overflow);
            end else begin
                $display("[FAIL] TC%02d — %s", tc_num, description);
                $display("       Esperado: acc_out=0x%04h ovf=%b",
                         expected_acc, expected_ovf);
                $display("       Obtido  : acc_out=0x%04h ovf=%b",
                         acc_out, overflow);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task auxiliar: aplica uma operação MAC e avança um ciclo
    // -------------------------------------------------------------------------
    task mac_op;
        input [15:0] op_a;
        input [15:0] op_b;
        begin
            a      = op_a;
            b      = op_b;
            mac_en  = 1;
            mac_clr = 0;
            @(posedge clk);
            #1;
        end
    endtask

    // Task: limpa o acumulador
    task do_clr;
        begin
            mac_clr = 1;
            mac_en  = 0;
            @(posedge clk);
            #1;
            mac_clr = 0;
        end
    endtask

    // Task: aplica reset
    task do_reset;
        begin
            rst_n = 0;
            @(posedge clk);
            #1;
            rst_n = 1;
            mac_en  = 0;
            mac_clr = 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Sequência de testes
    // -------------------------------------------------------------------------
    initial begin
        // Inicialização
        errors  = 0;
        rst_n   = 0;
        mac_en  = 0;
        mac_clr = 0;
        a       = 16'h0;
        b       = 16'h0;

        // Libera reset após 2 ciclos
        repeat(2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=============================================================");
        $display("  Testbench mac_unit.v — TEC 499 · UEFS 2026.1 · Marco 1");
        $display("=============================================================");

        // -----------------------------------------------------------------
        // TC01 — 0 × 0 = 0
        // Esperado: acc_out = 0x0000, overflow = 0
        // -----------------------------------------------------------------
        mac_op(Q_ZERO, Q_ZERO);
        check(16'h0000, 1'b0, 1, "0.0 * 0.0 = 0.0");
        do_reset;

        // -----------------------------------------------------------------
        // TC02 — 1.0 × 1.0 = 1.0
        // Q4.12: 0x1000 * 0x1000 → produto[27:12] = 0x1000
        // Esperado: acc_out = 0x1000, overflow = 0
        // -----------------------------------------------------------------
        mac_op(Q_ONE, Q_ONE);
        check(16'h1000, 1'b0, 2, "1.0 * 1.0 = 1.0");
        do_reset;

        // -----------------------------------------------------------------
        // TC03 — Overflow positivo: 7.999 × 7.999 → clamp 0x7FFF
        // Q4.12: 0x7FFB * 0x7FFB é muito maior que 7.999 — deve saturar
        // Esperado: acc_out = 0x7FFF, overflow = 1
        // -----------------------------------------------------------------
        mac_op(Q_POS_MAX, Q_POS_MAX);
        check(16'h7FFF, 1'b1, 3, "MAX_POS * MAX_POS → clamp 0x7FFF");
        do_reset;

        // -----------------------------------------------------------------
        // TC04 — Overflow negativo: -8.0 × 7.999 → clamp 0x8000
        // Esperado: acc_out = 0x8000, overflow = 1
        // -----------------------------------------------------------------
        mac_op(Q_NEG_MAX, Q_POS_MAX);
        check(16'h8000, 1'b1, 4, "MIN_NEG * MAX_POS → clamp 0x8000");
        do_reset;

        // -----------------------------------------------------------------
        // TC05 — Sequência: acumula 1.0 + 1.0 = 2.0, depois clr, acumula 0.5
        // Valida que mac_clr zera acc_out E o acumulador interno
        // Esperado pós-clr: acc_out = 0x0000
        // Esperado pós-acumulação: acc_out = 0x0800 (0.5)
        // -----------------------------------------------------------------
        // Acumula duas vezes 1.0 × 1.0
        mac_op(Q_ONE, Q_ONE);
        mac_op(Q_ONE, Q_ONE);
        // Limpa
        do_clr;
        check(16'h0000, 1'b0, 5, "Acumula 2x depois clr → acc_out deve ser 0x0000");
        // Acumula 0.5 × 1.0 = 0.5 (parting do zero)
        mac_op(Q_HALF, Q_ONE);
        check(16'h0800, 1'b0, 5, "Pós-clr: 0.5 * 1.0 = 0.5 (0x0800)");
        do_reset;

        // -----------------------------------------------------------------
        // TC06 — Dois negativos: -1.0 × -1.0 = +1.0
        // Q4.12: 0xF000 * 0xF000 → produto signed = +4096 em Q8.24
        //        bits[27:12] = 0x1000 = +1.0 em Q4.12
        // Esperado: acc_out = 0x1000, overflow = 0
        // -----------------------------------------------------------------
        mac_op(Q_NEG_ONE, Q_NEG_ONE);
        check(16'h1000, 1'b0, 6, "(-1.0) * (-1.0) = +1.0 (0x1000)");
        do_reset;

        // -----------------------------------------------------------------
        // TC07 — Reset no meio de uma acumulação
        // Acumula 1.0, aplica reset, verifica que acc_out volta a 0
        // Esperado pós-reset: acc_out = 0x0000
        // -----------------------------------------------------------------
        mac_op(Q_ONE, Q_ONE);   // acc = 1.0
        do_reset;
        check(16'h0000, 1'b0, 7, "Reset durante acumulação → acc_out = 0x0000");

        // -----------------------------------------------------------------
        // TC08 — mac_en=0 não altera o acumulador
        // Acumula 1.0, depois desabilita mac_en, verifica que acc não muda
        // -----------------------------------------------------------------
        mac_op(Q_ONE, Q_ONE);   // acc = 1.0
        // Ciclo com mac_en=0, a e b com valores diferentes
        a      = Q_TWO;
        b      = Q_TWO;
        mac_en = 0;
        @(posedge clk);
        check(16'h1000, 1'b0, 8, "mac_en=0 não altera acc (deve manter 0x1000)");
        do_reset;

        // -----------------------------------------------------------------
        // TC09 — Acumulação múltipla sem overflow: 4 × (0.5 × 1.0) = 2.0
        // Esperado: acc_out = 0x2000
        // -----------------------------------------------------------------
        mac_op(Q_HALF, Q_ONE);  // +0.5
        mac_op(Q_HALF, Q_ONE);  // +1.0
        mac_op(Q_HALF, Q_ONE);  // +1.5
        mac_op(Q_HALF, Q_ONE);  // +2.0
        check(16'h2000, 1'b0, 9, "4x (0.5*1.0) = 2.0 (0x2000)");
        do_reset;

        // -----------------------------------------------------------------
        // TC10 — mac_clr zera acc_out (não mantém valor anterior)
        // Acumula 2.0, aplica clr, verifica que acc_out = 0x0000
        // -----------------------------------------------------------------
        mac_op(Q_TWO, Q_ONE);  // acc = 2.0
        do_clr;
        check(16'h0000, 1'b0, 10, "mac_clr zera acc_out completamente");
        do_reset;

        // -----------------------------------------------------------------
        // Resultado final
        // -----------------------------------------------------------------
        $display("=============================================================");
        if (errors == 0)
            $display("  RESULTADO FINAL: TODOS OS TESTES PASSARAM (0 erros)");
        else
            $display("  RESULTADO FINAL: %0d TESTE(S) FALHARAM", errors);
        $display("=============================================================");

        $finish;
    end

    // -------------------------------------------------------------------------
    // Dump de waveform para visualização no GTKWave / ModelSim
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_mac.vcd");
        $dumpvars(0, tb_mac);
    end

    // -------------------------------------------------------------------------
    // Timeout de segurança: aborta simulação se travar
    // -------------------------------------------------------------------------
    initial begin
        #100000;
        $display("[TIMEOUT] Simulação abortada por timeout.");
        $finish;
    end

endmodule
