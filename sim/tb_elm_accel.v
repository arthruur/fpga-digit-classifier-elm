// =============================================================================
// tb_elm_accel.v — Testbench de integração end-to-end
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1 · Marco 1 / Fase 5
//
// Simula o ARM/HPS realizando uma inferência completa via MMIO:
//   1. Carrega 784 pixels em ram_img (via registrador IMG)
//   2. Dispara START (via registrador CTRL)
//   3. Faz polling em STATUS até DONE
//   4. Lê RESULT e compara com pred_ref.hex (golden model)
//
// Pré-requisitos (arquivos no mesmo diretório ou em sim/):
//   img_test.hex  — 784 pixels gerados por elm_golden.py
//   pred_ref.hex  — dígito esperado gerado por elm_golden.py
//   w_in.hex      — pesos W_in em Q4.12
//   bias.hex      — biases b em Q4.12
//   beta.hex      — pesos beta em Q4.12 (layout: neuron*10 + class)
//
// Como compilar e simular (da pasta sim/ com os hex presentes):
//   iverilog -o tb_elm_accel \
//       ../rtl/tb/tb_elm_accel.v \
//       ../rtl/elm_accel.v \
//       ../rtl/fsm_regbank/fsm_ctrl.v \
//       ../rtl/fsm_regbank/reg_bank.v \
//       ../rtl/datapath/mac_unit.v \
//       ../rtl/datapath/pwl_activation.v \
//       ../rtl/datapath/argmax_block.v \
//       ../rtl/memory/ram_img.v \
//       ../rtl/memory/rom_pesos.v \
//       ../rtl/memory/rom_bias.v \
//       ../rtl/memory/rom_beta.v \
//       ../rtl/memory/ram_hidden.v
//   vvp tb_elm_accel
// =============================================================================

