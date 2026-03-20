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
//   CALC_OUTPUT → calcula 10 scores de saída (MAC + PWL)
//   ARGMAX      → encontra o índice do maior score
//   DONE        → resultado disponível por 1 ciclo
//   ERROR       → overflow detectado, aguarda reset
//
// Contadores internos:
//   j [9:0]  → índice de pixel    (0..783) em LOAD_IMG e CALC_HIDDEN
//   i [6:0]  → índice de neurônio (0..127) em CALC_HIDDEN e CALC_OUTPUT
//   k [3:0]  → índice de classe   (0..9)   em CALC_OUTPUT
//
// Referência: test_spec_fsm_regbank.md — Módulo 2 (TC-FSM-01 a TC-FSM-18)
// =============================================================================

module fsm_ctrl (
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
    output reg   [6:0] addr_hidden,   // endereço ram_hidden = i
    output reg  [16:0] addr_w,        // endereço rom_pesos = {i, j}
    output reg   [6:0] addr_bias,     // endereço rom_bias  = i
    output reg  [10:0] addr_beta,     // endereço rom_beta  = {k, i}

    // -------------------------------------------------------------------------
    // Sinais de controle para o datapath
    // -------------------------------------------------------------------------
    output reg         mac_en,        // habilita acumulação na MAC
    output reg         mac_clr,       // limpa acumulador (entre neurônios)
    output reg         h_capture,     // captura saída PWL em ram_hidden
    output reg         argmax_en,     // habilita comparação no argmax

    // -------------------------------------------------------------------------
    // Sinais de status para o reg_bank
    // -------------------------------------------------------------------------
    output reg   [1:0] status_out,    // IDLE/BUSY/DONE/ERROR
    output reg   [3:0] result_out,    // dígito previsto (0..9)
    output reg  [31:0] cycles_out,    // contador de ciclos
    output reg         done_out       // pulso: inferência concluída
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

    reg  [9:0] j;    // contador de pixels    (0..783)
    reg  [6:0] i;    // contador de neurônios (0..127)
    reg  [3:0] k;    // contador de classes   (0..9)

    // =========================================================================
    // BLOCO 1 — Sequencial
    // Atualiza current_state, contadores e saídas registradas a cada borda.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n || reset) begin
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

                LOAD_IMG: begin
                    if (j < 783)
                        j <= j + 1;
                    else
                        j <= 0;
                end

                CALC_HIDDEN: begin
                    if (j < 783) begin
                        j <= j + 1;
                    end else begin
                        j <= 0;
                        if (i < 127)
                            i <= i + 1;
                        else
                            i <= 0;
                    end
                end

                CALC_OUTPUT: begin
                    if (i < 127) begin
                        i <= i + 1;
                    end else begin
                        i <= 0;
                        if (k < 9)
                            k <= k + 1;
                        else
                            k <= 0;
                    end
                end

                // -------------------------------------------------------------
                // CORREÇÃO (BUG 2): done_out e result_out devem ser capturados
                // no estado ARGMAX — quando argmax_done=1 — para que fiquem
                // disponíveis no mesmo ciclo em que current_state se torna DONE.
                //
                // Fluxo correto:
                //   posedge com argmax_done=1 (cs=ARGMAX):
                //     BLOCO2 → next_state = DONE
                //     BLOCO1 → done_out <= 1, result_out <= max_idx
                //   Após posedge: cs=DONE, done_out=1, result_out=max_idx  ✓
                //
                // Fluxo INCORRETO (original):
                //   posedge com argmax_done=1 (cs=ARGMAX):
                //     BLOCO1 → default → done_out <= 0  (nada acontece)
                //   Após posedge: cs=DONE, done_out=0  ← verificação falha
                //   Próximo posedge (cs=DONE):
                //     BLOCO1 → done_out <= 1  (um ciclo atrasado!)
                // -------------------------------------------------------------
                ARGMAX: begin
                    if (argmax_done) begin
                        result_out <= max_idx;  // captura enquanto cs=ARGMAX
                        done_out   <= 1;        // disponível quando cs=DONE
                    end
                end

                // -------------------------------------------------------------
                // DONE: limpa done_out após 1 ciclo (comportamento de pulso).
                // result_out mantém o valor para leitura pelo ARM.
                // -------------------------------------------------------------
                DONE: begin
                    done_out <= 0;
                end

                default: begin
                    done_out <= 0;
                end

            endcase

            // -----------------------------------------------------------------
            // Contador de ciclos (CYCLES)
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

        if (overflow && current_state != IDLE && current_state != DONE
                     && current_state != ERROR) begin
            next_state = ERROR;

        end else begin
            case (current_state)

                IDLE: begin
                    if (start)
                        next_state = LOAD_IMG;
                    else
                        next_state = IDLE;
                end

                LOAD_IMG: begin
                    if (j == 783)
                        next_state = CALC_HIDDEN;
                    else
                        next_state = LOAD_IMG;
                end

                CALC_HIDDEN: begin
                    if (i == 127 && j == 783)
                        next_state = CALC_OUTPUT;
                    else
                        next_state = CALC_HIDDEN;
                end

                CALC_OUTPUT: begin
                    if (k == 9 && i == 127)
                        next_state = ARGMAX;
                    else
                        next_state = CALC_OUTPUT;
                end

                ARGMAX: begin
                    if (argmax_done)
                        next_state = DONE;
                    else
                        next_state = ARGMAX;
                end

                DONE: begin
                    next_state = IDLE;
                end

                ERROR: begin
                    next_state = ERROR;
                end

                default: next_state = IDLE;

            endcase
        end
    end

    // =========================================================================
    // BLOCO 3 — Combinacional: gera sinais de controle por estado
    // =========================================================================
    always @(*) begin

        we_img_fsm  = 0;
        addr_img    = j;
        we_hidden   = 0;
        addr_hidden = i;
        addr_w      = {i, j};
        addr_bias   = i;
        addr_beta   = {k, i};
        mac_en      = 0;
        mac_clr     = 0;
        h_capture   = 0;
        argmax_en   = 0;
        status_out  = STATUS_IDLE;

        case (current_state)

            IDLE: begin
                status_out = STATUS_IDLE;
            end

            LOAD_IMG: begin
                we_img_fsm = 1;
                status_out = STATUS_BUSY;
            end

            CALC_HIDDEN: begin
                mac_en     = 1;
                status_out = STATUS_BUSY;

                if (j == 783) begin
                    mac_clr   = 1;
                    we_hidden = 1;
                    h_capture = 1;
                end
            end

            CALC_OUTPUT: begin
                mac_en     = 1;
                status_out = STATUS_BUSY;

                if (i == 127) begin
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

endmodule