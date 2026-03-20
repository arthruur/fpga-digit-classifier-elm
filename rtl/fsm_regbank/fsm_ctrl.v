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
    //
    // "localparam" define constantes locais ao módulo — como #define em C.
    // Usamos 3 bits para representar 7 estados (2³ = 8 possibilidades).
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
    // Atualiza current_state e contadores a cada borda de clock.
    //
    // Este bloco tem DUAS responsabilidades:
    //   1. Transicionar de current_state para next_state
    //   2. Incrementar/zerar os contadores i, j, k conforme o estado
    //
    // Por que os contadores ficam aqui e não no bloco combinacional?
    // Contadores são registradores — precisam do clock para mudar.
    // O bloco combinacional (always @*) não pode ter registradores.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n || reset) begin
            // -----------------------------------------------------------------
            // Reset: volta ao estado inicial e zera tudo
            //
            // "reset" vem do reg_bank (CTRL[1]) — permite abort via software.
            // "!rst_n" é o reset de hardware da placa.
            // Ambos produzem o mesmo efeito: IDLE + contadores zerados.
            // -----------------------------------------------------------------
            current_state <= IDLE;
            i             <= 0;
            j             <= 0;
            k             <= 0;
            cycles_out    <= 0;
            result_out    <= 0;
            done_out      <= 0;

        end else begin
            // -----------------------------------------------------------------
            // Atualiza estado
            // -----------------------------------------------------------------
            current_state <= next_state;

            // -----------------------------------------------------------------
            // Atualiza contadores por estado
            //
            // Os contadores controlam ONDE estamos dentro de cada loop.
            // A lógica é:
            //   j incrementa a cada ciclo dentro de um estado
            //   quando j chega no máximo → zera j, incrementa i ou k
            //   quando i ou k chegam no máximo → FSM transiciona
            // -----------------------------------------------------------------
            case (current_state)

                LOAD_IMG: begin
                    // ---------------------------------------------------------
                    // Conta 784 pixels (j = 0..783)
                    // A cada ciclo um pixel é gravado na ram_img.
                    // Quando j=783: último pixel gravado, próximo ciclo
                    // a FSM vai para CALC_HIDDEN e j é zerado.
                    // ---------------------------------------------------------
                    if (j < 783)
                        j <= j + 1;
                    else
                        j <= 0;
                end

                CALC_HIDDEN: begin
                    // ---------------------------------------------------------
                    // Loop duplo: i (neurônios) × j (pixels)
                    //
                    // j incrementa a cada ciclo (loop interno).
                    // Quando j=783 (fim de um neurônio):
                    //   → zera j para o próximo neurônio
                    //   → incrementa i
                    // Quando i=127 e j=783 (último neurônio):
                    //   → zera ambos, FSM vai para CALC_OUTPUT
                    // ---------------------------------------------------------
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
                    // ---------------------------------------------------------
                    // Loop duplo: k (classes) × i (neurônios ocultos)
                    //
                    // Mesmo padrão de CALC_HIDDEN, mas com k e i.
                    // i incrementa a cada ciclo (loop interno).
                    // Quando i=127: zera i, incrementa k.
                    // Quando k=9 e i=127: zera ambos.
                    // ---------------------------------------------------------
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

                DONE: begin
                    // ---------------------------------------------------------
                    // Captura o resultado do argmax e sinaliza done por 1 ciclo
                    // ---------------------------------------------------------
                    result_out <= max_idx;
                    done_out   <= 1;
                end

                default: begin
                    done_out <= 0;
                end

            endcase

            // -----------------------------------------------------------------
            // Contador de ciclos (CYCLES)
            //
            // Incrementa em todos os estados exceto IDLE e DONE.
            // Congela em DONE para preservar a medição de latência.
            // Zera quando sai de IDLE (início de nova inferência).
            // -----------------------------------------------------------------
            if (current_state == IDLE && next_state == LOAD_IMG)
                cycles_out <= 0;
            else if (current_state != IDLE && current_state != DONE)
                cycles_out <= cycles_out + 1;

        end
    end

    // =========================================================================
    // BLOCO 2 — Combinacional: decide next_state
    //
    // Este bloco é PURAMENTE combinacional — não tem registradores.
    // Ele olha current_state e as condições de transição e decide
    // qual será o próximo estado.
    //
    // Regra: para cada estado, sempre defina next_state — mesmo que
    // seja "fica no mesmo estado". Deixar next_state indefinido causa
    // comportamento imprevisível na síntese (latches indesejados).
    // =========================================================================
    always @(*) begin

        // Valor padrão: permanece no estado atual
        // Isso evita latches — qualquer caminho não coberto pelo case
        // mantém o estado atual em vez de gerar lógica undefined.
        next_state = current_state;

        // Overflow em qualquer estado ativo → ERROR
        if (overflow && current_state != IDLE && current_state != DONE
                     && current_state != ERROR) begin
            next_state = ERROR;

        end else begin
            case (current_state)

                IDLE: begin
                    // ---------------------------------------------------------
                    // Sai do IDLE apenas com start=1
                    // Qualquer outro ciclo permanece em IDLE
                    // ---------------------------------------------------------
                    if (start)
                        next_state = LOAD_IMG;
                    else
                        next_state = IDLE;
                end

                LOAD_IMG: begin
                    // ---------------------------------------------------------
                    // Permanece em LOAD_IMG até j=783 (784 pixels carregados)
                    // No ciclo seguinte vai para CALC_HIDDEN
                    // ---------------------------------------------------------
                    if (j == 783)
                        next_state = CALC_HIDDEN;
                    else
                        next_state = LOAD_IMG;
                end

                CALC_HIDDEN: begin
                    // ---------------------------------------------------------
                    // Permanece até i=127 e j=783 (todos os 128 neurônios)
                    // ---------------------------------------------------------
                    if (i == 127 && j == 783)
                        next_state = CALC_OUTPUT;
                    else
                        next_state = CALC_HIDDEN;
                end

                CALC_OUTPUT: begin
                    // ---------------------------------------------------------
                    // Permanece até k=9 e i=127 (todas as 10 classes)
                    // ---------------------------------------------------------
                    if (k == 9 && i == 127)
                        next_state = ARGMAX;
                    else
                        next_state = CALC_OUTPUT;
                end

                ARGMAX: begin
                    // ---------------------------------------------------------
                    // Aguarda pulso de argmax_done vindo do bloco argmax
                    // ---------------------------------------------------------
                    if (argmax_done)
                        next_state = DONE;
                    else
                        next_state = ARGMAX;
                end

                DONE: begin
                    // ---------------------------------------------------------
                    // DONE dura exatamente 1 ciclo → volta ao IDLE
                    // automaticamente, pronto para nova inferência
                    // ---------------------------------------------------------
                    next_state = IDLE;
                end

                ERROR: begin
                    // ---------------------------------------------------------
                    // ERROR só sai via reset externo (CTRL[1])
                    // O reset é tratado no bloco sequencial acima
                    // ---------------------------------------------------------
                    next_state = ERROR;
                end

                default: next_state = IDLE;

            endcase
        end
    end

    // =========================================================================
    // BLOCO 3 — Combinacional: gera sinais de controle por estado
    //
    // Cada estado ativa um conjunto específico de sinais.
    // IMPORTANTE: sempre defina TODOS os sinais em todos os estados.
    // Sinais não definidos em algum estado geram latches na síntese.
    //
    // Padrão: define tudo como 0 no início, depois ativa o necessário.
    // =========================================================================
    always @(*) begin

        // ---------------------------------------------------------------------
        // Valores padrão: todos os sinais desativados
        // Isso garante que sinais não usados em um estado ficam em 0,
        // evitando latches e comportamento indefinido.
        // ---------------------------------------------------------------------
        we_img_fsm  = 0;
        addr_img    = j;          // endereço da ram_img = contador j
        we_hidden   = 0;
        addr_hidden = i;          // endereço da ram_hidden = contador i
        addr_w      = {i, j};    // endereço rom_pesos = {neurônio, pixel}
        addr_bias   = i;          // endereço rom_bias = contador i
        addr_beta   = {k, i};    // endereço rom_beta = {classe, neurônio}
        mac_en      = 0;
        mac_clr     = 0;
        h_capture   = 0;
        argmax_en   = 0;
        status_out  = STATUS_IDLE;

        case (current_state)

            IDLE: begin
                status_out = STATUS_IDLE;
                // Todos os controles em 0 (padrão acima já garante)
            end

            LOAD_IMG: begin
                // -------------------------------------------------------------
                // Ativa escrita na ram_img a cada ciclo
                // addr_img = j (já definido no padrão acima)
                // we_img_fsm pulsa junto com we_img do reg_bank
                // -------------------------------------------------------------
                we_img_fsm = 1;
                status_out = STATUS_BUSY;
            end

            CALC_HIDDEN: begin
                // -------------------------------------------------------------
                // MAC acumula W[i][j] × x[j] a cada ciclo
                // Quando j=783 (fim do neurônio i):
                //   → mac_clr=1: limpa acumulador para próximo neurônio
                //   → we_hidden=1: salva h[i] = PWL(acumulador) em ram_hidden
                //   → h_capture=1: sinaliza PWL para capturar resultado
                // -------------------------------------------------------------
                mac_en     = 1;
                status_out = STATUS_BUSY;

                if (j == 783) begin
                    mac_clr   = 1;
                    we_hidden = 1;
                    h_capture = 1;
                end
            end

            CALC_OUTPUT: begin
                // -------------------------------------------------------------
                // MAC acumula β[k][i] × h[i] a cada ciclo
                // Quando i=127 (fim da classe k):
                //   → mac_clr=1: limpa acumulador para próxima classe
                // O score y[k] = PWL(acumulador) é capturado pelo argmax
                // -------------------------------------------------------------
                mac_en     = 1;
                status_out = STATUS_BUSY;

                if (i == 127) begin
                    mac_clr = 1;
                end
            end

            ARGMAX: begin
                // -------------------------------------------------------------
                // Habilita o bloco argmax para comparar os 10 scores
                // -------------------------------------------------------------
                argmax_en  = 1;
                status_out = STATUS_BUSY;
            end

            DONE: begin
                // -------------------------------------------------------------
                // Sinaliza conclusão — STATUS=DONE por 1 ciclo
                // result_out já foi atualizado no bloco sequencial
                // -------------------------------------------------------------
                status_out = STATUS_DONE;
            end

            ERROR: begin
                // -------------------------------------------------------------
                // Sinaliza erro — aguarda reset externo
                // Todos os controles permanecem em 0 (padrão acima)
                // -------------------------------------------------------------
                status_out = STATUS_ERROR;
            end

            default: begin
                status_out = STATUS_IDLE;
            end

        endcase
    end

endmodule
