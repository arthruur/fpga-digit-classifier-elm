// =============================================================================
// tb_full_flow.v
// Testbench de fluxo completo do elm_accel
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Exercita o sistema do início ao fim exatamente como o driver fará no Marco 2:
//   1. Reset do hardware
//   2. STORE_WEIGHTS — 100.352 writes via MMIO (0x14)
//   3. STORE_BIAS    — 128 writes via MMIO (0x18)
//   4. STORE_BETA    — 1.280 writes via MMIO (0x1C)
//   5. STORE_IMG     — 784 writes via MMIO (0x08)
//   6. START         — escreve CTRL bit[0]=1 (0x00)
//   7. Polling       — lê STATUS (0x04) até DONE
//   8. Verificação   — lê RESULT (0x0C) e compara com golden model
//   9. Repete inferência para confirmar estabilidade (mesma imagem, N vezes)
//
// Arquivos de entrada necessários (mesmos do golden model):
//   w_in.hex    — pesos W_in  (131.072 entradas, layout padded)
//   bias.hex    — biases b    (128 entradas)
//   beta.hex    — pesos β     (1.280 entradas)
//   img_test.hex — imagem de teste (784 entradas, 1 byte/pixel)
//
// Configuração:
//   Ajuste EXPECTED_PRED com a predição do golden model para a imagem de teste.
//   Ajuste N_STABILITY_RUNS para quantas re-inferências verificar estabilidade.
//
// Estimativa de ciclos de simulação:
//   STORE_WEIGHTS : 100.352 ciclos
//   STORE_BIAS    :     128 ciclos
//   STORE_BETA    :   1.280 ciclos
//   STORE_IMG     :     784 ciclos
//   Inferência    : ~102.048 ciclos (medido nos testes anteriores)
//   Overhead      :     ~100 ciclos
//   Total (1 run) : ~205.000 ciclos × 20 ns ≈ 4 ms simulado
//   A 50 MHz, ModelSim/QuestaSim completa em poucos segundos de wall-clock.
// =============================================================================

