// =============================================================================
// Testbench: tb_fsm_ctrl.v
// Módulo sob teste: fsm_ctrl.v
// Referência: test_spec_fsm_regbank.md — Módulo 2 (TC-FSM-01 a TC-FSM-18)
//
// ESTRATÉGIA DE SIMULAÇÃO:
// Este testbench instancia fsm_ctrl com parâmetros reduzidos para simular
// transições completas sem esperar 100k+ ciclos:
//   N_PIXELS  = 8   (em vez de 784)
//   N_NEURONS = 4   (em vez de 128)
//   N_CLASSES = 3   (em vez de 10)
//
// Impacto nos ciclos totais com parâmetros reduzidos:
//   LOAD_IMG   :  8  ciclos
//   CALC_HIDDEN:  4 neurônios × 11 ciclos/neurônio =  44 ciclos
//   CALC_OUTPUT:  3 classes   ×  6 ciclos/classe   =  18 ciclos
//   ARGMAX     : depende de argmax_done (controlado pelo TB)
//   TOTAL      : ~70 ciclos vs ~103.000 com parâmetros reais
//
// Testes modificados em relação à versão anterior:
//   TC-FSM-05 — tick ajustado para N_PIXELS=8 (tick(7) em vez de tick(783))
//   TC-FSM-06 — adicionado check do ciclo de warmup (mac_en=0 em j=0)
//   TC-FSM-07 — tick ajustado; adicionado check de bias_cycle; sequência
//               agora cobre warmup → acumulação → bias → capture+clear
//   TC-FSM-09 — adicionado check do ciclo de warmup (mac_en=0 em i=0)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_fsm_ctrl tb_fsm_ctrl.v fsm_ctrl.v && vvp tb_fsm_ctrl
// =============================================================================