`timescale 1ns/1ps

module tb_elm_accel;

    // =========================================================================
    // Parâmetros de configuração
    // =========================================================================
    localparam N_PIXELS   = 784;
    localparam CLK_HALF   = 5;          // 10 ns de período → 100 MHz
    localparam TIMEOUT    = 200_000;    // ciclos máximos antes de falha

    // Offsets MMIO — espelham reg_bank.v
    localparam ADDR_CTRL   = 32'h00;
    localparam ADDR_STATUS = 32'h04;
    localparam ADDR_IMG    = 32'h08;
    localparam ADDR_RESULT = 32'h0C;
    localparam ADDR_CYCLES = 32'h10;

    // Codificação de STATUS[1:0]
    localparam STATUS_IDLE  = 2'b00;
    localparam STATUS_BUSY  = 2'b01;
    localparam STATUS_DONE  = 2'b10;
    localparam STATUS_ERROR = 2'b11;

    // =========================================================================
    // Sinais de interface com o DUT
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg  [31:0] addr;
    reg         write_en;
    reg         read_en;
    reg  [31:0] data_in;
    wire [31:0] data_out;

    // =========================================================================
    // Instância do DUT
    // =========================================================================
    elm_accel dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (addr),
        .write_en (write_en),
        .read_en  (read_en),
        .data_in  (data_in),
        .data_out (data_out)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // Memórias auxiliares do testbench
    // =========================================================================
    reg  [7:0] img_mem   [0:N_PIXELS-1];   // pixels carregados de img_test.hex
    reg  [3:0] pred_ref  [0:0];            // predição esperada de pred_ref.hex

    // =========================================================================
    // Contadores e variáveis de controle
    // =========================================================================
    integer pass_count;
    integer fail_count;
    integer i;
    integer poll_count;
    reg [31:0] status_read;
    reg [31:0] result_read;
    reg [31:0] cycles_read;

    // =========================================================================
    // Tasks auxiliares
    // =========================================================================

    // Avança 1 ciclo de clock
    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    // Escreve um valor no barramento MMIO
    task mmio_write;
        input [31:0] a;
        input [31:0] d;
        begin
            @(posedge clk); #1;
            addr     = a;
            data_in  = d;
            write_en = 1;
            read_en  = 0;
            @(posedge clk); #1;
            write_en = 0;
            addr     = 0;
            data_in  = 0;
        end
    endtask

    // Lê um valor do barramento MMIO
    task mmio_read;
        input  [31:0] a;
        output [31:0] d;
        begin
            @(posedge clk); #1;
            addr    = a;
            read_en = 1;
            write_en= 0;
            #1;             // lógica combinacional — disponível imediatamente
            d = data_out;
            @(posedge clk); #1;
            read_en = 0;
            addr    = 0;
        end
    endtask

    // Reset completo do sistema
    task do_reset;
        begin
            rst_n    = 0;
            write_en = 0;
            read_en  = 0;
            addr     = 0;
            data_in  = 0;
            tick; tick;
            rst_n = 1;
            tick;
        end
    endtask

    // =========================================================================
    // Sequência principal
    // =========================================================================
    initial begin
        $dumpfile("tb_elm_accel.vcd");
        $dumpvars(0, tb_elm_accel);

        pass_count = 0;
        fail_count = 0;

        // ── Carregar arquivos de referência ───────────────────────────────────
        $readmemh("img_test.hex",  img_mem);
        $readmemh("pred_ref.hex",  pred_ref);

        $display("=====================================================");
        $display(" tb_elm_accel — Inferência End-to-End");
        $display(" Dígito esperado (golden model): %0d", pred_ref[0]);
        $display("=====================================================");

        // ── Fase 0: Reset ─────────────────────────────────────────────────────
        $display("\n[FASE 0] Reset do sistema...");
        do_reset;
        $display("  OK — sistema em IDLE");

        // ── Fase 1: Carregar imagem via MMIO ──────────────────────────────────
        // Protocolo: escrever em IMG com data_in = {14'b0, pixel_data, pixel_addr}
        //   bits[9:0]  = endereço do pixel (0..783)
        //   bits[17:10]= valor do pixel (0..255)
        $display("\n[FASE 1] Carregando %0d pixels via MMIO (IMG)...", N_PIXELS);
        for (i = 0; i < N_PIXELS; i = i + 1) begin
            mmio_write(
                ADDR_IMG,
                {14'b0, img_mem[i], i[9:0]}
            );
        end
        $display("  OK — %0d pixels escritos em ram_img", N_PIXELS);

        // ── Fase 2: Disparar START ────────────────────────────────────────────
        $display("\n[FASE 2] Disparando START (CTRL[0]=1)...");
        mmio_write(ADDR_CTRL, 32'h00000001);   // start=1
        mmio_write(ADDR_CTRL, 32'h00000000);   // start=0 (limpa o pulso)
        $display("  OK — START enviado");

        // ── Fase 3: Polling em STATUS até DONE ou ERROR ───────────────────────
        $display("\n[FASE 3] Aguardando DONE (polling em STATUS)...");
        poll_count = 0;
        status_read = 0;

        while (status_read[1:0] == STATUS_IDLE ||
               status_read[1:0] == STATUS_BUSY) begin

            mmio_read(ADDR_STATUS, status_read);
            poll_count = poll_count + 1;

            if (poll_count >= TIMEOUT) begin
                $display("  TIMEOUT — STATUS nunca chegou em DONE após %0d polls",
                         TIMEOUT);
                $display("  Último STATUS lido: %02b", status_read[1:0]);
                fail_count = fail_count + 1;
                $finish;
            end

            // Imprime progresso a cada 10.000 ciclos de polling
            if (poll_count % 10000 == 0)
                $display("  ... %0d polls, STATUS=%02b",
                         poll_count, status_read[1:0]);
        end

        if (status_read[1:0] == STATUS_ERROR) begin
            $display("  ERRO — FSM entrou no estado ERROR durante inferência");
            $display("  Verifique overflow da MAC ou sinal de controle inválido");
            fail_count = fail_count + 1;
            $finish;
        end

        $display("  OK — DONE detectado após %0d polls", poll_count);

        // ── Fase 4: Ler RESULT e CYCLES ───────────────────────────────────────
        $display("\n[FASE 4] Lendo resultados...");
        mmio_read(ADDR_RESULT, result_read);
        mmio_read(ADDR_CYCLES, cycles_read);
        mmio_read(ADDR_STATUS, status_read);

        $display("  RESULT  = %0d", result_read[3:0]);
        $display("  CYCLES  = %0d  (≈ %0.3f ms a 50 MHz)",
                 cycles_read,
                 $itor(cycles_read) / 50000.0);
        $display("  STATUS  = %02b  (pred nos bits [5:2] = %0d)",
                 status_read[1:0], status_read[5:2]);

        // ── Fase 5: Verificação ───────────────────────────────────────────────
        $display("\n[FASE 5] Verificando resultado...");
        $display("  Hardware prediz : %0d", result_read[3:0]);
        $display("  Golden model    : %0d", pred_ref[0]);

        if (result_read[3:0] === pred_ref[0]) begin
            $display("\n  [PASS] pred_hardware == pred_golden (%0d)", pred_ref[0]);
            pass_count = pass_count + 1;
        end else begin
            $display("\n  [FAIL] pred_hardware=%0d != pred_golden=%0d",
                     result_read[3:0], pred_ref[0]);
            fail_count = fail_count + 1;
        end

        // ── Resumo ────────────────────────────────────────────────────────────
        $display("\n=====================================================");
        $display(" RESULTADO: %0d PASS  /  %0d FAIL",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display(" STATUS: INTEGRAÇÃO VALIDADA");
        else
            $display(" STATUS: FALHA — verificar waveform em tb_elm_accel.vcd");
        $display("=====================================================\n");

        $finish;
    end

endmodule