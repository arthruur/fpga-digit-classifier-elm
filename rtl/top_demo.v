// =============================================================================
// top_demo.v — Top-level standalone para demo na DE1-SoC
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// Operação:
//   1. Coloque UMA chave SW[i] para cima para selecionar o dígito i (0..9).
//      HEX1 exibe o dígito selecionado imediatamente.
//   2. Pressione KEY[0] para iniciar a inferência.
//      O top_demo escreve os 784 pixels no elm_accel via MMIO e então
//      dispara START. LEDR[0] acende durante o processamento.
//   3. Ao concluir (~2 ms), LEDR[1] acende e HEX0 exibe o dígito predito.
//   4. KEY[1] reinicia o sistema (reset manual).
//
// Conexões DE1-SoC:
//   CLOCK_50   → clk (50 MHz, pino AF14)
//   SW[9:0]    → seleção do dígito (prioridade para o bit mais baixo ativo)
//   KEY[0]     → start (ativo baixo, com debounce)
//   KEY[1]     → reset (ativo baixo)
//   HEX0[6:0]  → dígito predito
//   HEX1[6:0]  → dígito selecionado
//   LEDR[0]    → BUSY (inferência em curso)
//   LEDR[1]    → DONE (resultado disponível, travado)
//   LEDR[2]    → ERROR
//
// Arquivos de imagem necessários em sim/ (gerados por gen_all_digits.py):
//   digit_0.hex .. digit_9.hex  — 784 pixels por arquivo (8-bit por linha)
//
// Nota sobre inicialização das ROMs:
//   As digit_rom são read-only (nunca escritas). Para ROMs puras, o Quartus
//   respeita $readmemh em blocos initial e inicializa o M10K corretamente.
//   Isso é diferente da ram_img (escrita via MMIO) onde $readmemh é ignorado.
// =============================================================================

