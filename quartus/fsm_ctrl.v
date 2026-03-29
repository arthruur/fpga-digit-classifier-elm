// =============================================================================
// Módulo: fsm_ctrl.v
// Função: Máquina de estados de controle do co-processador ELM.
//         Orquestra todos os módulos — memórias, MAC, PWL e argmax —
//         sequenciando os cálculos da inferência completa.
//
// Estados:
//   IDLE        → aguarda start
//   LOAD_IMG    → recebe 784 pixels do ARM via reg_bank
//   CALC_HIDDEN → calcula 128 neurônios ocultos (MAC + PWL)
//   CALC_OUTPUT → calcula 10 scores de saída (MAC)
//   ARGMAX      → encontra o índice do maior score
//   DONE        → resultado disponível por 1 ciclo
//   ERROR       → overflow detectado, aguarda reset
//
// Contadores internos:
//   j [9:0]  → sub-ciclo dentro de LOAD_IMG e CALC_HIDDEN
//              (0 = warmup, 1..N_PIXELS = acumulação pixels,
//               N_PIXELS+1 = bias, N_PIXELS+2 = captura+clear)
//   i [7:0]  → índice de neurônio/classe
//              Em CALC_HIDDEN: 0..(N_NEURONS-1)
//              Em CALC_OUTPUT: sub-ciclo (0 = warmup, 1..N_NEURONS = acum.,
//                               N_NEURONS+1 = captura+clear)
//   k [3:0]  → índice de classe (0..(N_CLASSES-1)) em CALC_OUTPUT
//
// Sequência de ciclos por neurônio — CALC_HIDDEN:
//   j=0             Warmup: endereços apresentados, BRAM carregando — mac_en=0
//   j=1..N_PIXELS   Acumulação: W[i][j-1]×x[j-1] disponíveis — mac_en=1
//   j=N_PIXELS+1    Bias: bias_data disponível, bias_cycle=1 — mac_en=1
//   j=N_PIXELS+2    Captura + Clear: we_hidden=1, mac_clr=1, mac_en=0
//   Total: N_PIXELS + 3 ciclos/neurônio
//
// Sequência de ciclos por classe — CALC_OUTPUT:
//   i=0             Warmup — mac_en=0
//   i=1..N_NEURONS  Acumulação: β[k][i-1]×h[i-1] — mac_en=1
//   i=N_NEURONS+1   Captura y[k] + Clear: mac_clr=1, mac_en=0
//   Total: N_NEURONS + 2 ciclos/classe
//
// Regra inviolável: mac_clr e mac_en nunca podem ser 1 no mesmo ciclo.
//
// Parâmetros reduzidos para simulação (passados pelo testbench):
//   N_PIXELS=8, N_NEURONS=4, N_CLASSES=3 → simulação muito mais rápida.
//
// Referência: test_spec_fsm_regbank.md — Módulo 2 (TC-FSM-01 a TC-FSM-18)
// =============================================================================

