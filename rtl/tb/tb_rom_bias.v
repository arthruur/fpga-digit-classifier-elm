// =============================================================================
// Testbench: tb_rom_bias.v
// Módulo sob teste: rom_bias.v
// Referência: test_spec_memories.md — Módulo 3 (TC-BIAS-01 a TC-BIAS-03)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_bias tb_rom_bias.v rom_bias.v && vvp tb_rom_bias
//
// REQUISITO: bias.hex deve estar no mesmo diretório que os arquivos .v
//
// Valores de referência (extraídos de b_q.txt em Q4.12):
//   BIAS_0   = b[0]   = -710  → 0xFD3A
//   BIAS_127 = b[127] = 7146  → 0x1BEA
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
    // Valores esperados — pesos reais em Q4.12 (fonte: b_q.txt)
    //
    //   b[0]   = -710  → complemento de dois 16-bit = 0xFD3A
    //   b[127] = 7146  → 0x1BEA
    //
    // Para verificar manualmente:
    //   -710 & 0xFFFF = 65536 - 710 = 64826 = 0xFD3A  ✓
    //    7146 em hex = 0x1BEA                          ✓
    // -------------------------------------------------------------------------
    localparam BIAS_0   = 16'hFD3A;   // b[0]   = -710 em Q4.12
    localparam BIAS_127 = 16'h1BEA;   // b[127] = 7146 em Q4.12

    // -------------------------------------------------------------------------
    // Array para varredura completa (TC-BIAS-03)
    // Carregado do mesmo arquivo que inicializa a ROM — comparação direta.
    // -------------------------------------------------------------------------
    reg [15:0] expected [127:0];

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

        // Carrega valores de referência do mesmo arquivo que a ROM
        $readmemh("bias.hex", expected);

        #3;

        $display("=============================================================");
        $display(" tb_rom_bias — Iniciando testes (TC-BIAS-01 a TC-BIAS-03)");
        $display(" Pesos reais Q4.12 carregados de bias.hex");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-BIAS-01 — Leitura do bias b[0]
        //
        // b[0] = -710 → 0xFD3A em Q4.12 (16-bit complemento de dois)
        // Verifica que a ROM foi inicializada com os pesos reais e que
        // o endereço base 0 retorna o valor correto.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-01: leitura b[0] (esperado 0xFD3A = -710 em Q4.12) --");
        @(posedge clk); #1;
        addr = 7'd0;

        @(posedge clk); #1;
        check(1, data_out, BIAS_0);

        // ---------------------------------------------------------------------
        // TC-BIAS-02 — Leitura do bias b[127] (endereço máximo)
        //
        // b[127] = 7146 → 0x1BEA
        // Verifica que addr[6:0] cobre corretamente todas as 128 posições.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-02: leitura b[127] (esperado 0x1BEA = 7146 em Q4.12) --");
        @(posedge clk); #1;
        addr = 7'd127;

        @(posedge clk); #1;
        check(2, data_out, BIAS_127);

        // ---------------------------------------------------------------------
        // TC-BIAS-03 — Varredura completa: todos os 128 biases legíveis
        //
        // Compara cada posição com o array expected[], que foi carregado
        // do mesmo arquivo bias.hex usado para inicializar a ROM.
        // Garante que não há posição inacessível ou corrompida.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BIAS-03: varredura completa (128 posicoes) --");
        test_passed = 1;

        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk); #1;
            addr = i[6:0];

            @(posedge clk); #1;
            if (data_out !== expected[i]) begin
                $display("  FAIL  TC-BIAS-03 | addr=%0d got=0x%04X exp=0x%04X  <---",
                         i, data_out, expected[i]);
                fail_count = fail_count + 1;
                test_passed = 0;
            end
        end

        if (test_passed) begin
            $display("  PASS  TC-BIAS-03 | 128/128 posicoes corretas (pesos reais Q4.12)");
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
