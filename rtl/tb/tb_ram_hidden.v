// =============================================================================
// Testbench: tb_ram_hidden.v
// Módulo sob teste: ram_hidden.v
// Referência: test_spec_memories.md — Módulo 5 (TC-HID-01 a TC-HID-06)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_ram_hidden tb_ram_hidden.v ram_hidden.v && vvp tb_ram_hidden
// =============================================================================

`timescale 1ns/1ps

module tb_ram_hidden;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg         clk;
    reg         we;
    reg   [6:0] addr;
    reg  [15:0] data_in;
    wire [15:0] data_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    ram_hidden dut (
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
        input [63:0]  tc_num;
        input [15:0]  got;
        input [15:0]  exp;
        begin
            if (got === exp) begin
                $display("  PASS  TC-HID-%0d | got=0x%04X  exp=0x%04X", tc_num, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-HID-%0d | got=0x%04X  exp=0x%04X  <---", tc_num, got, exp);
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
        we      = 0;
        addr    = 0;
        data_in = 0;
        #3;

        $display("=============================================================");
        $display(" tb_ram_hidden — Iniciando testes (TC-HID-01 a TC-HID-06)");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-HID-01 — Escrita e leitura simples no endereço 0
        //
        // Sanidade básica com dado de 16 bits em Q4.12.
        // 0x1000 = +1.0 em Q4.12 — valor típico de saída da PWL.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-01: escrita e leitura no addr=0 --");
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd0;
        data_in = 16'h1000;     // +1.0 em Q4.12

        @(posedge clk); #1;
        we   = 0;
        addr = 7'd0;

        @(posedge clk); #1;
        check(1, data_out, 16'h1000);

        // ---------------------------------------------------------------------
        // TC-HID-02 — Escrita e leitura no endereço máximo (127)
        //
        // addr=127 = 7'b111_1111 — caso extremo do endereço de 7 bits.
        // Escrevemos -1.0 (0xF000) para testar também valor negativo Q4.12.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-02: escrita e leitura no addr=127 --");
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd127;
        data_in = 16'hF000;     // -1.0 em Q4.12

        @(posedge clk); #1;
        we   = 0;
        addr = 7'd127;

        @(posedge clk); #1;
        check(2, data_out, 16'hF000);

        // ---------------------------------------------------------------------
        // TC-HID-03 — Escrita de valor negativo Q4.12 preserva sinal
        //
        // A saída da PWL pode ser negativa (ex: -0.75 = 0xF400).
        // Verifica que o bit 15 (sinal) não é truncado.
        // Erro comum: declarar data_in com menos de 16 bits acidentalmente.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-03: valor negativo Q4.12 preserva sinal --");
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd10;
        data_in = 16'hF400;     // -0.75 em Q4.12

        @(posedge clk); #1;
        we   = 0;
        addr = 7'd10;

        @(posedge clk); #1;
        check(3, data_out, 16'hF400);

        // ---------------------------------------------------------------------
        // TC-HID-04 — Escrita sequencial de 128 neurônios
        //
        // Simula o estado CALC_HIDDEN: a FSM escreve h[0], h[1], ..., h[127]
        // consecutivamente, um por ciclo.
        // Padrão: data_in = 0x1000 + addr (valores distintos e verificáveis)
        // Verificação por amostragem: posições 0, 64 e 127.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-04: escrita sequencial de 128 neuronios --");

        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk); #1;
            we      = 1;
            addr    = i[6:0];
            data_in = 16'h1000 + i[15:0];
        end

        @(posedge clk); #1;
        we = 0;

        // Amostra posição 0 → esperado 0x1000
        @(posedge clk); #1;
        addr = 7'd0;
        @(posedge clk); #1;
        check(4, data_out, 16'h1000);

        // Amostra posição 64 → esperado 0x1040
        @(posedge clk); #1;
        addr = 7'd64;
        @(posedge clk); #1;
        check(4, data_out, 16'h1040);

        // Amostra posição 127 → esperado 0x107F
        @(posedge clk); #1;
        addr = 7'd127;
        @(posedge clk); #1;
        check(4, data_out, 16'h107F);

        // ---------------------------------------------------------------------
        // TC-HID-05 — Isolamento: escrita em addr X não afeta addr Y
        //
        // Verifica que neurônios com endereços adjacentes são independentes.
        // Erro de aliasing faria addr=20 e addr=21 compartilhar o mesmo dado.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-05: isolamento entre enderecos adjacentes --");

        // Escreve em addr=20
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd20;
        data_in = 16'h0800;     // +0.5 em Q4.12

        // Escreve em addr=21
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd21;
        data_in = 16'h0400;     // +0.25 em Q4.12

        @(posedge clk); #1;
        we = 0;

        // Verifica addr=20
        @(posedge clk); #1;
        addr = 7'd20;
        @(posedge clk); #1;
        check(5, data_out, 16'h0800);

        // Verifica addr=21
        @(posedge clk); #1;
        addr = 7'd21;
        @(posedge clk); #1;
        check(5, data_out, 16'h0400);

        // ---------------------------------------------------------------------
        // TC-HID-06 — Sobrescrita: segunda inferência não contamina a primeira
        //
        // Entre duas inferências, a FSM sobrescreve ram_hidden com novos
        // valores de h. Verifica que a segunda escrita substitui completamente
        // a primeira — sem resíduos da inferência anterior.
        // ---------------------------------------------------------------------
        $display("\n-- TC-HID-06: sobrescrita entre inferencias --");

        // Primeira "inferência"
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd5;
        data_in = 16'hAAAA;

        // Segunda "inferência" — sobrescreve
        @(posedge clk); #1;
        we      = 1;
        addr    = 7'd5;
        data_in = 16'h5555;

        @(posedge clk); #1;
        we   = 0;
        addr = 7'd5;

        @(posedge clk); #1;
        check(6, data_out, 16'h5555);

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
        $dumpfile("tb_ram_hidden.vcd");
        $dumpvars(0, tb_ram_hidden);
    end

endmodule
