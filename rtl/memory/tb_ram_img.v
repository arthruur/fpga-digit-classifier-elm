// =============================================================================
// Testbench: tb_ram_img.v
// Módulo sob teste: ram_img.v
// Referência: test_spec_memories.md — Módulo 1 (TC-IMG-01 a TC-IMG-06)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_ram_img tb_ram_img.v ram_img.v && vvp tb_ram_img
//
// Critério de PASS: igualdade bit a bit (===) em todos os casos.
// =============================================================================

`timescale 1ns/1ps

module tb_ram_img;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT (Device Under Test)
    // -------------------------------------------------------------------------
    reg        clk;
    reg        we;
    reg  [9:0] addr;
    reg  [7:0] data_in;
    wire [7:0] data_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Variáveis auxiliares
    // -------------------------------------------------------------------------
    integer i;
    reg [7:0] expected;

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    ram_img dut (
        .clk      (clk),
        .we       (we),
        .addr     (addr),
        .data_in  (data_in),
        .data_out (data_out)
    );

    // -------------------------------------------------------------------------
    // Geração de clock: período de 10 ns (100 MHz)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Task auxiliar: verifica resultado e imprime PASS ou FAIL
    // -------------------------------------------------------------------------
    task check;
        input [63:0] tc_num;       // número do caso de teste
        input [7:0]  got;          // valor obtido
        input [7:0]  exp;          // valor esperado
        input [127:0] label;       // descrição curta (não usada no display)
        begin
            if (got === exp) begin
                $display("  PASS  TC-IMG-%0d | got=0x%02X  exp=0x%02X", tc_num, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-IMG-%0d | got=0x%02X  exp=0x%02X  <---", tc_num, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task auxiliar: avança N ciclos de clock
    // -------------------------------------------------------------------------
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
        // Inicialização
        pass_count = 0;
        fail_count = 0;
        we       = 0;
        addr     = 0;
        data_in  = 0;

        // Aguarda estabilização
        #3;

        $display("=============================================================");
        $display(" tb_ram_img — Iniciando testes (TC-IMG-01 a TC-IMG-06)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-IMG-01 — Escrita e leitura simples no endereço 0
        // Sequência: escreve 0xAB em addr=0, lê no ciclo seguinte,
        // verifica no ciclo+1 (latência 1 ciclo de BRAM síncrona).
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-01: escrita e leitura no addr=0 --");
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd0;
        data_in = 8'hAB;

        @(posedge clk); #1;   // ciclo 2: apresenta endereço para leitura
        we      = 0;
        addr    = 10'd0;

        @(posedge clk); #1;   // ciclo 3: dado disponível na saída
        check(1, data_out, 8'hAB, "addr0");

        // ---------------------------------------------------------------------
        // TC-IMG-02 — Escrita e leitura no endereço máximo (783)
        // Verifica que addr[9:0] cobre corretamente 784 posições.
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-02: escrita e leitura no addr=783 --");
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd783;
        data_in = 8'hFF;

        @(posedge clk); #1;
        we      = 0;
        addr    = 10'd783;

        @(posedge clk); #1;
        check(2, data_out, 8'hFF, "addr783");

        // ---------------------------------------------------------------------
        // TC-IMG-03 — we=0 não sobrescreve dado existente
        // Garante que a memória só escreve quando we=1.
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-03: we=0 nao sobrescreve --");

        // Passo 1: escreve 0x55 em addr=10
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd10;
        data_in = 8'h55;

        // Passo 2: tentativa de sobrescrita com we=0
        @(posedge clk); #1;
        we      = 0;
        addr    = 10'd10;
        data_in = 8'hAA;   // valor que NÃO deve ser gravado

        // Passo 3: lê addr=10 (latência: resultado no próximo ciclo)
        @(posedge clk); #1;
        addr    = 10'd10;

        @(posedge clk); #1;
        check(3, data_out, 8'h55, "we0_nao_sobrescreve");

        // ---------------------------------------------------------------------
        // TC-IMG-04 — Leitura tem latência de exatamente 1 ciclo
        // No ciclo imediatamente após a escrita, data_out ainda não é válido.
        // O PASS é verificado apenas 1 ciclo depois da apresentação do endereço.
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-04: latencia de leitura = 1 ciclo --");

        // Ciclo 1: escreve 0x42 em addr=5
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd5;
        data_in = 8'h42;

        // Ciclo 2: apresenta endereço — dado ainda NÃO disponível
        @(posedge clk); #1;
        we      = 0;
        addr    = 10'd5;
        // (não verifica data_out aqui — comportamento indefinido neste ciclo)

        // Ciclo 3: agora o dado está disponível
        @(posedge clk); #1;
        check(4, data_out, 8'h42, "latencia_1ciclo");

        // ---------------------------------------------------------------------
        // TC-IMG-05 — Escrita sequencial de 784 pixels e verificação por
        // amostragem (posições 0, 100, 391, 500, 783).
        // Padrão: data_in = addr[7:0]
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-05: escrita sequencial de 784 pixels --");

        // Escreve todos os 784 pixels
        for (i = 0; i < 784; i = i + 1) begin
            @(posedge clk); #1;
            we      = 1;
            addr    = i[9:0];
            data_in = i[7:0];   // padrão verificável: valor = índice truncado
        end

        // Desabilita escrita
        @(posedge clk); #1;
        we = 0;

        // Verificação por amostragem — 5 posições representativas
        // Posição 0 → valor esperado 8'h00
        @(posedge clk); #1;
        addr = 10'd0;
        @(posedge clk); #1;
        check(5, data_out, 8'h00, "seq_addr0");

        // Posição 100 → valor esperado 8'h64 (100 em hex)
        @(posedge clk); #1;
        addr = 10'd100;
        @(posedge clk); #1;
        check(5, data_out, 8'h64, "seq_addr100");

        // Posição 391 → valor esperado 8'h87 (391 & 0xFF = 135 = 0x87)
        @(posedge clk); #1;
        addr = 10'd391;
        @(posedge clk); #1;
        check(5, data_out, 8'h87, "seq_addr391");

        // Posição 500 → valor esperado 8'hF4 (500 & 0xFF = 244 = 0xF4)
        @(posedge clk); #1;
        addr = 10'd500;
        @(posedge clk); #1;
        check(5, data_out, 8'hF4, "seq_addr500");

        // Posição 783 → valor esperado 8'h0F (783 & 0xFF = 15 = 0x0F)
        @(posedge clk); #1;
        addr = 10'd783;
        @(posedge clk); #1;
        check(5, data_out, 8'h0F, "seq_addr783");

        // ---------------------------------------------------------------------
        // TC-IMG-06 — Sobrescrita: nova escrita substitui valor anterior
        // Simula o comportamento entre duas inferências consecutivas.
        // ---------------------------------------------------------------------
        $display("\n-- TC-IMG-06: sobrescrita substitui valor anterior --");

        // Primeira escrita
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd50;
        data_in = 8'h10;

        // Segunda escrita (sobrescrita)
        @(posedge clk); #1;
        we      = 1;
        addr    = 10'd50;
        data_in = 8'hBE;

        // Leitura
        @(posedge clk); #1;
        we   = 0;
        addr = 10'd50;

        @(posedge clk); #1;
        check(6, data_out, 8'hBE, "sobrescrita");

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
        $dumpfile("tb_ram_img.vcd");
        $dumpvars(0, tb_ram_img);
    end

endmodule
