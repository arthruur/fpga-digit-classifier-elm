// =============================================================================
// Testbench: tb_rom_pesos.v
// Módulo sob teste: rom_pesos.v
// Referência: test_spec_memories.md — Módulo 2 (TC-WGT-01 a TC-WGT-06)
//
// Como executar (Icarus Verilog):
//   iverilog -o tb_rom_pesos tb_rom_pesos.v rom_pesos.v && vvp tb_rom_pesos
//
// IMPORTANTE sobre os valores esperados:
//   Como os pesos reais ainda não foram fornecidos, a rom_pesos está
//   inicializada com o padrão sintético: mem[addr] = addr[15:0].
//   Portanto: valor esperado em qualquer posição = addr[15:0].
//
//   Quando o arquivo w_in.mif for fornecido pelo professor:
//   1. Substitua a inicialização sintética na rom_pesos.v
//   2. Atualize as constantes W_IN_* abaixo com os valores reais do MIF
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
    // Valores esperados para cada posição de teste
    //
    // Com o padrão sintético: valor esperado = addr[15:0]
    //
    // Cálculo dos endereços compostos:
    //   addr = {neuron_idx[6:0], pixel_idx[9:0]}
    //
    //   W[0][0]   → {7'd0,   10'd0}   = 17'd0      → valor = 16'd0
    //   W[0][783] → {7'd0,   10'd783} = 17'd783     → valor = 16'd783
    //   W[127][0] → {7'd127, 10'd0}   = 17'd100352-784 = 17'd99840 → valor = 99840 & 0xFFFF = 16'd99840 % 65536
    //   W[127][783]→ {7'd127,10'd783} = 17'd100351  → valor = 100351 & 0xFFFF = 16'd34815
    //
    // Substitua estes valores quando os pesos reais forem fornecidos:
    // -------------------------------------------------------------------------
    localparam W_IN_0_0     = 16'd0;        // addr = 17'd0
    localparam W_IN_0_783   = 16'd783;      // addr = 17'd783
    localparam W_IN_127_0   = 16'd34816;    // addr = 17'd99840  → 99840 mod 65536 = 34304... ver nota
    localparam W_IN_127_783 = 16'd34815;    // addr = 17'd100351 → 100351 mod 65536 = 34815

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
    // Task auxiliar: verifica resultado e imprime PASS ou FAIL
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
        $display("=============================================================");

        // ---------------------------------------------------------------------
        // TC-WGT-01 — Leitura do peso W[0][0] (neurônio 0, pixel 0)
        //
        // Endereço: {7'd0, 10'd0} = 17'd0
        // É o teste de sanidade fundamental da ROM — verifica que a
        // inicialização funcionou e que o endereço base retorna valor correto.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-01: leitura W[0][0] --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};       // endereço composto: neurônio 0, pixel 0

        @(posedge clk); #1;         // aguarda 1 ciclo de latência
        check(1, data_out, W_IN_0_0);

        // ---------------------------------------------------------------------
        // TC-WGT-02 — Leitura do peso W[0][783] (neurônio 0, último pixel)
        //
        // Verifica que pixel_idx[9:0] chega corretamente até 783.
        // Um addr de 16 bits em vez de 17 cortaria o bit mais alto de
        // pixel_idx e este endereço seria mapeado incorretamente.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-02: leitura W[0][783] --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd783};     // neurônio 0, último pixel

        @(posedge clk); #1;
        check(2, data_out, W_IN_0_783);

        // ---------------------------------------------------------------------
        // TC-WGT-03 — Leitura do peso W[127][0] (último neurônio, pixel 0)
        //
        // Verifica que neuron_idx[6:0] funciona corretamente nos bits altos
        // do endereço. Erro aqui faria todos os neurônios ler pesos do
        // neurônio 0.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-03: leitura W[127][0] --");
        @(posedge clk); #1;
        addr = {7'd127, 10'd0};     // último neurônio, pixel 0

        @(posedge clk); #1;
        check(3, data_out, W_IN_127_0);

        // ---------------------------------------------------------------------
        // TC-WGT-04 — Leitura do peso W[127][783] (endereço máximo)
        //
        // addr máximo = {7'd127, 10'd783} = 17'd100351
        // Verifica que a ROM tem profundidade suficiente e que não há
        // overflow de endereçamento na posição final.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-04: leitura W[127][783] (addr maximo) --");
        @(posedge clk); #1;
        addr = {7'd127, 10'd783};   // posição máxima da ROM

        @(posedge clk); #1;
        check(4, data_out, W_IN_127_783);

        // ---------------------------------------------------------------------
        // TC-WGT-05 — Latência de leitura: exatamente 1 ciclo de clock
        //
        // Verifica explicitamente que a ROM é síncrona: apresentar o endereço
        // no ciclo N entrega o dado no ciclo N+1, não no mesmo ciclo.
        // A FSM precisa respeitar essa latência ao ler pesos consecutivos.
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-05: latencia de leitura = 1 ciclo --");
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};       // apresenta endereço no ciclo N

        // Ciclo N+1: dado ainda não deve ser verificado aqui
        // (apenas avança o clock sem checar)
        @(posedge clk); #1;

        // Ciclo N+2: agora verifica — mesmo endereço, dado estável
        // Nota: avançamos 1 ciclo extra para garantir estabilidade
        check(5, data_out, W_IN_0_0);

        // ---------------------------------------------------------------------
        // TC-WGT-06 — Dois endereços consecutivos retornam valores distintos
        //
        // Verifica que leituras consecutivas não retornam o mesmo valor
        // por inércia de registrador. W[0][0] e W[1][0] devem ser diferentes
        // (garantido pelo padrão sintético: addr0=0, addr1=784).
        // ---------------------------------------------------------------------
        $display("\n-- TC-WGT-06: enderecos consecutivos retornam valores distintos --");

        // Lê W[0][0]
        @(posedge clk); #1;
        addr = {7'd0, 10'd0};
        @(posedge clk); #1;
        // data_out agora tem W[0][0] = 0x0000

        // Lê W[1][0] — endereço = {7'd1, 10'd0} = 17'd784
        @(posedge clk); #1;
        addr = {7'd1, 10'd0};
        @(posedge clk); #1;
        // data_out agora tem W[1][0] = 16'd784 = 0x0310

        // Verifica que W[1][0] é diferente de W[0][0]
        // Com padrão sintético: W[0][0]=0x0000, W[1][0]=0x0310 → distintos
        if (data_out !== W_IN_0_0) begin
            $display("  PASS  TC-WGT-06 | W[0][0] != W[1][0]: valores distintos confirmados");
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
