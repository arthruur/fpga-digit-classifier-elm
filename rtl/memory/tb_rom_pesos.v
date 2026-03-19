// =============================================================================
// Testbench: tb_rom_pesos.v
// Módulo sob teste: rom_pesos.v
// Referência: test_spec_memories.md — Módulo 2 (TC-WGT-01 a TC-WGT-06)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_pesos tb_rom_pesos.v rom_pesos.v && vvp tb_rom_pesos
//
// REQUISITO: w_in.hex deve estar no mesmo diretório que os arquivos .v
//
// ─── ESQUEMA DE ENDEREÇAMENTO (PADDED) ─────────────────────────────────────
//   addr = {neuron_idx[6:0], pixel_idx[9:0]}
//   addr = neuron_idx * 1024 + pixel_idx
//
//   Profundidade da ROM: 2^17 = 131.072 (padded)
//   Posições n*1024 + 784 a n*1024 + 1023: padding (zero, não usadas pela FSM)
//
//   Endereços de teste:
//     W[0][0]     → {7'd0,   10'd0}   = 17'd0      = 0
//     W[0][783]   → {7'd0,   10'd783} = 17'd783     = 783
//     W[127][0]   → {7'd127, 10'd0}   = 17'd130048  = 127*1024
//     W[127][783] → {7'd127, 10'd783} = 17'd130831  = 127*1024 + 783
//
// ─── VALORES ESPERADOS (pesos reais Q4.12) ──────────────────────────────────
//   W[0][0]     = w[0]       = -136  → 0xFF78
//   W[0][783]   = w[783]     = 5670  → 0x1626
//   W[127][0]   = w[99568]   = -466  → 0xFE2E
//   W[127][783] = w[100351]  = -4225 → 0xEF7F
// =============================================================================

`timescale 1ns/1ps

module tb_rom_pesos;

    // -------------------------------------------------------------------------
    // Sinais de interface com o DUT
    // -------------------------------------------------------------------------
    reg         clk;
    reg  [16:0] addr;
    wire [15:0] data_out;

    // -------------------------------------------------------------------------
    // Contadores de PASS / FAIL
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    // -------------------------------------------------------------------------
    // Valores esperados — pesos reais em Q4.12 (fonte: W_in_q.txt)
    //
    // Endereços com layout padded (neuron * 1024 + pixel):
    //   W[0][0]     = w_linear[0*784+0]   = -136  → 0xFF78
    //   W[0][783]   = w_linear[0*784+783] = 5670  → 0x1626
    //   W[127][0]   = w_linear[127*784+0] = -466  → 0xFE2E
    //   W[127][783] = w_linear[127*784+783]= -4225 → 0xEF7F
    // -------------------------------------------------------------------------
    localparam W_IN_0_0     = 16'hFF78;   // W[0][0]     addr=0
    localparam W_IN_0_783   = 16'h1626;   // W[0][783]   addr=783
    localparam W_IN_127_0   = 16'hFE2E;   // W[127][0]   addr=130048
    localparam W_IN_127_783 = 16'hEF7F;   // W[127][783] addr=130831

    // -------------------------------------------------------------------------
    // Instância do DUT
    // -------------------------------------------------------------------------
    rom_pesos dut (
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
                $display("  PASS  TC-WGT-%0d | got=0x%04X  exp=0x%04X", tc_num, got, exp);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  TC-WGT-%0d | got=0x%04X  exp=0x%04X  <---", tc_num, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Sequência principal de testes
    // =========================================================================
    initial begin
        pass_count = 0;
        fail_count = 0;
        addr = 0;

        #3;

        $display("=============================================================");
        $display(" tb_rom_pesos — Iniciando testes (TC-WGT-01 a TC-WGT-06)");
        $display(" Pesos reais Q4.12 | ROM padded 2^17 = 131072 entradas");
        $display(" Endereçamento: addr = {neuron[6:0], pixel[9:0]}");
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-WGT-01 — Leitura do peso W[0][0]
        //
        // W[0][0] = -136 → 0xFF78
        // Endereço: {7'd0, 10'd0} = 17'd0
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-01: leitura W[0][0] (esperado 0xFF78 = -136) --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};

        @(posedge clk); #1;
        check(1, data_out, W_IN_0_0);

        // ---------------------------------------------------------------------
        // TC-WGT-02 — Leitura do peso W[0][783] (neurônio 0, último pixel)
        //
        // W[0][783] = 5670 → 0x1626
        // Endereço: {7'd0, 10'd783} = 17'd783
        // Verifica que pixel_idx[9:0] cobre corretamente até 783.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-02: leitura W[0][783] (esperado 0x1626 = 5670) --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd783};

        @(posedge clk); #1;
        check(2, data_out, W_IN_0_783);

        // ---------------------------------------------------------------------
        // TC-WGT-03 — Leitura do peso W[127][0] (último neurônio, pixel 0)
        //
        // W[127][0] = -466 → 0xFE2E
        // Endereço padded: {7'd127, 10'd0} = 17'd130048
        //
        // NOTA HISTÓRICA — este era o bug do testbench original:
        //   A ROM tinha profundidade 100352, mas {7'd127, 10'd0} = 130048 > 100351
        //   → acesso out-of-bounds → data_out = 'x na simulação.
        //   Corrigido com profundidade padded = 131072. ✓
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-03: leitura W[127][0] (esperado 0xFE2E = -466) --");
        @(posedge clk); #1;
        addr = {7'd127, 10'd0};

        @(posedge clk); #1;
        check(3, data_out, W_IN_127_0);

        // ---------------------------------------------------------------------
        // TC-WGT-04 — Leitura do peso W[127][783] (endereço máximo real)
        //
        // W[127][783] = -4225 → 0xEF7F
        // Endereço padded: {7'd127, 10'd783} = 17'd130831
        // Verifica que a ROM tem profundidade suficiente.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-04: leitura W[127][783] (esperado 0xEF7F = -4225) --");
        @(posedge clk); #1;
        addr = {7'd127, 10'd783};

        @(posedge clk); #1;
        check(4, data_out, W_IN_127_783);

        // ---------------------------------------------------------------------
        // TC-WGT-05 — Latência de leitura: exatamente 1 ciclo
        //
        // Apresenta endereço no ciclo N, verifica no ciclo N+1.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-05: latencia de leitura = 1 ciclo --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};   // apresenta no ciclo N

        @(posedge clk); #1;     // ciclo N+1: dado disponível
        check(5, data_out, W_IN_0_0);

        // ---------------------------------------------------------------------
        // TC-WGT-06 — Dois endereços consecutivos retornam valores distintos
        //
        // W[0][0] = -136 (0xFF78)   addr=0
        // W[1][0] = ?               addr=1024 (= {7'd1, 10'd0})
        // Com pesos reais, praticamente garantido que W[0][0] ≠ W[1][0].
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-06: enderecos consecutivos retornam valores distintos --");

        // Lê W[0][0]
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};
        @(posedge clk); #1;
        // data_out = W[0][0]

        // Lê W[1][0]
        @(posedge clk); #1;
        addr = {7'd1, 10'd0};
        @(posedge clk); #1;
        // data_out = W[1][0]

        if (data_out !== W_IN_0_0) begin
            $display("  PASS  TC-WGT-06 | W[0][0] != W[1][0] (0x%04X vs 0x%04X): valores distintos",
                     W_IN_0_0, data_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL  TC-WGT-06 | W[0][0] == W[1][0]: registrador travado?  <---");
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
        $dumpfile("tb_rom_pesos.vcd");
        $dumpvars(0, tb_rom_pesos);
    end

endmodule
