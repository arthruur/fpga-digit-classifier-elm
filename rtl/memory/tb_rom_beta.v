// =============================================================================
// Testbench: tb_rom_beta.v
// Módulo sob teste: rom_beta.v
// Referência: test_spec_memories.md — Módulo 4 (TC-BETA-01 a TC-BETA-04)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_beta tb_rom_beta.v rom_beta.v && vvp tb_rom_beta
//
// REQUISITO: beta.hex deve estar no mesmo diretório que os arquivos .v
//
// Valores de referência (extraídos de beta_q.txt em Q4.12):
//   β[0][0]   = beta[0]    = -131 → 0xFF7D
//   β[9][127] = beta[1279] =   11 → 0x000B
//   β[1][0]   = beta[128]  =   13 → 0x000D  (usado no TC-BETA-03)
// =============================================================================

`timescale 1ns/1ps

module tb_rom_beta;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg         clk;
    reg  [10:0] addr;
    wire [15:0] data_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Valores esperados — pesos reais em Q4.12 (fonte: beta_q.txt)
    //
    //   β[0][0]   = beta[0]    = -131 → 0xFF7D
    //   β[9][127] = beta[1279] = 11   → 0x000B
    //   β[1][0]   = beta[128]  = 13   → 0x000D
    //
    // Verificação:
    //   -131 & 0xFFFF = 65536 - 131 = 65405 = 0xFF7D ✓
    // -------------------------------------------------------------------------

    // Valores lidos dinamicamente de expected[] carregado via $readmemh.
    // Layout: posição = neuron * 10 + class  (ex: neuron=3, class=7 → addr=37)

    // -------------------------------------------------------------------------
    // Array para varredura (TC-BETA-04)
    // -------------------------------------------------------------------------
    reg [15:0] expected [1279:0];

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    rom_beta dut (
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
    // Task auxiliar
    // -------------------------------------------------------------------------
    task check;
        input [63:0]  tc_num;
        input [15:0]  got;
        input [15:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-BETA-%0d | got=0x%04X  exp=0x%04X", tc_num, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-BETA-%0d | got=0x%04X  exp=0x%04X  <---", tc_num, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Sequência principal de testes
    // =========================================================================
    integer c, h;
    reg test_passed;

    initial begin
        pass_count = 0;
        fail_count = 0;
        addr = 0;

        $readmemh("beta_q.hex", expected);

        #3;

        $display("=============================================================");
        $display(" tb_rom_beta — Iniciando testes (TC-BETA-01 a TC-BETA-04)");
        $display(" Pesos reais Q4.12 carregados de beta.hex");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-BETA-01 — Leitura de β[0][0]
        //
        // β[0][0] = -131 → 0xFF7D
        // Endereço: {4'd0, 7'd0} = 11'd0
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-01: leitura beta[0][0] (esperado 0xFF7D = -131) --");
        @(posedge clk); #1;
        addr = 11'd0;   // 0*10+0 = 0

        @(posedge clk); #1;
        check(1, data_out, expected[0]);

        // ---------------------------------------------------------------------
        // TC-BETA-02 — Leitura de β[9][127] (endereço máximo = 1279)
        //
        // β[9][127] = 11 → 0x000B
        // Endereço: {4'd9, 7'd127} = 11'd1279
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-02: leitura addr=1279 (neuron=127, class=9 — maximo) --");
        @(posedge clk); #1;
        addr = 11'd1279;       // 127*10+9 = 1279
        @(posedge clk); #1;
        check(2, data_out, expected[1279]);

        // ---------------------------------------------------------------------
        // TC-BETA-03 — Independência entre classes: β[0][0] ≠ β[1][0]
        //
        // β[0][0] = -131 (0xFF7D)   addr = 0
        // β[1][0] =   13 (0x000D)   addr = 128
        // Verifica que class_idx distingue corretamente as linhas de β.
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-03: independencia entre classes (neuron=0: class=0 vs class=1) --");
        @(posedge clk); #1;
        addr = 11'd0;          // neuron=0, class=0 → 0*10+0 = 0
        @(posedge clk); #1;
        // data_out = expected[0]

        @(posedge clk); #1;
        addr = 11'd1;          // neuron=0, class=1 → 0*10+1 = 1
        @(posedge clk); #1;
        // data_out = expected[1]

        if (data_out !== expected[0]) begin
            $display("  PASS  TC-BETA-03 | addr=1 (0x%04X) != addr=0 (0x%04X): classes independentes",
                    data_out, expected[0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-BETA-03 | addr=0 == addr=1: class_idx sem efeito?  <---");
            fail_count = fail_count + 1;
        end
        check(3, data_out, expected[1]);

        // ---------------------------------------------------------------------
        // TC-BETA-04 — Varredura por amostragem: 3 classes × 3 neurônios
        //
        // Compara com expected[] carregado do beta.hex.
        // Posições verificadas para cada classe c em {0, 4, 9}:
        //   β[c][0], β[c][63], β[c][127]
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-04: varredura por amostragem (3 classes x 3 neuronios) --");
        test_passed = 1;

        begin : varredura
            integer classe;
            integer neuron;
            integer expected_addr;

        for (neuron = 0; neuron <= 127; neuron = neuron + 63) begin
            if (neuron == 126) neuron = 127;
            for (classe = 0; classe <= 9; classe = classe + 4) begin
                if (classe == 8) classe = 9;
                expected_addr = neuron * 10 + classe;
                @(posedge clk); #1;
                addr = ({4'b0, neuron[6:0]} << 3)
                    + ({4'b0, neuron[6:0]} << 1)
                    + {7'b0, classe[3:0]};
                @(posedge clk); #1;
                if (data_out !== expected[expected_addr]) begin
                    $display("  FAIL  TC-BETA-04 | addr=%0d (n=%0d,c=%0d) got=0x%04X exp=0x%04X  <---",
                            expected_addr, neuron, classe, data_out, expected[expected_addr]);
                        fail_count = fail_count + 1;
                        test_passed = 0;
                    end
                end
            end
        end

        if (test_passed) begin
            $display("  PASS  TC-BETA-04 | 9/9 posicoes amostradas corretas (pesos reais Q4.12)");
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
        $dumpfile("tb_rom_beta.vcd");
        $dumpvars(0, tb_rom_beta);
    end

endmodule