module top_demo #(
    parameter DIGIT_0_HEX = "digit_0.hex",
    parameter DIGIT_1_HEX = "digit_1.hex",
    parameter DIGIT_2_HEX = "digit_2.hex",
    parameter DIGIT_3_HEX = "digit_3.hex",
    parameter DIGIT_4_HEX = "digit_4.hex",
    parameter DIGIT_5_HEX = "digit_5.hex",
    parameter DIGIT_6_HEX = "digit_6.hex",
    parameter DIGIT_7_HEX = "digit_7.hex",
    parameter DIGIT_8_HEX = "digit_8.hex",
    parameter DIGIT_9_HEX = "digit_9.hex"
)(
    input        CLOCK_50,
    input  [9:0] SW,       // SW[i] seleciona dígito i
    input        KEY0,     // start (ativo baixo)
    input        KEY1,     // reset (ativo baixo)
    output [6:0] HEX0,     // dígito predito
    output [6:0] HEX1,     // dígito selecionado
    output       LEDR0,    // BUSY
    output       LEDR1,    // DONE travado
    output       LEDR2     // ERROR travado
);

    // =========================================================================
    // Reset — KEY[1] ativo baixo
    // =========================================================================
    wire rst_n = KEY1;     // KEY1 pressionado → rst_n=0 → reset

    // =========================================================================
    // ROMs de dígitos — 10 arrays separados de 784×8 bits
    // Arrays 2D unpacked com dois índices variáveis não são suportados em
    // Verilog-2001 no Quartus — usamos 10 arrays independentes + mux.
    // =========================================================================
    reg [7:0] rom0 [783:0]; reg [7:0] rom1 [783:0];
    reg [7:0] rom2 [783:0]; reg [7:0] rom3 [783:0];
    reg [7:0] rom4 [783:0]; reg [7:0] rom5 [783:0];
    reg [7:0] rom6 [783:0]; reg [7:0] rom7 [783:0];
    reg [7:0] rom8 [783:0]; reg [7:0] rom9 [783:0];

    initial begin
        $readmemh(DIGIT_0_HEX, rom0);
        $readmemh(DIGIT_1_HEX, rom1);
        $readmemh(DIGIT_2_HEX, rom2);
        $readmemh(DIGIT_3_HEX, rom3);
        $readmemh(DIGIT_4_HEX, rom4);
        $readmemh(DIGIT_5_HEX, rom5);
        $readmemh(DIGIT_6_HEX, rom6);
        $readmemh(DIGIT_7_HEX, rom7);
        $readmemh(DIGIT_8_HEX, rom8);
        $readmemh(DIGIT_9_HEX, rom9);
    end

    // =========================================================================
    // Seleção do dígito — encoder de prioridade sobre SW[9:0]
    // Bit menos significativo ativo tem prioridade.
    // Se nenhuma chave estiver ativa, usa dígito 0.
    // =========================================================================
    reg [3:0] sel_digit;

    always @(*) begin
        casez (SW)
            10'b?????????1: sel_digit = 4'd0;
            10'b????????10: sel_digit = 4'd1;
            10'b???????100: sel_digit = 4'd2;
            10'b??????1000: sel_digit = 4'd3;
            10'b?????10000: sel_digit = 4'd4;
            10'b????100000: sel_digit = 4'd5;
            10'b???1000000: sel_digit = 4'd6;
            10'b??10000000: sel_digit = 4'd7;
            10'b?100000000: sel_digit = 4'd8;
            10'b1000000000: sel_digit = 4'd9;
            default:        sel_digit = 4'd0;
        endcase
    end

    // =========================================================================
    // Debounce de KEY[0] — filtro de ~20 ms (20 bits @ 50 MHz)
    // KEY[0] é ativo baixo: solto=1, pressionado=0.
    // start_pulse: pulso de 1 ciclo na borda de descida de KEY[0].
    // =========================================================================
    reg [19:0] dbnc_cnt;
    reg        key_stable;
    reg        key_prev;

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            dbnc_cnt   <= 0;
            key_stable <= 1'b1;
            key_prev   <= 1'b1;
        end else begin
            if (KEY0 !== key_stable)
                dbnc_cnt <= dbnc_cnt + 1;
            else
                dbnc_cnt <= 0;

            if (dbnc_cnt == 20'hFFFFF)
                key_stable <= KEY0;

            key_prev <= key_stable;
        end
    end

    wire start_pulse = key_prev & ~key_stable;  // borda de descida

    // =========================================================================
    // Máquina de estados do top_demo
    //
    // IDLE     → aguarda KEY[0]
    // LOADING  → escreve 784 pixels via registrador IMG do elm_accel
    //            (785 ciclos: 1 warmup + 784 escritas)
    // STARTING → escreve 0x01 em CTRL (start=1)
    // CLEARING → escreve 0x00 em CTRL (start=0)
    // WAITING  → faz polling em STATUS até DONE ou ERROR
    // LATCHED  → resultado travado, aguarda próximo KEY[0]
    //
    // O elm_accel é instanciado com PRELOADED_IMG=0 e INIT_FILE="":
    // pixels chegam via MMIO (LOADING) antes do START.
    // =========================================================================
    localparam ST_IDLE     = 3'd0;
    localparam ST_LOADING  = 3'd1;
    localparam ST_STARTING = 3'd2;
    localparam ST_CLEARING = 3'd3;
    localparam ST_WAITING  = 3'd4;
    localparam ST_LATCHED  = 3'd5;

    reg [2:0]  state;
    reg [9:0]  load_cnt;     // contador de pixels durante LOADING (0..784)
    reg [3:0]  sel_latch;    // dígito selecionado no momento do KEY[0]
    reg [7:0]  pixel_reg;    // pixel lido da ROM no ciclo anterior (latência 1)

    // Mux de seleção da ROM — escolhe o pixel correto entre as 10 ROMs
    reg [7:0] rom_pixel;
    always @(*) begin
        case (sel_latch)
            4'd0: rom_pixel = rom0[load_cnt];
            4'd1: rom_pixel = rom1[load_cnt];
            4'd2: rom_pixel = rom2[load_cnt];
            4'd3: rom_pixel = rom3[load_cnt];
            4'd4: rom_pixel = rom4[load_cnt];
            4'd5: rom_pixel = rom5[load_cnt];
            4'd6: rom_pixel = rom6[load_cnt];
            4'd7: rom_pixel = rom7[load_cnt];
            4'd8: rom_pixel = rom8[load_cnt];
            4'd9: rom_pixel = rom9[load_cnt];
            default: rom_pixel = 8'h00;
        endcase
    end

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            load_cnt  <= 0;
            sel_latch <= 0;
            pixel_reg <= 0;
        end else begin
            case (state)

                ST_IDLE: begin
                    if (start_pulse) begin
                        sel_latch <= sel_digit;   // trava o dígito selecionado
                        load_cnt  <= 0;
                        state     <= ST_LOADING;
                    end
                end

                ST_LOADING: begin
                    // Ciclo 0: warmup — apresenta addr=0, não escreve
                    // Ciclos 1..784: escreve pixel[load_cnt-1] no addr load_cnt-1
                    pixel_reg <= rom_pixel;        // registra pixel do ciclo atual
                    if (load_cnt < 784)
                        load_cnt <= load_cnt + 1;
                    else begin
                        load_cnt <= 0;
                        state    <= ST_STARTING;
                    end
                end

                ST_STARTING: state <= ST_CLEARING;
                ST_CLEARING: state <= ST_WAITING;

                ST_WAITING: begin
                    // Permanece aqui até detectar DONE ou ERROR via status_word
                    if ((status_word[1:0] == 2'b10) ||
                        (status_word[1:0] == 2'b11))
                        state <= ST_LATCHED;
                end

                ST_LATCHED: begin
                    // Aguarda novo KEY[0] para reiniciar
                    if (start_pulse) begin
                        sel_latch <= sel_digit;
                        load_cnt  <= 0;
                        state     <= ST_LOADING;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Geração dos sinais MMIO para o elm_accel
    //
    // LOADING:  addr=0x08 (IMG), write_en=1, data=(pixel<<10)|addr_pixel
    //           Ciclo 0: sem escrita (warmup, pixel_reg ainda inválido)
    //           Ciclos 1..784: escreve pixel[load_cnt-1] no addr load_cnt-1
    // STARTING: addr=0x00 (CTRL), write_en=1, data=0x01
    // CLEARING: addr=0x00 (CTRL), write_en=1, data=0x00
    // demais:   addr=0x04 (STATUS), read_en=1
    // =========================================================================
    wire loading_write = (state == ST_LOADING) && (load_cnt > 0);
    wire [9:0] img_addr_wr = load_cnt - 10'd1;  // addr do pixel que está sendo escrito

    reg [31:0] mmio_addr;
    reg [31:0] mmio_din;
    reg        mmio_wen;
    reg        mmio_ren;

    always @(*) begin
        mmio_addr = 32'h04;   // default: lê STATUS
        mmio_din  = 32'h00;
        mmio_wen  = 1'b0;
        mmio_ren  = 1'b1;

        case (state)
            ST_LOADING: begin
                if (loading_write) begin
                    mmio_addr = 32'h08;
                    mmio_din  = ({22'b0, pixel_reg} << 10) | {22'b0, img_addr_wr};
                    mmio_wen  = 1'b1;
                    mmio_ren  = 1'b0;
                end
            end
            ST_STARTING: begin
                mmio_addr = 32'h00;
                mmio_din  = 32'h01;
                mmio_wen  = 1'b1;
                mmio_ren  = 1'b0;
            end
            ST_CLEARING: begin
                mmio_addr = 32'h00;
                mmio_din  = 32'h00;
                mmio_wen  = 1'b1;
                mmio_ren  = 1'b0;
            end
            default: begin
                mmio_addr = 32'h04;
                mmio_wen  = 1'b0;
                mmio_ren  = 1'b1;
            end
        endcase
    end

    // =========================================================================
    // Instância do elm_accel
    // INIT_FILE="" e PRELOADED_IMG=0: modo normal, pixels via MMIO
    // =========================================================================
    wire [31:0] status_word;

    elm_accel #(
        .INIT_FILE     (""),
        .PRELOADED_IMG (0)
    ) u_elm (
        .clk      (CLOCK_50),
        .rst_n    (rst_n),
        .addr     (mmio_addr),
        .write_en (mmio_wen),
        .read_en  (mmio_ren),
        .data_in  (mmio_din),
        .data_out (status_word)
    );

    // =========================================================================
    // Guarda de reset — bloqueia done_latch nos primeiros 255 ciclos
    // Evita captura de STATUS espúrio logo após rst_n subir.
    // =========================================================================
    reg [7:0] reset_guard;
    wire      system_ready = &reset_guard;

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) reset_guard <= 8'h00;
        else if (!system_ready) reset_guard <= reset_guard + 1;
    end

    // =========================================================================
    // Travamento do resultado
    // pred_latch e done_latch persistem até reset ou novo START.
    // =========================================================================
    wire [1:0] fsm_state = status_word[1:0];
    wire [3:0] pred_now  = status_word[5:2];

    reg [3:0] pred_latch;
    reg       done_latch;
    reg       error_latch;

    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            pred_latch  <= 4'd0;
            done_latch  <= 1'b0;
            error_latch <= 1'b0;
        end else if (system_ready) begin
            if (state == ST_LOADING && load_cnt == 0) begin
                // Novo START: limpa resultado anterior
                done_latch  <= 1'b0;
                error_latch <= 1'b0;
            end
            if (fsm_state == 2'b10) begin
                pred_latch <= pred_now;
                done_latch <= 1'b1;
            end
            if (fsm_state == 2'b11)
                error_latch <= 1'b1;
        end
    end

    // =========================================================================
    // Saídas de status
    // =========================================================================
    assign LEDR0 = (fsm_state == 2'b01);   // BUSY
    assign LEDR1 = done_latch;              // DONE travado
    assign LEDR2 = error_latch;             // ERROR travado

    // =========================================================================
    // Decoder 7-segmentos (compartilhado para HEX0 e HEX1)
    // Segmentos ativos em LOW (cátodo comum na DE1-SoC).
    //
    //   ─ a ─
    //  f     b
    //   ─ g ─
    //  e     c
    //   ─ d ─    {g,f,e,d,c,b,a}
    // =========================================================================
    function [6:0] digit_to_seg;
        input [3:0] d;
        case (d)
            4'd0:    digit_to_seg = 7'b1000000;
            4'd1:    digit_to_seg = 7'b1111001;
            4'd2:    digit_to_seg = 7'b0100100;
            4'd3:    digit_to_seg = 7'b0110000;
            4'd4:    digit_to_seg = 7'b0011001;
            4'd5:    digit_to_seg = 7'b0010010;
            4'd6:    digit_to_seg = 7'b0000010;
            4'd7:    digit_to_seg = 7'b1111000;
            4'd8:    digit_to_seg = 7'b0000000;
            4'd9:    digit_to_seg = 7'b0010000;
            default: digit_to_seg = 7'b0111111;  // traço
        endcase
    endfunction

    // HEX0: dígito predito (traço enquanto não há resultado)
    assign HEX0 = done_latch ? digit_to_seg(pred_latch) : 7'b0111111;

    // HEX1: dígito selecionado pelas chaves (atualiza em tempo real)
    assign HEX1 = digit_to_seg(sel_digit);

endmodule