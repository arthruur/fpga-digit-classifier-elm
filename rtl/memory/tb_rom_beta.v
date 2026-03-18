// =============================================================================
// Testbench: tb_rom_beta.v
// Módulo sob teste: rom_beta.v
// Referência: test_spec_memories.md — Módulo 4 (TC-BETA-01 a TC-BETA-04)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_beta tb_rom_beta.v rom_beta.v && vvp tb_rom_beta
//
// Padrão sintético: mem[addr] = addr[15:0]
//   β[0][0]   → addr={4'd0, 7'd0}   = 0    → valor=0x0000
//   β[9][127] → addr={4'd9, 7'd127} = 1279 → valor=0x04FF
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
    // Valores esperados
    //
    // Com padrão sintético: valor = endereço numérico
    //
    // Cálculo:
    //   β[0][0]   → {4'd0, 7'd0}   = 11'd0    → 0x0000
    //   β[9][127] → {4'd9, 7'd127} = 11'd1279  → 0x04FF
    //
    // Atualize quando beta.mif for fornecido.
    // -------------------------------------------------------------------------
    localparam BETA_0_0   = 16'h0000;   // addr=0
    localparam BETA_9_127 = 16'h04FF;   // addr=1279

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
    // Task auxiliar: verifica resultado e imprime PASS ou FAIL
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
        #3;

        $display("=============================================================");
        $display(" tb_rom_beta — Iniciando testes (TC-BETA-01 a TC-BETA-04)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-BETA-01 — Leitura de β[0][0] (classe 0, neurônio oculto 0)
        //
        // Sanidade básica: verifica inicialização e endereçamento base.
        // Endereço: {4'd0, 7'd0} = 11'd0
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-01: leitura beta[0][0] --");
        @(posedge clk); #1;
        addr = {4'd0, 7'd0};

        @(posedge clk); #1;
        check(1, data_out, BETA_0_0);

        // ---------------------------------------------------------------------
        // TC-BETA-02 — Leitura de β[9][127] (endereço máximo)
        //
        // Endereço máximo = {4'd9, 7'd127} = 11'd1279
        // Verifica que a ROM tem profundidade suficiente para 10×128=1280
        // posições e que o endereço máximo é acessível sem overflow.
        //
        // Por que 4 bits para class_idx?
        //   10 classes → precisamos representar 0..9
        //   2³ = 8  → insuficiente
        //   2⁴ = 16 → suficiente ✓
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-02: leitura beta[9][127] (addr maximo) --");
        @(posedge clk); #1;
        addr = {4'd9, 7'd127};

        @(posedge clk); #1;
        check(2, data_out, BETA_9_127);

        // ---------------------------------------------------------------------
        // TC-BETA-03 — Independência entre classes: β[0][0] ≠ β[1][0]
        //
        // Verifica que class_idx distingue corretamente linhas diferentes
        // da matriz β. Um erro no campo class_idx faria todas as 10 classes
        // usar os mesmos pesos — a rede classificaria tudo como dígito 0.
        //
        // β[0][0] → addr = {4'd0, 7'd0} = 0   → valor = 0x0000
        // β[1][0] → addr = {4'd1, 7'd0} = 128  → valor = 0x0080
        // Com padrão sintético são diferentes ✓
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-03: independencia entre classes --");

        // Lê β[0][0]
        @(posedge clk); #1;
        addr = {4'd0, 7'd0};
        @(posedge clk); #1;
        // data_out agora tem β[0][0] = 0x0000

        // Lê β[1][0]
        @(posedge clk); #1;
        addr = {4'd1, 7'd0};
        @(posedge clk); #1;
        // data_out agora tem β[1][0] = 0x0080

        // Verifica que β[1][0] ≠ β[0][0]
        if (data_out !== BETA_0_0) begin
            $display("  PASS  TC-BETA-03 | beta[0][0] != beta[1][0]: classes independentes");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-BETA-03 | beta[0][0] == beta[1][0]: class_idx incorreto?  <---");
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // TC-BETA-04 — Varredura por amostragem: 3 classes × 3 neurônios
        //
        // Lê 9 posições estratégicas e compara com padrão sintético.
        // Verifica integridade do MIF sem simular todas as 1280 posições.
        //
        // Posições verificadas para cada classe c em {0, 4, 9}:
        //   β[c][0]   → addr = c*128 + 0
        //   β[c][63]  → addr = c*128 + 63
        //   β[c][127] → addr = c*128 + 127
        // ---------------------------------------------------------------------
        $display("\n-- TC-BETA-04: varredura por amostragem (3 classes x 3 neuronios) --");
        test_passed = 1;

        begin : varredura
            integer classe;
            integer neuron;
            integer expected_addr;
            reg [15:0] expected_val;

            for (classe = 0; classe <= 9; classe = classe + 4) begin
                // Garante que só passa por {0, 4, 9}
                if (classe > 8) classe = 9;

                for (neuron = 0; neuron <= 127; neuron = neuron + 63) begin
                    if (neuron > 64 && neuron < 127) neuron = 127;

                    expected_addr = classe * 128 + neuron;
                    expected_val  = expected_addr[15:0]; // padrão sintético

                    @(posedge clk); #1;
                    addr = {classe[3:0], neuron[6:0]};

                    @(posedge clk); #1;

                    if (data_out !== expected_val) begin
                        $display("  FAIL  TC-BETA-04 | beta[%0d][%0d] got=0x%04X exp=0x%04X  <---",
                                 classe, neuron, data_out, expected_val);
                        fail_count = fail_count + 1;
                        test_passed = 0;
                    end
                end
            end
        end

        if (test_passed) begin
            $display("  PASS  TC-BETA-04 | 9/9 posicoes amostradas corretas");
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