`timescale 1ns/1ps

module tb_full_flow;

    // =========================================================================
    // Parâmetros configuráveis
    // =========================================================================
    parameter EXPECTED_PRED    = 4'd3;   // altere conforme o golden model
    parameter N_STABILITY_RUNS = 3;      // re-inferências para teste de estabilidade

    localparam CLK_PERIOD = 20;          // 50 MHz

    // Offsets MMIO
    localparam ADDR_CTRL    = 32'h00;
    localparam ADDR_STATUS  = 32'h04;
    localparam ADDR_IMG     = 32'h08;
    localparam ADDR_RESULT  = 32'h0C;
    localparam ADDR_CYCLES  = 32'h10;
    localparam ADDR_WEIGHTS = 32'h14;
    localparam ADDR_BIAS    = 32'h18;
    localparam ADDR_BETA    = 32'h1C;

    // Codificação de STATUS
    localparam STATUS_IDLE  = 2'b00;
    localparam STATUS_BUSY  = 2'b01;
    localparam STATUS_DONE  = 2'b10;
    localparam STATUS_ERROR = 2'b11;

    // Limites dos ponteiros
    localparam N_NEURONS = 128;
    localparam N_PIXELS  = 784;
    localparam N_CLASSES = 10;
    localparam N_BETA    = N_NEURONS * N_CLASSES;  // 1280

    // =========================================================================
    // Sinais do DUT
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg  [31:0] addr;
    reg         write_en;
    reg         read_en;
    reg  [31:0] data_in;
    wire [31:0] data_out;

    // =========================================================================
    // Arrays temporários para os arquivos de pesos
    //
    // w_in_padded: 131.072 entradas (layout padded {neuron[6:0], pixel[9:0]})
    //   O hex file já está nesse formato — neurônio n ocupa posições
    //   n*1024 a n*1024+783; posições n*1024+784 a n*1024+1023 são zero.
    //
    // Nota: esses arrays existem APENAS no testbench (simulação).
    //   Em síntese, os dados chegam via MMIO — não há $readmemh no RTL.
    // =========================================================================
    reg [15:0] w_in_padded [0:131071];
    reg [15:0] bias_arr    [0:127];
    reg [15:0] beta_arr    [0:1279];
    reg  [7:0] img_arr     [0:783];

    // =========================================================================
    // Contadores globais
    // =========================================================================
    integer pass_count;
    integer fail_count;
    integer run;

    // =========================================================================
    // Instância do DUT — elm_accel completo
    //
    // PRELOADED_IMG=0: imagem chega via MMIO (fluxo real do driver)
    // INIT_FILE="":    ram_img começa vazia (escrita via STORE_IMG)
    // =========================================================================
    elm_accel #(
        .INIT_FILE     (""),
        .PRELOADED_IMG (0)
    ) u_dut (
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
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Tarefas auxiliares
    // =========================================================================

    // Escreve um valor no barramento MMIO (1 ciclo)
    task mmio_write;
        input [31:0] a;
        input [31:0] d;
        begin
            @(negedge clk);
            addr     = a;
            data_in  = d;
            write_en = 1'b1;
            read_en  = 1'b0;
            @(posedge clk);
            #1;
            write_en = 1'b0;
        end
    endtask

    // Lê um valor do barramento MMIO
    // reg_bank tem latência de 1 ciclo na leitura (pipeline)
    // [CORREÇÃO] read_en mantido em ALTO até a amostragem do dado ser concluída
    task mmio_read;
        input  [31:0] a;
        output [31:0] d;
        begin
            @(negedge clk);
            addr     = a;
            write_en = 1'b0;
            read_en  = 1'b1;      // Levanta o pedido de leitura

            @(posedge clk);       // Ciclo 1: reg_bank registra o pedido
            @(posedge clk);       // Ciclo 2: dado fica disponível no data_out
            #1;

            d = data_out;         // Lê o dado PRIMEIRO...
            read_en  = 1'b0;      // ...e só depois abaixa o sinal!
        end
    endtask

    // Verifica um valor e atualiza contadores
    task check;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                $display("  PASS | %s | got=%0d expected=%0d", name, got, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL | %s | got=%0d expected=%0d", name, got, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // Tarefa: carregar STORE_WEIGHTS via MMIO
    // =========================================================================
    task do_store_weights;
        integer n, p;
        begin
            $display("  Carregando STORE_WEIGHTS (%0d writes)...", N_NEURONS * N_PIXELS);
            for (n = 0; n < N_NEURONS; n = n + 1) begin
                for (p = 0; p < N_PIXELS; p = p + 1) begin
                    mmio_write(ADDR_WEIGHTS,
                               {16'b0, w_in_padded[n * 1024 + p]});
                end
            end
            $display("  STORE_WEIGHTS concluido.");
        end
    endtask

    // =========================================================================
    // Tarefa: carregar STORE_BIAS via MMIO
    // =========================================================================
    task do_store_bias;
        integer b;
        begin
            $display("  Carregando STORE_BIAS (%0d writes)...", N_NEURONS);
            for (b = 0; b < N_NEURONS; b = b + 1)
                mmio_write(ADDR_BIAS, {16'b0, bias_arr[b]});
            $display("  STORE_BIAS concluido.");
        end
    endtask

    // =========================================================================
    // Tarefa: carregar STORE_BETA via MMIO
    // =========================================================================
    task do_store_beta;
        integer bt;
        begin
            $display("  Carregando STORE_BETA (%0d writes)...", N_BETA);
            for (bt = 0; bt < N_BETA; bt = bt + 1)
                mmio_write(ADDR_BETA, {16'b0, beta_arr[bt]});
            $display("  STORE_BETA concluido.");
        end
    endtask

    // =========================================================================
    // Tarefa: carregar STORE_IMG via MMIO
    // =========================================================================
    task do_store_img;
        integer px;
        begin
            $display("  Carregando STORE_IMG (%0d writes)...", N_PIXELS);
            for (px = 0; px < N_PIXELS; px = px + 1)
                mmio_write(ADDR_IMG,
                           {14'b0, img_arr[px], px[9:0]});
            $display("  STORE_IMG concluido.");
        end
    endtask

    // =========================================================================
    // Tarefa: executar inferência (START + polling + leitura de resultado)
    // Retorna pred e cycles.
    // =========================================================================
    task do_inference;
        output [3:0]  pred;
        output [31:0] cycles;
        reg    [31:0] status_val;
        reg    [1:0]  status_bits;
        integer       poll_count;
        begin
            // START
            mmio_write(ADDR_CTRL, 32'h00000001);

            // Limpa start (boa prática — evita re-disparo acidental)
            mmio_write(ADDR_CTRL, 32'h00000000);

            // Polling em STATUS até DONE ou ERROR
            poll_count = 0;
            status_bits = STATUS_IDLE;

            while (status_bits != STATUS_DONE && status_bits != STATUS_ERROR) begin
                mmio_read(ADDR_STATUS, status_val);
                status_bits = status_val[1:0];
                poll_count  = poll_count + 1;

                if (poll_count > 500000) begin
                    $display("  [ERRO] Timeout no polling — FSM travada?");
                    $finish;
                end
            end

            if (status_bits == STATUS_ERROR) begin
                $display("  [ERRO] FSM entrou em estado ERROR.");
                pred   = 4'hF;
                cycles = 32'hFFFFFFFF;
            end else begin
                // Lê resultado e ciclos
                mmio_read(ADDR_RESULT, status_val);
                pred = status_val[3:0];
                mmio_read(ADDR_CYCLES, cycles);

                // [CORREÇÃO] Acknowledge/Reset para libertar a FSM do estado pegajoso 'DONE'
                // e fazê-la retornar para 'IDLE' a tempo das próximas repetições
                mmio_write(ADDR_CTRL, 32'h00000002);  // bit[1]=1 → reset
                mmio_write(ADDR_CTRL, 32'h00000000);  // limpa reset
            end
        end
    endtask

    // =========================================================================
    // Sequência principal
    // =========================================================================
    reg  [3:0]  pred_result;
    reg [31:0]  cycles_result;
    integer     stability_ok;

    initial begin
        // -- Inicialização
        pass_count   = 0;
        fail_count   = 0;
        stability_ok = 1;
        write_en     = 0;
        read_en      = 0;
        addr         = 0;
        data_in      = 0;

        // -- Leitura dos arquivos de pesos para os arrays temporários
        $display("\n[SETUP] Lendo arquivos de pesos...");
        $readmemh("w_in.hex",     w_in_padded);
        $readmemh("bias.hex",     bias_arr);
        $readmemh("beta.hex",     beta_arr);
        $readmemh("img_test.hex", img_arr);
        $display("[SETUP] Arquivos carregados.");

        // -- Reset hardware
        $display("\n[RESET] Aplicando reset...");
        rst_n = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[RESET] Concluido.");

        // =====================================================================
        // FASE 1 — Carga de parâmetros via MMIO
        // =====================================================================
        $display("\n[FASE 1] Carga de parametros via MMIO");
        do_store_weights;
        do_store_bias;
        do_store_beta;
        do_store_img;

        // =====================================================================
        // FASE 2 — Primeira inferência
        // =====================================================================
        $display("\n[FASE 2] Primeira inferencia");
        do_inference(pred_result, cycles_result);
        $display("  pred=%0d  cycles=%0d", pred_result, cycles_result);
        check("Predicao correta (run 1)", pred_result, EXPECTED_PRED);
        $display("  Latencia: %0d ciclos = %0.2f us a 50 MHz",
                 cycles_result, cycles_result * 0.02);

        // =====================================================================
        // FASE 3 — Teste de estabilidade
        // Re-executa a inferência N vezes sem recarregar nada.
        // Os pesos nas RAMs persistem entre inferências — apenas STORE_IMG
        // e START são repetidos, como o driver fará na prática.
        // =====================================================================
        $display("\n[FASE 3] Teste de estabilidade (%0d runs)", N_STABILITY_RUNS);
        for (run = 2; run <= N_STABILITY_RUNS + 1; run = run + 1) begin

            // Re-envia a imagem (pesos permanecem nas RAMs)
            do_store_img;

            do_inference(pred_result, cycles_result);
            $display("  Run %0d: pred=%0d cycles=%0d", run, pred_result, cycles_result);

            if (pred_result !== EXPECTED_PRED) begin
                $display("  FAIL | Estabilidade run %0d | got=%0d expected=%0d",
                         run, pred_result, EXPECTED_PRED);
                stability_ok = 0;
                fail_count   = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end

        if (stability_ok)
            $display("  PASS | Sistema estavel em %0d runs consecutivos.",
                     N_STABILITY_RUNS);

        // =====================================================================
        // FASE 4 — Teste de recarregamento
        // Reseta os ponteiros via CTRL reset e recarrega os parâmetros.
        // Verifica que a predição continua correta após recarga completa.
        // =====================================================================
        $display("\n[FASE 4] Teste de recarregamento (reset + recarga completa)");
        mmio_write(ADDR_CTRL, 32'h00000002);  // bit[1]=1 → reset
        @(posedge clk);
        mmio_write(ADDR_CTRL, 32'h00000000);  // limpa reset
        @(posedge clk);

        do_store_weights;
        do_store_bias;
        do_store_beta;
        do_store_img;

        do_inference(pred_result, cycles_result);
        $display("  pred=%0d  cycles=%0d", pred_result, cycles_result);
        check("Predicao correta apos recarregamento", pred_result, EXPECTED_PRED);

        // =====================================================================
        // Sumário final
        // =====================================================================
        $display("\n==============================================");
        $display("  RESULTADO FINAL: %0d passed, %0d failed",
                 pass_count, fail_count);
        $display("==============================================\n");

        if (fail_count == 0)
            $display("  Todos os testes passaram.");
        else
            $display("  ATENCAO: %0d teste(s) falharam.", fail_count);

        $finish;
    end

    // =========================================================================
    // Timeout de segurança
    // 500 ms de tempo simulado cobre qualquer run razoável
    // =========================================================================
    initial begin
        #500_000_000;
        $display("[TIMEOUT] Simulacao nao terminou em 500 ms simulados.");
        $finish;
    end

    // =========================================================================
    // Dump de waveform
    // =========================================================================
    initial begin
        $dumpfile("tb_full_flow.vcd");
        $dumpvars(0, tb_full_flow);
    end

endmodule