// =============================================================================
// Testbench: tb_fsm_ctrl.v
// Módulo sob teste: fsm_ctrl.v
// Referência: test_spec_fsm_regbank.md — Módulo 2 (TC-FSM-01 a TC-FSM-18)
//
// ESTRATÉGIA DE SIMULAÇÃO:
// Simular 100.352 ciclos de CALC_HIDDEN seria muito lento.
// Este testbench usa parâmetros reduzidos para acelerar a simulação:
//   N_NEURONS = 4   (em vez de 128)
//   N_PIXELS  = 8   (em vez de 784)
//   N_CLASSES = 3   (em vez de 10)
// Os testes de transição são válidos com qualquer dimensão.
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_fsm_ctrl tb_fsm_ctrl.v fsm_ctrl.v && vvp tb_fsm_ctrl
// =============================================================================

`timescale 1ns/1ps

module tb_fsm_ctrl;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg        clk;
    reg        rst_n;
    reg        start;
    reg        reset;
    reg        we_img;
    reg        overflow;
    reg        argmax_done;
    reg  [3:0] max_idx;

    // Saídas do DUT
    wire        we_img_fsm;
    wire  [9:0] addr_img;
    wire        we_hidden;
    wire  [6:0] addr_hidden;
    wire [16:0] addr_w;
    wire  [6:0] addr_bias;
    wire [10:0] addr_beta;
    wire        mac_en;
    wire        mac_clr;
    wire        h_capture;
    wire        argmax_en;
    wire  [1:0] status_out;
    wire  [3:0] result_out;
    wire [31:0] cycles_out;
    wire        done_out;

    // Acesso interno ao estado atual (para verificação nos testes)
    wire  [2:0] current_state;
    assign current_state = dut.current_state;

    // -------------------------------------------------------------------------
    // Parâmetros de estado (espelham os localparam do DUT)
    // -------------------------------------------------------------------------
    localparam IDLE        = 3'd0;
    localparam LOAD_IMG    = 3'd1;
    localparam CALC_HIDDEN = 3'd2;
    localparam CALC_OUTPUT = 3'd3;
    localparam ARGMAX      = 3'd4;
    localparam DONE        = 3'd5;
    localparam ERROR       = 3'd6;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer cycle_count;

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    fsm_ctrl dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .reset       (reset),
        .we_img      (we_img),
        .overflow    (overflow),
        .argmax_done (argmax_done),
        .max_idx     (max_idx),
        .we_img_fsm  (we_img_fsm),
        .addr_img    (addr_img),
        .we_hidden   (we_hidden),
        .addr_hidden (addr_hidden),
        .addr_w      (addr_w),
        .addr_bias   (addr_bias),
        .addr_beta   (addr_beta),
        .mac_en      (mac_en),
        .mac_clr     (mac_clr),
        .h_capture   (h_capture),
        .argmax_en   (argmax_en),
        .status_out  (status_out),
        .result_out  (result_out),
        .cycles_out  (cycles_out),
        .done_out    (done_out)
    );

    // -------------------------------------------------------------------------
    // Geração de clock: período de 10 ns (100 MHz)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Tasks auxiliares
    // -------------------------------------------------------------------------
    task check_state;
        input [63:0]  tc_num;
        input [2:0]   got;
        input [2:0]   exp;
        input [127:0] label;
        begin
            if (got === exp) begin
                $display("  PASS  TC-FSM-%0d | %s estado=%0d", tc_num, label, got);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-FSM-%0d | %s got=%0d exp=%0d  <---",
                         tc_num, label, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check1;
        input [63:0]  tc_num;
        input [127:0] label;
        input         got;
        input         exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-FSM-%0d | %s got=%b exp=%b", tc_num, label, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-FSM-%0d | %s got=%b exp=%b  <---",
                         tc_num, label, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_val;
        input [63:0]  tc_num;
        input [127:0] label;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-FSM-%0d | %s got=%0d exp=%0d", tc_num, label, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-FSM-%0d | %s got=%0d exp=%0d  <---",
                         tc_num, label, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_reset;
        begin
            rst_n = 0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1;
            @(posedge clk); #1;
        end
    endtask

    // Task: avança a FSM até um estado alvo (máx 200.000 ciclos)
    task wait_for_state;
        input [2:0] target;
        integer timeout;
        begin
            timeout = 0;
            while (current_state !== target && timeout < 200000) begin
                @(posedge clk); #1;
                timeout = timeout + 1;
            end
            if (timeout >= 200000)
                $display("  WARN  wait_for_state: timeout aguardando estado %0d", target);
        end
    endtask

    // Task: avança N ciclos de clock
    task tick;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    // =========================================================================
    // Sequência principal de testes
    // =========================================================================
    initial begin
        pass_count   = 0;
        fail_count   = 0;
        rst_n        = 1;
        start        = 0;
        reset        = 0;
        we_img       = 0;
        overflow     = 0;
        argmax_done  = 0;
        max_idx      = 0;
        #3;

        $display("=============================================================");
        $display(" tb_fsm_ctrl — Iniciando testes (TC-FSM-01 a TC-FSM-18)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-FSM-01 — Reset assíncrono leva ao estado IDLE
        //
        // Verifica estado inicial e que todos os controles estão em 0.
        // Base de todos os outros testes.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-01: reset assíncrono → IDLE --");
        do_reset;
        check_state(1, current_state, IDLE, "estado");
        check1(1, "mac_en=0",    mac_en,     1'b0);
        check1(1, "we_img_fsm=0",we_img_fsm, 1'b0);
        check1(1, "we_hidden=0", we_hidden,  1'b0);
        check1(1, "argmax_en=0", argmax_en,  1'b0);

        // ---------------------------------------------------------------------
        // TC-FSM-02 — IDLE permanece em IDLE sem start
        //
        // A FSM não deve avançar espontaneamente.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-02: IDLE permanece sem start --");
        do_reset;
        tick(10);
        check_state(2, current_state, IDLE, "apos_10_ciclos");

        // ---------------------------------------------------------------------
        // TC-FSM-03 — IDLE → LOAD_IMG quando start=1
        //
        // Um único pulso de start=1 deve iniciar o carregamento.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-03: IDLE → LOAD_IMG com start=1 --");
        do_reset;

        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        check_state(3, current_state, LOAD_IMG, "apos_start");

        // ---------------------------------------------------------------------
        // TC-FSM-04 — LOAD_IMG: we_img_fsm=1 e addr_img=j incrementando
        //
        // Verifica que a FSM ativa a escrita na ram_img e que o endereço
        // incrementa corretamente nos primeiros ciclos.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-04: LOAD_IMG sinais corretos --");
        do_reset;

        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        // Agora em LOAD_IMG

        // Verifica os primeiros 4 ciclos
        begin : check_load
            integer c;
            for (c = 0; c < 4; c = c + 1) begin
                check1(4, "we_img_fsm", we_img_fsm, 1'b1);
                if (addr_img === c[9:0]) begin
                    $display("  PASS  TC-FSM-04 | addr_img=%0d exp=%0d", addr_img, c);
                    pass_count = pass_count + 1;
                end else begin
                    $display("  FAIL  TC-FSM-04 | addr_img=%0d exp=%0d  <---", addr_img, c);
                    fail_count = fail_count + 1;
                end
                @(posedge clk); #1;
            end
        end

        // ---------------------------------------------------------------------
        // TC-FSM-05 — LOAD_IMG → CALC_HIDDEN após 784 pixels
        //
        // A FSM deve permanecer em LOAD_IMG por exatamente 784 ciclos.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-05: LOAD_IMG → CALC_HIDDEN apos 784 ciclos --");
        do_reset;

        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // Avança 782 ciclos (deve ainda estar em LOAD_IMG)
        tick(782);
        check_state(5, current_state, LOAD_IMG, "ciclo_783");

        // Próximo ciclo: deve transicionar para CALC_HIDDEN
        @(posedge clk); #1;
        check_state(5, current_state, CALC_HIDDEN, "ciclo_784");

        // ---------------------------------------------------------------------
        // TC-FSM-06 — CALC_HIDDEN: mac_en=1 e endereços corretos
        //
        // Verifica que mac_en está ativo e que addr_w={i,j} incrementa.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-06: CALC_HIDDEN mac_en e enderecos --");
        // Já estamos em CALC_HIDDEN do teste anterior

        check1(6, "mac_en=1", mac_en, 1'b1);
        check_state(6, current_state, CALC_HIDDEN, "estado");

        // Verifica addr_w = {i=0, j=0} no início
        if (addr_w === {7'd0, 10'd0}) begin
            $display("  PASS  TC-FSM-06 | addr_w={0,0} correto");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-06 | addr_w=0x%05X exp={0,0}  <---", addr_w);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // TC-FSM-07 — CALC_HIDDEN: mac_clr e we_hidden ao fim de cada neurônio
        //
        // No ciclo j=783 de cada neurônio, mac_clr e we_hidden devem pulsar.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-07: mac_clr e we_hidden ao fim do neuronio --");
        // Ainda em CALC_HIDDEN, j está em 0 (reiniciou)
        // Avança até j=783 (783 ciclos)
        tick(782);   // j vai de 1 até 782
        @(posedge clk); #1;   // j=783 — fim do neurônio 0

        check1(7, "mac_clr=1",   mac_clr,   1'b1);
        check1(7, "we_hidden=1", we_hidden, 1'b1);
        check1(7, "h_capture=1", h_capture, 1'b1);

        // No ciclo seguinte, esses sinais devem voltar a 0
        @(posedge clk); #1;
        check1(7, "mac_clr=0 ciclo+1",   mac_clr,   1'b0);
        check1(7, "we_hidden=0 ciclo+1", we_hidden, 1'b0);

        // ---------------------------------------------------------------------
        // TC-FSM-08 — CALC_HIDDEN → CALC_OUTPUT após todos os neurônios
        //
        // Com os parâmetros reais (128×784), esperaríamos 100.352 ciclos.
        // Aqui usamos wait_for_state para aguardar a transição.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-08: CALC_HIDDEN → CALC_OUTPUT --");
        wait_for_state(CALC_OUTPUT);
        check_state(8, current_state, CALC_OUTPUT, "transicao");

        // ---------------------------------------------------------------------
        // TC-FSM-09 — CALC_OUTPUT: endereços rom_beta e ram_hidden corretos
        //
        // mac_en=1, addr_beta={k=0, i} incrementando.
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-09: CALC_OUTPUT enderecos corretos --");
        check1(9, "mac_en=1", mac_en, 1'b1);

        if (addr_beta === {4'd0, 7'd0}) begin
            $display("  PASS  TC-FSM-09 | addr_beta={0,0} correto");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-09 | addr_beta=0x%03X exp={0,0}  <---", addr_beta);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // TC-FSM-10 — CALC_OUTPUT → ARGMAX após 10 classes
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-10: CALC_OUTPUT → ARGMAX --");
        wait_for_state(ARGMAX);
        check_state(10, current_state, ARGMAX, "transicao");
        check1(10, "argmax_en=1", argmax_en, 1'b1);

        // ---------------------------------------------------------------------
        // TC-FSM-11 — ARGMAX → DONE quando argmax_done=1
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-11: ARGMAX → DONE com argmax_done=1 --");

        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd7;
        @(posedge clk); #1;
        argmax_done = 0;
        check_state(11, current_state, DONE, "transicao");

        // ---------------------------------------------------------------------
        // TC-FSM-12 — DONE: done_out=1 e result correto
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-12: DONE sinais corretos --");
        check1(12, "done_out=1", done_out, 1'b1);
        if (status_out === 2'b10) begin
            $display("  PASS  TC-FSM-12 | STATUS=DONE");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-12 | STATUS got=%b exp=10  <---", status_out);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // TC-FSM-13 — DONE → IDLE automaticamente após 1 ciclo
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-13: DONE → IDLE automatico --");
        @(posedge clk); #1;
        check_state(13, current_state, IDLE, "apos_done");

        // ---------------------------------------------------------------------
        // TC-FSM-14 — ERROR: overflow leva ao estado ERROR
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-14: overflow → ERROR --");
        do_reset;

        // Inicia inferência e vai para CALC_HIDDEN
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(CALC_HIDDEN);

        // Força overflow
        @(posedge clk); #1;
        overflow = 1;
        @(posedge clk); #1;
        overflow = 0;
        check_state(14, current_state, ERROR, "apos_overflow");

        if (status_out === 2'b11) begin
            $display("  PASS  TC-FSM-14 | STATUS=ERROR");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-14 | STATUS got=%b exp=11  <---", status_out);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // TC-FSM-15 — ERROR → IDLE via reset externo
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-15: ERROR → IDLE via reset --");
        // Ainda em ERROR do teste anterior

        @(posedge clk); #1;
        reset = 1;
        @(posedge clk); #1;
        reset = 0;
        check_state(15, current_state, IDLE, "apos_reset");

        // ---------------------------------------------------------------------
        // TC-FSM-16 — Contador CYCLES incrementa e congela em DONE
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-16: contador CYCLES --");
        do_reset;

        // Verifica que cycles=0 em IDLE
        check_val(16, "cycles_idle", cycles_out, 32'd0);

        // Inicia inferência
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // Avança alguns ciclos e verifica que cycles está incrementando
        tick(10);
        if (cycles_out > 0) begin
            $display("  PASS  TC-FSM-16 | cycles incrementando: %0d", cycles_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-16 | cycles nao incrementou  <---");
            fail_count = fail_count + 1;
        end

        // Vai até DONE e verifica que cycles congela
        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        @(posedge clk); #1;
        argmax_done = 0;
        // Agora em DONE
        begin : check_cycles_freeze
            reg [31:0] cycles_at_done;
            cycles_at_done = cycles_out;
            @(posedge clk); #1;   // DONE → IDLE
            @(posedge clk); #1;   // em IDLE
            check_val(16, "cycles_congelado", cycles_out, cycles_at_done);
        end

        // ---------------------------------------------------------------------
        // TC-FSM-17 — Duas inferências consecutivas sem contaminação
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-17: duas inferencias consecutivas --");
        do_reset;

        // Primeira inferência
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd3;    // primeira inferência → dígito 3
        @(posedge clk); #1;
        argmax_done = 0;
        // DONE → IDLE automático

        @(posedge clk); #1;
        check_state(17, current_state, IDLE, "volta_idle");

        // Segunda inferência
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd8;    // segunda inferência → dígito 8
        @(posedge clk); #1;
        argmax_done = 0;
        // Em DONE
        check_val(17, "result_segunda", result_out, 32'd8);

        // ---------------------------------------------------------------------
        // TC-FSM-18 — Reset no meio de CALC_HIDDEN aborta → IDLE
        // ---------------------------------------------------------------------
        $display("\n-- TC-FSM-18: reset no meio de CALC_HIDDEN --");
        do_reset;

        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(CALC_HIDDEN);

        // Avança alguns ciclos dentro de CALC_HIDDEN
        tick(300);

        // Reset no meio da operação
        @(posedge clk); #1;
        reset = 1;
        @(posedge clk); #1;
        reset = 0;

        check_state(18, current_state, IDLE, "abort_reset");
        check1(18, "mac_en=0",    mac_en,    1'b0);
        check1(18, "we_hidden=0", we_hidden, 1'b0);

        // Verifica que contadores foram zerados
        if (dut.i === 7'd0 && dut.j === 10'd0 && dut.k === 4'd0) begin
            $display("  PASS  TC-FSM-18 | contadores zerados i=0 j=0 k=0");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-18 | contadores i=%0d j=%0d k=%0d  <---",
                     dut.i, dut.j, dut.k);
            fail_count = fail_count + 1;
        end

        // =====================================================================
        // Relatório final
        // =====================================================================
        $display("\n=============================================================");
        $display(" RESULTADO FINAL");
        $display("   PASS : %0d", pass_count);
        $display("   FAIL : %0d", fail_count);
        $display("   TOTAL: %0d", pass_count + fail_count);
        if (fail_count == 0)
            $display(" >> TODOS OS TESTES PASSARAM <<");
        else
            $display(" >> ATENCAO: %0d TESTE(S) FALHARAM <<", fail_count);
        $display("=============================================================");

        $finish;
    end

    // -------------------------------------------------------------------------
    // Dump de waveform para GTKWave
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_fsm_ctrl.vcd");
        $dumpvars(0, tb_fsm_ctrl);
    end

endmodule
