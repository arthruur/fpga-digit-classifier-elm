// =============================================================================
// Módulo: reg_bank.v
// Função: Banco de registradores MMIO — interface entre o ARM e o co-processador.
//         Decodifica endereços e distribui sinais de controle para a FSM
//         e sinais de status de volta para o ARM.
//
// Mapa de registradores (offsets de 32 bits):
//   0x00 → CTRL         (W)   bit[0]=start, bit[1]=reset
//   0x04 → STATUS       (R)   bits[1:0]=estado, bits[5:2]=pred
//   0x08 → IMG          (W)   bits[9:0]=pixel_addr, bits[17:10]=pixel_data
//   0x0C → RESULT       (R)   bits[3:0]=pred (0..9)
//   0x10 → CYCLES       (R)   contador de ciclos de clock
//   0x14 → WEIGHTS_DATA (W)   bits[15:0]=peso Q4.12    — STORE_WEIGHTS
//   0x18 → BIAS_DATA    (W)   bits[15:0]=bias Q4.12    — STORE_BIAS
//   0x1C → BETA_DATA    (W)   bits[15:0]=peso β Q4.12  — STORE_BETA
//
// Ponteiros auto-incrementais:
//
//   STORE_WEIGHTS (0x14):
//     Dual-counter {w_neuron[6:0], w_pixel[9:0]} → endereço padded 17 bits.
//     Total: 100.352 writes (W[0][0]..W[127][783]).
//     Saturação: w_done=1 após último write; writes extras ignorados.
//
//   STORE_BIAS (0x18):
//     Ponteiro linear b_ptr[6:0] → 0..127.
//     Total: 128 writes (b[0]..b[127]).
//     Saturação: b_done=1 após último write.
//
//   STORE_BETA (0x1C):
//     Ponteiro linear beta_ptr[10:0] → 0..1279.
//     Total: 1.280 writes (β[0][0]..β[9][127]), ordem class-major.
//     Saturação: beta_done=1 após último write.
//
//   Todos os ponteiros resetam quando CTRL bit[1]=1 é escrito.
//
// Referência: test_spec_fsm_regbank.md — Módulo 1 (TC-REG-01 a TC-REG-10)
// =============================================================================

