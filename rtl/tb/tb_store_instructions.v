// =============================================================================
// tb_store_instructions.v
// Testbench isolado para as instruções de carga de parâmetros:
//   STORE_WEIGHTS (0x14), STORE_BIAS (0x18), STORE_BETA (0x1C)
//
// Notas de timing (Icarus Verilog):
//   As memórias usam non-blocking assignments (<=) em always @(posedge clk).
//   NBAs são agendadas no active region e efetivadas no NBA region do mesmo
//   timestep. Verificações de mem[] via acesso hierárquico devem ocorrer
//   APÓS o NBA region, ou seja, após #1 do posedge que dispara a escrita.
//
//   Cadeia de latência para cada write MMIO:
//     Posedge N   : reg_bank registra we_out, waddr, wdata (NBC→NBA)
//     Posedge N+1 : ram_X escreve mem[waddr]←wdata (NBA)
//     #1 após N+1 : mem[] visível via hierarquia ← ponto seguro para check
//
//   Por isso, a tarefa check_after_write() aguarda 2 posedges + #1.
// =============================================================================

`timescale 1ns/1ps

module tb_store_instructions;

    // =========================================================================
    // Parâmetros
    // =========================================================================
    localparam CLK_PERIOD = 20;  // 50 MHz

    localparam ADDR_CTRL    = 32'h00;
    localparam ADDR_WEIGHTS = 32'h14;
    localparam ADDR_BIAS    = 32'h18;
    localparam ADDR_BETA    = 32'h1C;

    // =========================================================================
    // Sinais
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg  [31:0] addr;
    reg         write_en;
    reg         read_en;
    reg  [31:0] data_in;
    wire [31:0] data_out;

    wire        we_pesos;
    wire [16:0] waddr_pesos;
    wire [15:0] wdata_pesos;

    wire        we_bias;
    wire  [6:0] waddr_bias;
    wire [15:0] wdata_bias;

    wire        we_beta;
    wire [10:0] waddr_beta;
    wire [15:0] wdata_beta;

    integer pass_count;
    integer fail_count;

    // =========================================================================
    // Instâncias
    // =========================================================================
    reg_bank u_reg_bank (
        .clk          (clk),
        .rst_n        (rst_n),
        .addr         (addr),
        .write_en     (write_en),
        .read_en      (read_en),
        .data_in      (data_in),
        .status_in    (2'b00),
        .pred_in      (4'b0000),
        .cycles_in    (32'b0),
        .data_out     (data_out),
        .start_out    (),
        .reset_out    (),
        .pixel_addr   (),
        .pixel_data   (),
        .we_img_out   (),
        .we_pesos_out (we_pesos),
        .waddr_pesos  (waddr_pesos),
        .wdata_pesos  (wdata_pesos),
        .we_bias_out  (we_bias),
        .waddr_bias   (waddr_bias),
        .wdata_bias   (wdata_bias),
        .we_beta_out  (we_beta),
        .waddr_beta   (waddr_beta),
        .wdata_beta   (wdata_beta)
    );

    ram_pesos u_ram_pesos (
        .clk      (clk),
        .addr_r   (17'b0),
        .data_out (),
        .we_w     (we_pesos),
        .addr_w   (waddr_pesos),
        .data_w   (wdata_pesos)
    );

    ram_bias u_ram_bias (
        .clk      (clk),
        .addr_r   (7'b0),
        .data_out (),
        .we_w     (we_bias),
        .addr_w   (waddr_bias),
        .data_w   (wdata_bias)
    );

    ram_beta u_ram_beta (
        .clk      (clk),
        .addr_r   (11'b0),
        .data_out (),
        .we_w     (we_beta),
        .addr_w   (waddr_beta),
        .data_w   (wdata_beta)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Tarefas
    // =========================================================================

    // Escreve via MMIO e retorna após o posedge que captura o write
    task mmio_write;
        input [31:0] a;
        input [31:0] d;
        begin
            @(negedge clk);
            addr     = a;
            data_in  = d;
            write_en = 1'b1;
            read_en  = 1'b0;
            @(posedge clk);   // posedge N: reg_bank captura e agenda NBAs
            #1;
            write_en = 1'b0;
        end
    endtask

    // Escreve e aguarda a memória estabilizar antes de retornar.
    //   Posedge N   : reg_bank registra we_out, waddr, wdata
    //   Posedge N+1 : ram escreve mem[addr] via NBA
    //   #1          : NBA efetivada — mem[] seguro para leitura hierárquica
    task mmio_write_and_wait;
        input [31:0] a;
        input [31:0] d;
        begin
            mmio_write(a, d);
            @(posedge clk);   // posedge N+1: ram escreve mem
            #1;               // aguarda NBA region completar
        end
    endtask

    task check;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                $display("  PASS | %s | got=0x%04h expected=0x%04h",
                         name, got, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL | %s | got=0x%04h expected=0x%04h",
                         name, got, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Sequência de testes
    // =========================================================================
    integer i;

    initial begin
        pass_count = 0;
        fail_count = 0;
        rst_n    = 0;
        write_en = 0;
        read_en  = 0;
        addr     = 0;
        data_in  = 0;

        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =====================================================================
        // TC-STR-01: STORE_WEIGHTS — primeiros 2 writes
        // =====================================================================
        $display("\n[TC-STR-01] STORE_WEIGHTS — primeiros 2 writes");

        mmio_write_and_wait(ADDR_WEIGHTS, 32'h00001234);
        check("W[0][0]", u_ram_pesos.mem[17'h00000], 16'h1234);

        mmio_write_and_wait(ADDR_WEIGHTS, 32'h00005678);
        check("W[0][1]", u_ram_pesos.mem[17'h00001], 16'h5678);

        // =====================================================================
        // TC-STR-02: STORE_WEIGHTS — rollover pixel→neurônio
        //
        // Ponteiro está em (neuron=0, pixel=2).
        // Avança pixels 2..782 com valor qualquer (781 writes).
        // Escreve pixel=783: deve rodar pixel para 0 e avançar neuron para 1.
        // Escreve W[1][0] e verifica.
        // =====================================================================
        $display("\n[TC-STR-02] STORE_WEIGHTS — rollover pixel->neuronio");

        for (i = 2; i <= 782; i = i + 1)
            mmio_write(ADDR_WEIGHTS, 32'h0000BEEF);

        // Write em pixel=783 — deve avançar neuron
        mmio_write_and_wait(ADDR_WEIGHTS, 32'h0000ABCD);
        check("W[0][783]", u_ram_pesos.mem[{7'd0, 10'd783}], 16'hABCD);

        // Próximo write vai para W[1][0]
        mmio_write_and_wait(ADDR_WEIGHTS, 32'h00001111);
        check("W[1][0]", u_ram_pesos.mem[{7'd1, 10'd0}], 16'h1111);

        // =====================================================================
        // TC-STR-03: STORE_WEIGHTS — saturação após W[127][783]
        //
        // Ponteiro está em (neuron=1, pixel=1).
        // Posições restantes até W[127][782] (sem incluir W[127][783]):
        //   neuron 1, pixels 1..783 : 783 writes  → chega em (2, 0)
        //   neurônios 2..126        : 125×784 = 98000 writes → chega em (127, 0)
        //   neuron 127, pixels 0..782 : 783 writes → chega em (127, 783)
        //   Total: 783 + 98000 + 783 = 99566 writes
        //
        // Depois: write explícito em W[127][783]=0xFFFF (último válido).
        // Depois: write extra deve ser ignorado (saturação).
        // =====================================================================
        $display("\n[TC-STR-03] STORE_WEIGHTS — saturacao");

        for (i = 0; i < 99566; i = i + 1)
            mmio_write(ADDR_WEIGHTS, 32'h0000CCCC);

        // Último write válido
        mmio_write_and_wait(ADDR_WEIGHTS, 32'h0000FFFF);
        check("W[127][783] ultimo", u_ram_pesos.mem[{7'd127, 10'd783}], 16'hFFFF);

        // Write extra — deve ser ignorado (w_done=1)
        mmio_write_and_wait(ADDR_WEIGHTS, 32'h00000000);
        check("W[127][783] pos-sat", u_ram_pesos.mem[{7'd127, 10'd783}], 16'hFFFF);

        // =====================================================================
        // TC-STR-04: STORE_BIAS — primeiros 2 writes
        // =====================================================================
        $display("\n[TC-STR-04] STORE_BIAS — primeiros 2 writes");

        mmio_write_and_wait(ADDR_BIAS, 32'h0000AAAA);
        check("b[0]", u_ram_bias.mem[7'd0], 16'hAAAA);

        mmio_write_and_wait(ADDR_BIAS, 32'h0000BBBB);
        check("b[1]", u_ram_bias.mem[7'd1], 16'hBBBB);

        // =====================================================================
        // TC-STR-05: STORE_BIAS — saturação após b[127]
        //
        // Ponteiro em 2. Avança até b[126] (125 writes), depois escreve
        // b[127] explicitamente. Write extra deve ser ignorado.
        // =====================================================================
        $display("\n[TC-STR-05] STORE_BIAS — saturacao");

        for (i = 2; i <= 126; i = i + 1)
            mmio_write(ADDR_BIAS, 32'h00001234);

        mmio_write_and_wait(ADDR_BIAS, 32'h00005555);
        check("b[127] ultimo", u_ram_bias.mem[7'd127], 16'h5555);

        mmio_write_and_wait(ADDR_BIAS, 32'h00000000);
        check("b[127] pos-sat", u_ram_bias.mem[7'd127], 16'h5555);

        // =====================================================================
        // TC-STR-06: STORE_BETA — primeiros 2 writes
        // =====================================================================
        $display("\n[TC-STR-06] STORE_BETA — primeiros 2 writes");

        mmio_write_and_wait(ADDR_BETA, 32'h00002222);
        check("beta[0][0]", u_ram_beta.mem[11'd0], 16'h2222);

        mmio_write_and_wait(ADDR_BETA, 32'h00003333);
        check("beta[0][1]", u_ram_beta.mem[11'd1], 16'h3333);

        // =====================================================================
        // TC-STR-07: STORE_BETA — rollover β[0][127] → β[1][0]
        //
        // Ponteiro em 2. Avança até beta[0][126] (125 writes),
        // escreve beta[0][127] e verifica, depois beta[1][0] e verifica.
        // =====================================================================
        $display("\n[TC-STR-07] STORE_BETA — rollover classe 0->1");

        for (i = 2; i <= 126; i = i + 1)
            mmio_write(ADDR_BETA, 32'h0000DDDD);

        mmio_write_and_wait(ADDR_BETA, 32'h00004444);
        check("beta[0][127]", u_ram_beta.mem[11'd127], 16'h4444);

        mmio_write_and_wait(ADDR_BETA, 32'h00006666);
        check("beta[1][0]", u_ram_beta.mem[11'd128], 16'h6666);

        // =====================================================================
        // TC-STR-08: STORE_BETA — saturação após β[9][127]
        //
        // Ponteiro em 129. Posições restantes até beta[1278] (sem incluir 1279):
        //   1279 - 129 - 1 = 1149 writes → chega em ptr=1278
        // Depois: write explícito em beta[1279]=0x7777 (último válido).
        // Depois: write extra deve ser ignorado.
        // =====================================================================
        $display("\n[TC-STR-08] STORE_BETA — saturacao");

        for (i = 0; i < 1150; i = i + 1)
            mmio_write(ADDR_BETA, 32'h0000EEEE);

        // Último write válido
        mmio_write_and_wait(ADDR_BETA, 32'h00007777);
        check("beta[9][127] ultimo", u_ram_beta.mem[11'd1279], 16'h7777);

        // Write extra — deve ser ignorado
        mmio_write_and_wait(ADDR_BETA, 32'h00000000);
        check("beta[9][127] pos-sat", u_ram_beta.mem[11'd1279], 16'h7777);

        // =====================================================================
        // TC-STR-09: Reset de ponteiros via CTRL bit[1]=1
        // =====================================================================
        $display("\n[TC-STR-09] Reset de ponteiros via CTRL");
        mmio_write(ADDR_CTRL, 32'h00000002);
        repeat(2) @(posedge clk);

        // =====================================================================
        // TC-STR-10: Write após reset recarrega posição 0 de cada memória
        // =====================================================================
        $display("\n[TC-STR-10] Write apos reset recarrega posicao 0");

        mmio_write_and_wait(ADDR_WEIGHTS, 32'h0000CAFE);
        check("W[0][0] pos-reset", u_ram_pesos.mem[17'h00000], 16'hCAFE);

        mmio_write_and_wait(ADDR_BIAS, 32'h0000BABE);
        check("b[0] pos-reset", u_ram_bias.mem[7'd0], 16'hBABE);

        mmio_write_and_wait(ADDR_BETA, 32'h0000FACE);
        check("beta[0][0] pos-reset", u_ram_beta.mem[11'd0], 16'hFACE);

        // =====================================================================
        // Sumário
        // =====================================================================
        $display("\n==============================================");
        $display("  RESULTADO: %0d passed, %0d failed", pass_count, fail_count);
        $display("==============================================\n");
        if (fail_count == 0)
            $display("  Todos os testes passaram.");
        else
            $display("  ATENCAO: %0d teste(s) falharam.", fail_count);

        $finish;
    end

    initial begin
        #100_000_000;
        $display("[TIMEOUT] Simulacao travada.");
        $finish;
    end

    initial begin
        $dumpfile("tb_store_instructions.vcd");
        $dumpvars(0, tb_store_instructions);
    end

endmodule