`timescale 1ns/1ps

module tb_fsm_ctrl;

    // =========================================================================
    // Parâmetros reduzidos — ALTERE APENAS AQUI para mudar a dimensão do teste
    // =========================================================================
    localparam P_PIXELS  = 8;
    localparam P_NEURONS = 4;
    localparam P_CLASSES = 3;

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
    wire        bias_cycle;    // NOVO: sinal de ciclo de bias
    wire        h_capture;
    wire        argmax_en;
    wire  [1:0] status_out;
    wire  [3:0] result_out;
    wire [31:0] cycles_out;
    wire        done_out;

    // Acesso interno ao estado e contadores (para verificação)
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

    // -------------------------------------------------------------------------
    // Instância do DUT com parâmetros reduzidos
    // -------------------------------------------------------------------------
    fsm_ctrl #(
        .N_PIXELS  (P_PIXELS),
        .N_NEURONS (P_NEURONS),
        .N_CLASSES (P_CLASSES)
    ) dut (
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
        .bias_cycle  (bias_cycle),
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

    // Avança até o estado alvo (máx 200.000 ciclos)
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

    // Avança N bordas de subida do clock
    task tick;
        input integer n;
        integer kk;
        begin
            for (kk = 0; kk < n; kk = kk + 1)
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
        $display(" Parâmetros: N_PIXELS=%0d  N_NEURONS=%0d  N_CLASSES=%0d",
                 P_PIXELS, P_NEURONS, P_CLASSES);
        $display("=============================================================");

        // =====================================================================
        // TC-FSM-01 — Reset assíncrono leva ao estado IDLE
        // =====================================================================
        $display("\n-- TC-FSM-01: reset assíncrono → IDLE --");
        do_reset;
        check_state(1, current_state, IDLE, "estado");
        check1(1, "mac_en=0",    mac_en,     1'b0);
        check1(1, "we_img_fsm=0",we_img_fsm, 1'b0);
        check1(1, "we_hidden=0", we_hidden,  1'b0);
        check1(1, "argmax_en=0", argmax_en,  1'b0);
        check1(1, "bias_cycle=0",bias_cycle, 1'b0);

        // =====================================================================
        // TC-FSM-02 — IDLE permanece em IDLE sem start
        // =====================================================================
        $display("\n-- TC-FSM-02: IDLE permanece sem start --");
        do_reset;
        tick(10);
        check_state(2, current_state, IDLE, "apos_10_ciclos");

        // =====================================================================
        // TC-FSM-03 — IDLE → LOAD_IMG quando start=1
        // =====================================================================
        $display("\n-- TC-FSM-03: IDLE → LOAD_IMG com start=1 --");
        do_reset;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        check_state(3, current_state, LOAD_IMG, "apos_start");

        // =====================================================================
        // TC-FSM-04 — LOAD_IMG: we_img_fsm=1 e addr_img=j incrementando
        // =====================================================================
        $display("\n-- TC-FSM-04: LOAD_IMG sinais corretos --");
        do_reset;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        // Continua em LOAD_IMG; j=0 após entrar no estado
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

        // =====================================================================
        // TC-FSM-05 — LOAD_IMG → CALC_HIDDEN após N_PIXELS ciclos
        //
        // Com N_PIXELS=8: LOAD_IMG percorre j=0..7 (8 ciclos).
        // Após entrar em LOAD_IMG (j=0), tick(7) leva j até 7.
        // BLOCO 2 vê j==N_PIXELS-1=7 → next_state=CALC_HIDDEN.
        // Após o próximo posedge: state=CALC_HIDDEN, j=0.
        // =====================================================================
        $display("\n-- TC-FSM-05: LOAD_IMG → CALC_HIDDEN após %0d pixels --", P_PIXELS);
        do_reset;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        // Estado: LOAD_IMG, j=0

        tick(P_PIXELS - 1);   // j: 0 → N_PIXELS-1 = 7.  Ainda em LOAD_IMG.
        check_state(5, current_state, LOAD_IMG, "ultimo_pixel_j7");

        @(posedge clk); #1;   // Transição: LOAD_IMG → CALC_HIDDEN, j→0
        check_state(5, current_state, CALC_HIDDEN, "transicao");

        // =====================================================================
        // TC-FSM-06 — CALC_HIDDEN: warmup em j=0 e acumulação em j=1
        //
        // Continua de TC-FSM-05: state=CALC_HIDDEN, j=0 (warmup).
        //
        // MUDANÇA em relação à versão anterior:
        //   Antes: verificava mac_en=1 imediatamente ao entrar no estado.
        //   Agora: j=0 é o ciclo de warmup (mac_en=0).
        //          Avança 1 ciclo para j=1 e verifica mac_en=1.
        // =====================================================================
        $display("\n-- TC-FSM-06: CALC_HIDDEN warmup j=0 e acumulação j=1 --");

        // j=0: warmup
        check_state(6, current_state, CALC_HIDDEN, "estado");
        check1(6, "mac_en=0 warmup j=0",    mac_en,    1'b0);
        check1(6, "bias_cycle=0 warmup j=0",bias_cycle,1'b0);
        if (addr_w === {7'd0, 10'd0}) begin
            $display("  PASS  TC-FSM-06 | addr_w={0,0} correto no warmup");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-06 | addr_w=0x%05X exp={0,0}  <---", addr_w);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;   // j=0→1: inicia acumulação
        check1(6, "mac_en=1 j=1",    mac_en,    1'b1);
        check1(6, "mac_clr=0 j=1",   mac_clr,   1'b0);
        check1(6, "bias_cycle=0 j=1",bias_cycle,1'b0);

        // =====================================================================
        // TC-FSM-07 — CALC_HIDDEN: ciclo de bias e captura+clear ao fim do neurônio
        //
        // Continua de TC-FSM-06: state=CALC_HIDDEN, j=1 (acumulação).
        //
        // Com N_PIXELS=8, a sequência completa do neurônio 0 a partir de j=1:
        //   j=1..8   acumulação (8 pixels)   → tick(N_PIXELS-1) = tick(7)
        //   j=9      bias                    → @posedge → bias_cycle=1
        //   j=10     captura+clear           → @posedge → mac_clr=1, we_hidden=1
        //   j=0      warmup neurônio 1       → @posedge → mac_clr=0
        //
        // MUDANÇA em relação à versão anterior:
        //   Antes: tick(782), depois verificava j=783 com mac_clr+we_hidden.
        //   Agora: tick(7) leva de j=1 a j=8; depois @posedge → j=9 (bias),
        //          depois @posedge → j=10 (capture+clear).
        //   Adicionado: verificação de bias_cycle=1 em j=9.
        // =====================================================================
        $display("\n-- TC-FSM-07: bias_cycle e capture+clear ao fim do neurônio --");
        // Partindo de j=1

        tick(P_PIXELS - 1);   // j: 1 → N_PIXELS = 8  (último pixel)

        @(posedge clk); #1;   // j: 8 → 9  (bias cycle)
        check1(7, "bias_cycle=1 j=N_PIXELS+1", bias_cycle, 1'b1);
        check1(7, "mac_en=1 bias",             mac_en,     1'b1);
        check1(7, "mac_clr=0 bias",            mac_clr,    1'b0);
        check1(7, "we_hidden=0 bias",          we_hidden,  1'b0);

        @(posedge clk); #1;   // j: 9 → 10  (captura+clear)
        check1(7, "mac_clr=1 j=N_PIXELS+2",   mac_clr,   1'b1);
        check1(7, "we_hidden=1 j=N_PIXELS+2", we_hidden, 1'b1);
        check1(7, "h_capture=1 j=N_PIXELS+2", h_capture, 1'b1);
        check1(7, "mac_en=0 j=N_PIXELS+2",    mac_en,    1'b0);
        check1(7, "bias_cycle=0 capture",      bias_cycle,1'b0);

        @(posedge clk); #1;   // j→0, i→1: warmup do próximo neurônio
        check1(7, "mac_clr=0 apos_clear",   mac_clr,   1'b0);
        check1(7, "we_hidden=0 apos_clear", we_hidden, 1'b0);
        check1(7, "mac_en=0 warmup",        mac_en,    1'b0);

        // =====================================================================
        // TC-FSM-08 — CALC_HIDDEN → CALC_OUTPUT após N_NEURONS neurônios
        // =====================================================================
        $display("\n-- TC-FSM-08: CALC_HIDDEN → CALC_OUTPUT --");
        // Com parâmetros reduzidos: 4×11=44 ciclos de CALC_HIDDEN no total.
        // wait_for_state aguarda sem timeout até 200k ciclos.
        wait_for_state(CALC_OUTPUT);
        check_state(8, current_state, CALC_OUTPUT, "transicao");

        // =====================================================================
        // TC-FSM-09 — CALC_OUTPUT: warmup em i=0 e acumulação em i=1
        //
        // Continua de TC-FSM-08: state=CALC_OUTPUT, i=0 (warmup).
        //
        // MUDANÇA em relação à versão anterior:
        //   Antes: verificava mac_en=1 imediatamente ao entrar no estado.
        //   Agora: i=0 é o ciclo de warmup (mac_en=0).
        //          Avança 1 ciclo para i=1 e verifica mac_en=1.
        // =====================================================================
        $display("\n-- TC-FSM-09: CALC_OUTPUT warmup i=0 e acumulação i=1 --");

        // i=0: warmup
        check1(9, "mac_en=0 warmup i=0", mac_en, 1'b0);
        if (addr_beta === 11'd0) begin
            $display("  PASS  TC-FSM-09 | addr_beta=0 correto no warmup (n=0,c=0 → 0*10+0=0)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-09 | addr_beta=%0d exp=0  <---", addr_beta);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;   // i=0→1: inicia acumulação
        check1(9, "mac_en=1 i=1",  mac_en,  1'b1);
        check1(9, "mac_clr=0 i=1", mac_clr, 1'b0);

        // addr_beta em i=1, k=0: 1*10+0 = 10
        if (addr_beta === 11'd10) begin
            $display("  PASS  TC-FSM-09 | addr_beta=10 correto em i=1,k=0 (1*10+0=10)");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-09 | addr_beta=%0d exp=10  <---", addr_beta);
            fail_count = fail_count + 1;
        end

        // =====================================================================
        // TC-FSM-10 — CALC_OUTPUT → ARGMAX após N_CLASSES classes
        // =====================================================================
        $display("\n-- TC-FSM-10: CALC_OUTPUT → ARGMAX --");
        wait_for_state(ARGMAX);
        check_state(10, current_state, ARGMAX, "transicao");
        check1(10, "argmax_en=1", argmax_en, 1'b1);

        // =====================================================================
        // TC-FSM-11 — ARGMAX → DONE quando argmax_done=1
        // =====================================================================
        $display("\n-- TC-FSM-11: ARGMAX → DONE com argmax_done=1 --");
        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd7;
        @(posedge clk); #1;
        argmax_done = 0;
        check_state(11, current_state, DONE, "transicao");

        // =====================================================================
        // TC-FSM-12 — DONE: done_out=1 e result correto
        // =====================================================================
        $display("\n-- TC-FSM-12: DONE sinais corretos --");
        check1(12, "done_out=1", done_out, 1'b1);
        if (status_out === 2'b10) begin
            $display("  PASS  TC-FSM-12 | STATUS=DONE");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-12 | STATUS got=%b exp=10  <---", status_out);
            fail_count = fail_count + 1;
        end
        check_val(12, "result_out", result_out, 32'd7);

        // =====================================================================
        // TC-FSM-13 — DONE → IDLE automaticamente após 1 ciclo
        // =====================================================================
        $display("\n-- TC-FSM-13: DONE → IDLE automático --");
        @(posedge clk); #1;
        check_state(13, current_state, IDLE, "apos_done");

        // =====================================================================
        // TC-FSM-14 — ERROR: overflow da MAC leva ao estado ERROR
        // =====================================================================
        $display("\n-- TC-FSM-14: overflow → ERROR --");
        do_reset;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(CALC_HIDDEN);
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

        // =====================================================================
        // TC-FSM-15 — ERROR → IDLE via reset externo
        // =====================================================================
        $display("\n-- TC-FSM-15: ERROR → IDLE via reset --");
        @(posedge clk); #1;
        reset = 1;
        @(posedge clk); #1;
        reset = 0;
        check_state(15, current_state, IDLE, "apos_reset");

        // =====================================================================
        // TC-FSM-16 — Contador CYCLES incrementa e congela em DONE
        // =====================================================================
        $display("\n-- TC-FSM-16: contador CYCLES --");
        do_reset;
        check_val(16, "cycles_idle", cycles_out, 32'd0);

        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        tick(10);
        if (cycles_out > 0) begin
            $display("  PASS  TC-FSM-16 | cycles incrementando: %0d", cycles_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-FSM-16 | cycles nao incrementou  <---");
            fail_count = fail_count + 1;
        end

        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        @(posedge clk); #1;
        argmax_done = 0;
        begin : check_cycles_freeze
            reg [31:0] cycles_at_done;
            cycles_at_done = cycles_out;
            @(posedge clk); #1;
            @(posedge clk); #1;
            check_val(16, "cycles_congelado", cycles_out, cycles_at_done);
        end

        // =====================================================================
        // TC-FSM-17 — Duas inferências consecutivas: sem contaminação
        // =====================================================================
        $display("\n-- TC-FSM-17: duas inferências consecutivas --");
        do_reset;

        // Primeira inferência — pred=3
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd3;
        @(posedge clk); #1;
        argmax_done = 0;

        @(posedge clk); #1;   // DONE → IDLE
        check_state(17, current_state, IDLE, "volta_idle");

        // Segunda inferência — pred=8
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(ARGMAX);
        @(posedge clk); #1;
        argmax_done = 1;
        max_idx     = 4'd8;
        @(posedge clk); #1;
        argmax_done = 0;
        // Em DONE agora — result_out deve ser 8
        check_val(17, "result_segunda_inferencia", result_out, 32'd8);

        // =====================================================================
        // TC-FSM-18 — Reset no meio de CALC_HIDDEN aborta → IDLE
        // =====================================================================
        $display("\n-- TC-FSM-18: reset no meio de CALC_HIDDEN --");
        do_reset;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait_for_state(CALC_HIDDEN);

        // Avança alguns ciclos dentro de CALC_HIDDEN (seguro: 5 < 44 total)
        tick(5);

        @(posedge clk); #1;
        reset = 1;
        @(posedge clk); #1;
        reset = 0;

        check_state(18, current_state, IDLE, "abort_reset");
        check1(18, "mac_en=0",    mac_en,    1'b0);
        check1(18, "we_hidden=0", we_hidden, 1'b0);
        check1(18, "bias_cycle=0",bias_cycle,1'b0);

        if (dut.i === 0 && dut.j === 0 && dut.k === 0) begin
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