module reg_bank (
    input             clk,
    input             rst_n,

    // Barramento MMIO vindo do ARM
    input      [31:0] addr,
    input             write_en,
    input             read_en,
    input      [31:0] data_in,

    // Sinais de status vindos da FSM
    input       [1:0] status_in,
    input       [3:0] pred_in,
    input      [31:0] cycles_in,

    // Saída de leitura para o ARM
    output reg [31:0] data_out,

    // Sinais de controle para a FSM
    output reg        start_out,
    output reg        reset_out,

    // Sinais para ram_img — STORE_IMG
    output reg  [9:0] pixel_addr,
    output reg  [7:0] pixel_data,
    output reg        we_img_out,

    // Sinais para ram_pesos — STORE_WEIGHTS
    output reg        we_pesos_out,
    output reg [16:0] waddr_pesos,
    output reg [15:0] wdata_pesos,

    // Sinais para ram_bias — STORE_BIAS
    output reg        we_bias_out,
    output reg  [6:0] waddr_bias,
    output reg [15:0] wdata_bias,

    // Sinais para ram_beta — STORE_BETA
    output reg        we_beta_out,
    output reg [10:0] waddr_beta,
    output reg [15:0] wdata_beta
);

    // =========================================================================
    // Ponteiro STORE_WEIGHTS — dual-counter
    // =========================================================================
    reg  [6:0] w_neuron;
    reg  [9:0] w_pixel;
    reg        w_done;

    // =========================================================================
    // Ponteiro STORE_BIAS — linear
    // =========================================================================
    reg  [6:0] b_ptr;
    reg        b_done;

    // =========================================================================
    // Ponteiro STORE_BETA — linear
    //   Range: 0..1279 (10 classes × 128 neurônios)
    //   11 bits: 2^11 = 2048 > 1279 ✓
    // =========================================================================
    reg [10:0] beta_ptr;
    reg        beta_done;

    // =========================================================================
    // Lógica de ESCRITA
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            start_out    <= 0;
            reset_out    <= 0;
            pixel_addr   <= 0;
            pixel_data   <= 0;
            we_img_out   <= 0;
            we_pesos_out <= 0;
            waddr_pesos  <= 0;
            wdata_pesos  <= 0;
            we_bias_out  <= 0;
            waddr_bias   <= 0;
            wdata_bias   <= 0;
            we_beta_out  <= 0;
            waddr_beta   <= 0;
            wdata_beta   <= 0;
            w_neuron     <= 0;
            w_pixel      <= 0;
            w_done       <= 0;
            b_ptr        <= 0;
            b_done       <= 0;
            beta_ptr     <= 0;
            beta_done    <= 0;

        end else begin
            // Defaults de pulso — voltam a 0 a cada ciclo automaticamente
            we_img_out   <= 0;
            we_pesos_out <= 0;
            we_bias_out  <= 0;
            we_beta_out  <= 0;

            if (write_en) begin
                case (addr)

                    // ---------------------------------------------------------
                    // CTRL (0x00)
                    //   bit[0] = start
                    //   bit[1] = reset — reseta FSM e todos os ponteiros
                    // ---------------------------------------------------------
                    32'h00: begin
                        start_out <= data_in[0];
                        reset_out <= data_in[1];

                        if (data_in[1]) begin
                            w_neuron  <= 0;
                            w_pixel   <= 0;
                            w_done    <= 0;
                            b_ptr     <= 0;
                            b_done    <= 0;
                            beta_ptr  <= 0;
                            beta_done <= 0;
                        end
                    end

                    // ---------------------------------------------------------
                    // IMG (0x08) — STORE_IMG
                    //   bits[9:0]   = pixel_addr (0..783)
                    //   bits[17:10] = pixel_data (0..255)
                    // ---------------------------------------------------------
                    32'h08: begin
                        pixel_addr <= data_in[9:0];
                        pixel_data <= data_in[17:10];
                        we_img_out <= 1;
                    end

                    // ---------------------------------------------------------
                    // WEIGHTS_DATA (0x14) — STORE_WEIGHTS
                    //   bits[15:0] = peso W Q4.12
                    //
                    //   Dual-counter evita divisão em hardware:
                    //     endereço = {w_neuron[6:0], w_pixel[9:0]}
                    //   Avanço: w_pixel++ até 783, depois w_neuron++.
                    //   Saturação após W[127][783].
                    // ---------------------------------------------------------
                    32'h14: begin
                        if (!w_done) begin
                            we_pesos_out <= 1;
                            waddr_pesos  <= {w_neuron, w_pixel};
                            wdata_pesos  <= data_in[15:0];

                            if (w_pixel == 10'd783) begin
                                w_pixel <= 10'd0;
                                if (w_neuron == 7'd127)
                                    w_done <= 1'b1;
                                else
                                    w_neuron <= w_neuron + 7'd1;
                            end else begin
                                w_pixel <= w_pixel + 10'd1;
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // BIAS_DATA (0x18) — STORE_BIAS
                    //   bits[15:0] = bias b Q4.12
                    //
                    //   Ponteiro linear b_ptr [6:0], 0..127.
                    //   Saturação após b[127].
                    // ---------------------------------------------------------
                    32'h18: begin
                        if (!b_done) begin
                            we_bias_out <= 1;
                            waddr_bias  <= b_ptr;
                            wdata_bias  <= data_in[15:0];

                            if (b_ptr == 7'd127)
                                b_done <= 1'b1;
                            else
                                b_ptr <= b_ptr + 7'd1;
                        end
                    end

                    // ---------------------------------------------------------
                    // BETA_DATA (0x1C) — STORE_BETA
                    //   bits[15:0] = peso β Q4.12
                    //
                    //   Ponteiro linear beta_ptr [10:0], 0..1279.
                    //   Ordem esperada: β[0][0..127], β[1][0..127], ...,
                    //                  β[9][0..127] — class-major.
                    //
                    //   O endereço gerado por beta_ptr coincide diretamente
                    //   com o layout {class_idx[3:0], hidden_idx[6:0]} da
                    //   rom_beta original, pois a ordem de escrita class-major
                    //   produz a mesma sequência linear 0..1279.
                    //   Nenhuma conversão de endereço é necessária.
                    //
                    //   Saturação após β[9][127] (beta_ptr == 1279).
                    // ---------------------------------------------------------
                    32'h1C: begin
                        if (!beta_done) begin
                            we_beta_out <= 1;
                            waddr_beta  <= beta_ptr;
                            wdata_beta  <= data_in[15:0];

                            if (beta_ptr == 11'd1279)
                                beta_done <= 1'b1;
                            else
                                beta_ptr <= beta_ptr + 11'd1;
                        end
                    end

                    default: begin
                        // Endereços não mapeados: ignorados silenciosamente
                    end

                endcase
            end
        end
    end

    // =========================================================================
    // Lógica de LEITURA — registrador de pipeline na saída
    //
    // Motivação: versão combinacional causava caminho crítico de ~30 ns,
    // estourando o período de 20 ns a 50 MHz (slack −10,74 ns).
    // Lógica síncrona quebra o caminho em dois segmentos de clock.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 32'h00000000;
        end else begin
            if (read_en) begin
                case (addr)
                    32'h04: data_out <= {26'b0, pred_in, status_in};
                    32'h0C: data_out <= {28'b0, pred_in};
                    32'h10: data_out <= cycles_in;
                    default: data_out <= 32'h00000000;
                endcase
            end else begin
                data_out <= 32'h00000000;
            end
        end
    end

endmodule
