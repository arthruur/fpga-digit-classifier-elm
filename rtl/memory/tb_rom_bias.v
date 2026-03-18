// =============================================================================
// Testbench: tb_rom_bias.v
// Módulo sob teste: rom_bias.v
// Referência: test_spec_memories.md — Módulo 3 (TC-BIAS-01 a TC-BIAS-03)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_bias tb_rom_bias.v rom_bias.v && vvp tb_rom_bias
//
// Padrão sintético: mem[addr] = addr[15:0]
//   BIAS_0   = 0x0000  (addr=0)
//   BIAS_127 = 0x007F  (addr=127)
// =============================================================================

`timescale 1ns/1ps

module tb_rom_bias;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg        clk;
    reg  [6:0] addr;
    wire [15:0] data_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Valores esperados
    // Com padrão sintético: valor = addr
    // Atualize quando bias.mif for fornecido.
    // -------------------------------------------------------------------------
    localparam BIAS_0   = 16'h0000;   // addr=0   → valor=0
    localparam BIAS_127 = 16'h007F;   // addr=127 → valor=127

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    rom_bias dut (
        .clk      (clk),
        .addr     (addr),
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
        input [63:0]  tc_num;
        input [15:0]  got;
        input [15:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-BIAS-%0d | got=0x%04X  exp=0x%04X", tc_num, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-BIAS-%0d | got=0x%04X  exp=0x%04X  <---", tc_num, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Sequência principal de testes
    // =========================================================================
    integer i;
    reg test_passed;

    initial begin
        pass_count = 0;
        fail_count = 0;
        addr = 0;
        #3;

        $display("=============================================================");
        $display(" tb_rom_bias — Iniciando testes (TC-BIAS-01 a TC-BIAS-03)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-BIAS-01 — Leitura do bias b[0]
        //
        // Sanidade básica: verifica que a ROM foi inicializada e que
        // o endereço 0 retorna o valor correto.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-01: leitura b[0] --");
        @(posedge clk); #1;
        addr = 7'd0;

        @(posedge clk); #1;
        check(1, data_out, BIAS_0);

        // ---------------------------------------------------------------------
        // TC-BIAS-02 — Leitura do bias b[127] (endereço máximo)
        //
        // Verifica que os 7 bits de endereço cobrem as 128 posições.
        // Se addr fosse declarado com 6 bits, addr=127 seria truncado
        // para addr=63, retornando o bias errado.
        //
        // 7 bits → representa 0..127 ✓
        // 6 bits → representa 0..63  ✗ (insuficiente)
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-02: leitura b[127] (addr maximo) --");
        @(posedge clk); #1;
        addr = 7'd127;

        @(posedge clk); #1;
        check(2, data_out, BIAS_127);

        // ---------------------------------------------------------------------
        // TC-BIAS-03 — Varredura completa: todos os 128 biases legíveis
        //
        // Lê todas as 128 posições e compara com o padrão sintético.
        // Com padrão sintético: valor esperado em addr N = N.
        //
        // Este teste garante que não há posição inacessível ou corrompida.
        // Quando bias.mif for fornecido, substitua o valor esperado por
        // um array carregado do arquivo de referência.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-03: varredura completa (128 posicoes) --");
        test_passed = 1;

        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk); #1;
            addr = i[6:0];

            @(posedge clk); #1;
            // Com padrão sintético: valor esperado = índice
            if (data_out !== i[15:0]) begin
                $display("  FAIL  TC-BIAS-03 | addr=%0d got=0x%04X exp=0x%04X  <---",
                         i, data_out, i[15:0]);
                fail_count = fail_count + 1;
                test_passed = 0;
            end
        end

        if (test_passed) begin
            $display("  PASS  TC-BIAS-03 | 128/128 posicoes corretas");
            pass_count = pass_count + 1;
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
        $dumpfile("tb_rom_bias.vcd");
        $dumpvars(0, tb_rom_bias);
    end

endmodule