module fsm_ctrl #(
    parameter N_PIXELS      = 784,  // pixels por imagem (28×28 = 784)
    parameter N_NEURONS     = 128,  // neurônios ocultos
    parameter N_CLASSES     = 10,   // classes de saída (dígitos 0–9)
    parameter PRELOADED_IMG = 0     // 1 = imagem pré-carregada no bitstream;
                                    //     pula LOAD_IMG e vai direto a CALC_HIDDEN
)(
    input  wire        clk,
    input  wire        rst_n,         // reset assíncrono ativo em baixo

    // Sinais de controle vindos do reg_bank
    input  wire        start,         // pulso: inicia inferência
    input  wire        reset,         // nível: aborta e reinicia
    input  wire        we_img,        // pixel novo disponível na ram_img

    // Sinal de overflow da MAC
    input  wire        overflow,      // 1 = overflow detectado → ERROR

    // Sinal de conclusão do argmax
    input  wire        argmax_done,   // 1 = argmax terminou

    // Resultado do argmax
    input  wire  [3:0] max_idx,       // índice do maior score (0..9)

    // -------------------------------------------------------------------------
    // Sinais de controle para as memórias
    // -------------------------------------------------------------------------
    output reg         we_img_fsm,    // write enable ram_img (durante LOAD_IMG)
    output reg   [9:0] addr_img,      // endereço ram_img = j
    output reg         we_hidden,     // write enable ram_hidden
    output reg   [6:0] addr_hidden,   // endereço ram_hidden = i[6:0]
    output reg  [16:0] addr_w,        // endereço rom_pesos = {i[6:0], j}
    output reg   [6:0] addr_bias,     // endereço rom_bias  = i[6:0]
    output reg  [10:0] addr_beta,     // endereço rom_beta  = ({7'b0, i[6:0]} << 3) + ({7'b0, i[6:0]} << 1) + {7'b0, k};


    // -------------------------------------------------------------------------
    // Sinais de controle para o datapath
    // -------------------------------------------------------------------------
    output reg         mac_en,        // habilita acumulação na MAC
    output reg         mac_clr,       // limpa acumulador (entre neurônios)
    output reg         bias_cycle,    // 1 no ciclo em que mac_a=b[i], mac_b=1.0
                                      // O top-level roteia bias_data→mac_a e
                                      // 16'h1000→mac_b quando este sinal estiver ativo
    output reg         h_capture,     // captura saída PWL em ram_hidden
    output reg         argmax_en,     // habilita comparação no argmax

    // -------------------------------------------------------------------------
    // Sinais de status para o reg_bank
    // -------------------------------------------------------------------------
    output reg   [1:0] status_out,    // IDLE/BUSY/DONE/ERROR
    output reg   [3:0] result_out,    // dígito previsto (0..9)
    output reg  [31:0] cycles_out,    // contador de ciclos
    output reg         done_out,       // pulso: inferência concluída
    output reg        calc_output_active, // 1 quando current_state == CALC_OUTPUT
    output wire [3:0] k_out               // índice de classe atual (0..9)
);

    // =========================================================================
    // Declaração dos estados
    // =========================================================================
    localparam IDLE        = 3'd0;
    localparam LOAD_IMG    = 3'd1;
    localparam CALC_HIDDEN = 3'd2;
    localparam CALC_OUTPUT = 3'd3;
    localparam ARGMAX      = 3'd4;
    localparam DONE        = 3'd5;
    localparam ERROR       = 3'd6;

    // Codificação de STATUS para o reg_bank
    localparam STATUS_IDLE  = 2'b00;
    localparam STATUS_BUSY  = 2'b01;
    localparam STATUS_DONE  = 2'b10;
    localparam STATUS_ERROR = 2'b11;

    // =========================================================================
    // Registradores de estado e contadores
    // =========================================================================
    reg [2:0] current_state;
    reg [2:0] next_state;

    reg  [9:0] j;    // sub-ciclo pixel / fase (0..N_PIXELS+2 em CALC_HIDDEN)
    reg  [7:0] i;    // índice neurônio / sub-ciclo em CALC_OUTPUT (0..N_NEURONS+1)
                     // [7:0] em vez de [6:0]: cobre 0..N_NEURONS+1 = 0..129
    reg  [3:0] k;    // índice de classe (0..N_CLASSES-1)

    // =========================================================================
    // BLOCO 1 — Sequencial
    // Atualiza current_state, contadores e saídas registradas a cada borda.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            // Reset assíncrono (borda de descida de rst_n)
            current_state <= IDLE;
            i             <= 0;
            j             <= 0;
            k             <= 0;
            cycles_out    <= 0;
            result_out    <= 0;
            done_out      <= 0;

        end else if (reset) begin
            // Reset síncrono (sinal reset vindo do reg_bank via MMIO)
            current_state <= IDLE;
            i             <= 0;
            j             <= 0;
            k             <= 0;
            cycles_out    <= 0;
            result_out    <= 0;
            done_out      <= 0;

        end else begin
            current_state <= next_state;

            case (current_state)

                // -------------------------------------------------------------
                // LOAD_IMG: incrementa j de 0 até N_PIXELS-1.
                // Sem incremento de i — i já é zerado pelo reset e só é usado
                // a partir de CALC_HIDDEN.
                // -------------------------------------------------------------
                LOAD_IMG: begin
                    if (j < N_PIXELS - 1)
                        j <= j + 1;
                    else
                        j <= 0;
                end

                // -------------------------------------------------------------
                // CALC_HIDDEN: j percorre 0..N_PIXELS+2 por neurônio.
                //   j=0            warmup
                //   j=1..N_PIXELS  acumulação
                //   j=N_PIXELS+1   bias
                //   j=N_PIXELS+2   captura+clear → reseta j, avança i
                // -------------------------------------------------------------
                CALC_HIDDEN: begin
                    if (j < N_PIXELS + 2) begin
                        j <= j + 1;
                    end else begin
                        j <= 0;
                        if (i < N_NEURONS - 1)
                            i <= i + 1;
                        else
                            i <= 0;
                    end
                end

                // -------------------------------------------------------------
                // CALC_OUTPUT: i percorre 0..N_NEURONS+1 por classe.
                //   i=0              warmup
                //   i=1..N_NEURONS   acumulação
                //   i=N_NEURONS+1    captura y[k] + clear → reseta i, avança k
                // -------------------------------------------------------------
                CALC_OUTPUT: begin
                    if (i < N_NEURONS + 1) begin
                        i <= i + 1;
                    end else begin
                        i <= 0;
                        if (k < N_CLASSES - 1)
                            k <= k + 1;
                        else
                            k <= 0;
                    end
                end

                // -------------------------------------------------------------
                // ARGMAX: captura resultado quando argmax_done=1.
                // done_out e result_out são atribuídos AQUI (quando cs=ARGMAX)
                // para ficarem disponíveis no mesmo ciclo em que cs passa a DONE.
                // -------------------------------------------------------------
                ARGMAX: begin
                    if (argmax_done) begin
                        result_out <= max_idx;
                        done_out   <= 1;
                    end
                end

                DONE: begin
                    done_out <= 0;
                end

                default: begin
                    done_out <= 0;
                end

            endcase

            // -----------------------------------------------------------------
            // Contador de ciclos (CYCLES)
            // Inicia em 0 na transição IDLE→LOAD_IMG.
            // Para de incrementar quando chega em DONE ou IDLE.
            // -----------------------------------------------------------------
            if (current_state == IDLE && next_state == LOAD_IMG)
                cycles_out <= 0;
            else if (current_state != IDLE && current_state != DONE)
                cycles_out <= cycles_out + 1;

        end
    end

    // =========================================================================
    // BLOCO 2 — Combinacional: decide next_state
    // =========================================================================
    always @(*) begin
        next_state = current_state;

        case (current_state)
            IDLE:        next_state = start ? (PRELOADED_IMG ? CALC_HIDDEN : LOAD_IMG) : IDLE;

            LOAD_IMG:    next_state = (j == N_PIXELS - 1)
                                    ? CALC_HIDDEN : LOAD_IMG;

            CALC_HIDDEN: next_state = (i == N_NEURONS - 1 && j == N_PIXELS + 2)
                                    ? CALC_OUTPUT : CALC_HIDDEN;

            CALC_OUTPUT: next_state = (k == N_CLASSES - 1 && i == N_NEURONS + 1)
                                    ? ARGMAX : CALC_OUTPUT;

            ARGMAX:      next_state = argmax_done ? DONE : ARGMAX;

            DONE:        next_state = IDLE;

            ERROR:       next_state = reset ? IDLE : ERROR;

            default:     next_state = IDLE;
        endcase
    end


    // =========================================================================
    // BLOCO 3 — Combinacional: gera sinais de controle por estado
    //
    // Defaults aplicados antes do case — qualquer sinal não sobrescrito no
    // estado ativo assume estes valores.
    // =========================================================================
    always @(*) begin

        // -- Defaults --
        we_img_fsm  = 0;
        addr_img    = j[9:0];
        we_hidden   = 0;
        addr_hidden = i[6:0];
        addr_w      = {i[6:0], j[9:0]};
        addr_bias   = i[6:0];
        addr_beta   = ({4'b0, i[6:0]} << 3)
                        + ({4'b0, i[6:0]} << 1)
                        + {7'b0, k};
        mac_en      = 0;
        mac_clr     = 0;
        bias_cycle  = 0;
        calc_output_active = 0;
        h_capture   = 0;
        argmax_en   = 0;
        status_out  = STATUS_IDLE;

        case (current_state)

            IDLE: begin
                status_out = STATUS_IDLE;
            end

            // -----------------------------------------------------------------
            // LOAD_IMG: ativa we_img_fsm para cada pixel.
            // addr_img = j já está nos defaults.
            // -----------------------------------------------------------------
            LOAD_IMG: begin
                we_img_fsm = 1;
                status_out = STATUS_BUSY;
            end

            // -----------------------------------------------------------------
            // CALC_HIDDEN — 4 fases por ciclo j:
            //
            //   j=0              Warmup: endereços saindo das BRAMs, mac_en=0.
            //                    addr_img=0, addr_w={i,0} (defaults com j=0).
            //
            //   j=1..N_PIXELS    Acumulação: dado de j-1 disponível na BRAM.
            //                    mac_en=1.
            //                    addr_img=j, addr_w={i,j} (defaults) — pré-carrega
            //                    endereço do próximo pixel para o ciclo seguinte.
            //
            //   j=N_PIXELS+1     Bias: addr_bias=i estável → bias_data disponível.
            //                    bias_cycle=1 sinaliza ao top-level para rotear
            //                    bias_data→mac_a e 0x1000→mac_b. mac_en=1.
            //
            //   j=N_PIXELS+2     Captura + Clear:
            //                    acc_out (combinacional no mac_unit) ainda reflete
            //                    sum+bias antes do clr ser efetivado — captura correta.
            //                    we_hidden=1, h_capture=1, mac_clr=1, mac_en=0.
            //
            // INVARIANTE: mac_clr e mac_en nunca são 1 simultaneamente.
            // -----------------------------------------------------------------
            CALC_HIDDEN: begin
                status_out = STATUS_BUSY;

                if (j == 0) begin
                    mac_en  = 0;
                    mac_clr = 0;

                end else if (j <= N_PIXELS) begin
                    mac_en  = 1;
                    mac_clr = 0;

                end else if (j == N_PIXELS + 1) begin
                    // Ciclo de bias
                    bias_cycle = 1;
                    mac_en     = 1;
                    mac_clr    = 0;

                end else begin
                    // j == N_PIXELS + 2: captura + clear
                    we_hidden = 1;
                    h_capture = 1;
                    mac_en    = 0;
                    mac_clr   = 1;
                end
            end

            // -----------------------------------------------------------------
            // CALC_OUTPUT — 3 fases por ciclo i:
            //
            //   i=0              Warmup: endereços saindo da BRAM, mac_en=0.
            //                    addr_hidden=0, addr_beta={k,0} (defaults com i=0).
            //
            //   i=1..N_NEURONS   Acumulação: h[i-1] e β[k][i-1] disponíveis.
            //                    mac_en=1.
            //                    addr_hidden=i, addr_beta={k,i} — pré-carrega
            //                    endereço do próximo neurônio.
            //
            //   i=N_NEURONS+1    Captura y[k] + Clear:
            //                    acc_out ainda reflete y[k] antes do clr.
            //                    A FSM (BLOCO 1) captura acc_out→y[k] neste ciclo
            //                    através do bloco argmax ou de registro interno.
            //                    mac_clr=1, mac_en=0.
            //
            // INVARIANTE: mac_clr e mac_en nunca são 1 simultaneamente.
            // -----------------------------------------------------------------
            CALC_OUTPUT: begin
                calc_output_active = 1;
                status_out = STATUS_BUSY;

                if (i == 0) begin
                    mac_en  = 0;
                    mac_clr = 0;

                end else if (i <= N_NEURONS) begin
                    mac_en  = 1;
                    mac_clr = 0;

                end else begin
                    // i == N_NEURONS + 1: captura y[k] + clear
                    mac_en  = 0;
                    mac_clr = 1;
                end
            end

            ARGMAX: begin
                argmax_en  = 1;
                status_out = STATUS_BUSY;
            end

            DONE: begin
                status_out = STATUS_DONE;
            end

            ERROR: begin
                status_out = STATUS_ERROR;
            end

            default: begin
                status_out = STATUS_IDLE;
            end

        endcase
    end
    assign k_out = k[3:0];

endmodule