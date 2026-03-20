// =============================================================================
// Testbench: tb_reg_bank.v
// Módulo sob teste: reg_bank.v
// Referência: test_spec_fsm_regbank.md — Módulo 1 (TC-REG-01 a TC-REG-10)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_reg_bank tb_reg_bank.v reg_bank.v && vvp tb_reg_bank
// =============================================================================

`timescale 1ns/1ps

module tb_reg_bank;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg         clk;
    reg         rst_n;
    reg  [31:0] addr;
    reg         write_en;
    reg         read_en;
    reg  [31:0] data_in;

    // Sinais de status (entradas do reg_bank vindas da FSM)
    reg   [1:0] status_in;
    reg   [3:0] pred_in;
    reg  [31:0] cycles_in;

    // Saídas do DUT
    wire [31:0] data_out;
    wire        start_out;
    wire        reset_out;
    wire  [9:0] pixel_addr;
    wire  [7:0] pixel_data;
    wire        we_img_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    reg_bank dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (addr),
        .write_en   (write_en),
        .read_en    (read_en),
        .data_in    (data_in),
        .status_in  (status_in),
        .pred_in    (pred_in),
        .cycles_in  (cycles_in),
        .data_out   (data_out),
        .start_out  (start_out),
        .reset_out  (reset_out),
        .pixel_addr (pixel_addr),
        .pixel_data (pixel_data),
        .we_img_out (we_img_out)
    );

    // -------------------------------------------------------------------------
    // Geração de clock: período de 10 ns (100 MHz)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Task: verifica sinal de 32 bits
    // -------------------------------------------------------------------------
    task check32;
        input [63:0]  tc_num;
        input [255:0] label;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-REG-%0d | %s got=0x%08X exp=0x%08X",
                         tc_num, label, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-REG-%0d | %s got=0x%08X exp=0x%08X  <---",
                         tc_num, label, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: verifica sinal de 1 bit
    // -------------------------------------------------------------------------
    task check1;
        input [63:0]  tc_num;
        input [255:0] label;
        input         got;
        input         exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-REG-%0d | %s got=%b exp=%b",
                         tc_num, label, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-REG-%0d | %s got=%b exp=%b  <---",
                         tc_num, label, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: aplica reset assíncrono
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            rst_n = 1;
            @(posedge clk); #1;
        end
    endtask

    // =========================================================================
    // Sequência principal de testes
    // =========================================================================
    initial begin
        // Inicialização de todos os sinais
        pass_count = 0;
        fail_count = 0;
        rst_n      = 1;
        write_en   = 0;
        read_en    = 0;
        addr       = 0;
        data_in    = 0;
        status_in  = 2'b00;
        pred_in    = 4'd0;
        cycles_in  = 32'd0;
        #3;

        $display("=============================================================");
        $display(" tb_reg_bank — Iniciando testes (TC-REG-01 a TC-REG-10)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-REG-01 — Reset assíncrono limpa todos os registradores
        //
        // O reset deve zerar start_out, reset_out, we_img_out e data_out
        // independentemente do que havia antes.
        // É o primeiro teste pois um reset defeituoso invalida todos os outros.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-01: reset assíncrono --");

        // Força alguns valores antes do reset
        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'hFFFFFFFF;
        @(posedge clk); #1;
        write_en = 0;

        // Aplica reset
        do_reset;

        // Verifica que tudo foi zerado
        check1(1, "start_out", start_out, 1'b0);
        check1(1, "reset_out", reset_out, 1'b0);
        check1(1, "we_img_out", we_img_out, 1'b0);

        // ---------------------------------------------------------------------
        // TC-REG-02 — Escrita em CTRL[0] gera start_out=1
        //
        // data_in=0x01 seta bit[0]=start.
        // data_in=0x00 limpa bit[0]=start.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-02: CTRL[0] -> start_out --");
        do_reset;

        // Escreve start=1
        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'h00000001;
        @(posedge clk); #1;
        write_en = 0;
        check1(2, "start_out=1", start_out, 1'b1);

        // Limpa start
        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'h00000000;
        @(posedge clk); #1;
        write_en = 0;
        check1(2, "start_out=0", start_out, 1'b0);

        // ---------------------------------------------------------------------
        // TC-REG-03 — Escrita em CTRL[1] gera reset_out=1
        //
        // data_in=0x02 seta bit[1]=reset.
        // Verifica independência de start_out (deve permanecer 0).
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-03: CTRL[1] -> reset_out --");
        do_reset;

        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'h00000002;
        @(posedge clk); #1;
        write_en = 0;
        check1(3, "reset_out=1", reset_out, 1'b1);
        check1(3, "start_out=0", start_out, 1'b0);   // start não deve ser afetado

        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'h00000000;
        @(posedge clk); #1;
        write_en = 0;
        check1(3, "reset_out=0", reset_out, 1'b0);

        // ---------------------------------------------------------------------
        // TC-REG-04 — Escrita em IMG gera pixel_addr, pixel_data e we_img_out
        //
        // Empacotamento: data_in[9:0]=pixel_addr, data_in[17:10]=pixel_data
        // Exemplo: addr=100 (0x64), dado=200 (0xC8)
        //   data_in = {14'b0, 8'hC8, 10'h064} = 32'h00032064
        //
        // Por que esse empacotamento?
        // O barramento MMIO transfere 32 bits por vez. Empacotar endereço
        // e dado juntos permite carregar um pixel com uma única escrita,
        // dobrando o throughput em relação a dois acessos separados.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-04: IMG -> pixel_addr, pixel_data, we_img_out --");
        do_reset;

        @(posedge clk); #1;
        // pixel_addr=100=0x64, pixel_data=200=0xC8
        // data_in = {14'b0, 8'hC8, 10'h064}
        write_en = 1;
        addr     = 32'h08;
        data_in  = {14'b0, 8'hC8, 10'h064};   // 32'h00032064
        @(posedge clk); #1;
        write_en = 0;

        // Verifica campos extraídos
        if (pixel_addr === 10'h064) begin
            $display("  PASS  TC-REG-04 | pixel_addr got=0x%03X exp=0x064", pixel_addr);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-REG-04 | pixel_addr got=0x%03X exp=0x064  <---", pixel_addr);
            fail_count = fail_count + 1;
        end

        if (pixel_data === 8'hC8) begin
            $display("  PASS  TC-REG-04 | pixel_data got=0x%02X exp=0xC8", pixel_data);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-REG-04 | pixel_data got=0x%02X exp=0xC8  <---", pixel_data);
            fail_count = fail_count + 1;
        end

        check1(4, "we_img_out=1", we_img_out, 1'b1);

        // ---------------------------------------------------------------------
        // TC-REG-05 — we_img_out dura exatamente 1 ciclo
        //
        // we_img_out deve voltar a 0 automaticamente no ciclo seguinte.
        // Se persistir, a ram_img receberia múltiplas escritas para o
        // mesmo pixel, corrompendo a contagem da FSM.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-05: we_img_out pulsa por exatamente 1 ciclo --");

        // No ciclo anterior já verificamos we_img_out=1
        // Agora verificamos que voltou a 0
        @(posedge clk); #1;
        check1(5, "we_img_out=0 ciclo+1", we_img_out, 1'b0);

        @(posedge clk); #1;
        check1(5, "we_img_out=0 ciclo+2", we_img_out, 1'b0);

        // ---------------------------------------------------------------------
        // TC-REG-06 — Leitura de STATUS retorna campo correto
        //
        // STATUS[1:0] = status_in, STATUS[5:2] = pred_in
        // Forçamos status_in=DONE (2'b10) e pred_in=7
        // Valor esperado: {26'b0, 4'd7, 2'b10} = 0x0000001E
        //
        // Cálculo:
        //   bits[1:0] = 2'b10 = 2
        //   bits[5:2] = 4'd7  = 7 << 2 = 28 = 0x1C
        //   total = 0x1C | 0x02 = 0x1E = 30
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-06: leitura STATUS --");
        do_reset;

        status_in = 2'b10;   // DONE
        pred_in   = 4'd7;    // dígito 7

        @(posedge clk); #1;
        read_en = 1; addr = 32'h04;
        #1;   // lógica combinacional — resultado imediato
        check32(6, "STATUS", data_out, 32'h0000001E);
        read_en = 0;

        // ---------------------------------------------------------------------
        // TC-REG-07 — Leitura de RESULT retorna pred correto
        //
        // RESULT[3:0] = pred_in, bits altos = 0
        // Forçamos pred_in=9 → data_out esperado = 0x00000009
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-07: leitura RESULT --");

        pred_in = 4'd9;

        @(posedge clk); #1;
        read_en = 1; addr = 32'h0C;
        #1;
        check32(7, "RESULT", data_out, 32'h00000009);
        read_en = 0;

        // ---------------------------------------------------------------------
        // TC-REG-08 — Leitura de CYCLES retorna contador correto
        //
        // CYCLES é passado integralmente de cycles_in para data_out.
        // Verifica que não há truncamento nos 32 bits.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-08: leitura CYCLES --");

        cycles_in = 32'h000003E8;   // 1000 ciclos

        @(posedge clk); #1;
        read_en = 1; addr = 32'h10;
        #1;
        check32(8, "CYCLES", data_out, 32'h000003E8);
        read_en = 0;

        // ---------------------------------------------------------------------
        // TC-REG-09 — Leitura em endereço inválido retorna zero
        //
        // Qualquer endereço não mapeado deve retornar 0x00000000.
        // Retornar lixo poderia fazer o ARM interpretar STATUS errado.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-09: leitura em endereco invalido --");

        @(posedge clk); #1;
        read_en = 1; addr = 32'hFF;
        #1;
        check32(9, "addr_invalido", data_out, 32'h00000000);
        read_en = 0;

        // ---------------------------------------------------------------------
        // TC-REG-10 — Escrita em endereço inválido não afeta registradores
        //
        // Escreve valores conhecidos em CTRL, depois tenta corromper
        // com escrita em endereço inválido, e verifica que CTRL não mudou.
        // ---------------------------------------------------------------------
        $display("\n-- TC-REG-10: escrita em endereco invalido nao corrompe --");
        do_reset;

        // Escreve start=1 em CTRL
        @(posedge clk); #1;
        write_en = 1; addr = 32'h00; data_in = 32'h00000001;
        @(posedge clk); #1;
        write_en = 0;
        // start_out deve ser 1 agora

        // Tenta escrever em endereço inválido
        @(posedge clk); #1;
        write_en = 1; addr = 32'hAA; data_in = 32'hDEADBEEF;
        @(posedge clk); #1;
        write_en = 0;

        // Verifica que start_out ainda é 1 (não foi corrompido)
        check1(10, "start_out_preservado", start_out, 1'b1);

        // Verifica que we_img_out continua 0 (não foi ativado)
        check1(10, "we_img_out_preservado", we_img_out, 1'b0);

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
        $dumpfile("tb_reg_bank.vcd");
        $dumpvars(0, tb_reg_bank);
    end

endmodule
