// =============================================================================
// Módulo: reg_bank.v
// Função: Banco de registradores MMIO — interface entre o ARM e o co-processador.
//         Decodifica endereços e distribui sinais de controle para a FSM
//         e sinais de status de volta para o ARM.
//
// Mapa de registradores (offsets de 32 bits):
//   0x00 → CTRL    (W)   bit[0]=start, bit[1]=reset
//   0x04 → STATUS  (R)   bits[1:0]=estado, bits[5:2]=pred
//   0x08 → IMG     (W)   bits[9:0]=pixel_addr, bits[17:10]=pixel_data
//   0x0C → RESULT  (R)   bits[3:0]=pred (0..9)
//   0x10 → CYCLES  (R)   contador de ciclos de clock
//
// Referência: test_spec_fsm_regbank.md — Módulo 1 (TC-REG-01 a TC-REG-10)
// =============================================================================

module reg_bank (
    input             clk,
    input             rst_n,          // reset assíncrono ativo em baixo

    // Barramento MMIO vindo do ARM
    input      [31:0] addr,           // endereço do registrador (offset)
    input             write_en,       // 1 = escrita do ARM
    input             read_en,        // 1 = leitura do ARM
    input      [31:0] data_in,        // dado vindo do ARM

    // Sinais de status vindos da FSM (entradas do reg_bank)
    input       [1:0] status_in,      // 2'b00=IDLE, 01=BUSY, 10=DONE, 11=ERROR
    input       [3:0] pred_in,        // dígito previsto (0..9)
    input      [31:0] cycles_in,      // contador de ciclos da FSM

    // Saída de leitura para o ARM
    output reg [31:0] data_out,       // dado enviado ao ARM

    // Sinais de controle para a FSM (saídas do reg_bank)
    output reg        start_out,      // pulso: inicia inferência
    output reg        reset_out,      // nível: reseta a FSM

    // Sinais para a ram_img
    output reg  [9:0] pixel_addr,     // endereço do pixel (0..783)
    output reg  [7:0] pixel_data,     // valor do pixel (0..255)
    output reg        we_img_out      // write enable para ram_img (pulso 1 ciclo)
);

    // =========================================================================
    // Lógica de ESCRITA — decodifica o endereço e distribui os sinais
    //
    // "always @(posedge clk or negedge rst_n)" significa:
    //   executa na borda de subida do clock OU na borda de descida do reset.
    //
    // O reset é ASSÍNCRONO e ATIVO EM BAIXO (rst_n):
    //   rst_n=0 → reset imediato, independente do clock
    //   rst_n=1 → operação normal, sincronizada com clock
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            // -----------------------------------------------------------------
            // Reset assíncrono: zera todos os registradores de saída
            // "!" inverte o sinal — rst_n=0 significa reset ativo
            // -----------------------------------------------------------------
            start_out  <= 0;
            reset_out  <= 0;
            pixel_addr <= 0;
            pixel_data <= 0;
            we_img_out <= 0;

        end else begin
            // -----------------------------------------------------------------
            // Comportamento padrão a cada clock:
            // we_img_out é um pulso — deve voltar a 0 automaticamente
            // a menos que uma nova escrita em IMG ocorra neste ciclo.
            // -----------------------------------------------------------------
            we_img_out <= 0;

            if (write_en) begin
                // -------------------------------------------------------------
                // Decodificação de endereço para ESCRITA
                //
                // "case(addr)" verifica qual registrador o ARM está escrevendo.
                // Cada offset mapeia para um conjunto diferente de sinais.
                // -------------------------------------------------------------
                case (addr)

                    32'h00: begin
                        // -----------------------------------------------------
                        // CTRL — registrador de controle
                        //
                        // bit[0] = start: inicia uma inferência
                        // bit[1] = reset: aborta e reinicia a FSM
                        //
                        // O ARM escreve 0x01 para dar start
                        //             0x02 para dar reset
                        //             0x00 para limpar os dois
                        // -----------------------------------------------------
                        start_out <= data_in[0];
                        reset_out <= data_in[1];
                    end

                    32'h08: begin
                        // -----------------------------------------------------
                        // IMG — registrador de imagem
                        //
                        // O ARM empacota endereço e dado em uma única escrita:
                        //   data_in[9:0]   → endereço do pixel (0..783)
                        //   data_in[17:10] → valor do pixel (0..255)
                        //
                        // we_img_out=1 por 1 ciclo sinaliza para a ram_img
                        // que há um pixel novo para gravar.
                        //
                        // Por que 1 ciclo? A FSM conta exatamente 784 pulsos
                        // de we_img — pulsos extras corromperiam a contagem.
                        // -----------------------------------------------------
                        pixel_addr <= data_in[9:0];
                        pixel_data <= data_in[17:10];
                        we_img_out <= 1;
                    end

                    // Endereços não mapeados: ignorados silenciosamente
                    // O "default" garante que nenhum sinal é alterado
                    default: begin
                        // nada — escrita ignorada
                    end

                endcase
            end
        end
    end

    // =========================================================================
    // Lógica de LEITURA — registrador de pipeline na saída (Marco 2)
    //
    // Motivação: a versão combinacional (always @(*)) produzia um caminho
    // crítico de ~30 ns (addr → data_out), estourando o período de 20 ns
    // a 50 MHz e causando slack de −10,74 ns.
    //
    // Solução: converter para lógica SÍNCRONA. data_out é capturado no
    // posedge do clock seguinte ao ciclo em que read_en=1 e addr são
    // apresentados. Isso quebra o caminho crítico em dois segmentos:
    //   Ciclo N  : addr + read_en chegam → lógica combinacional resolve
    //   Ciclo N+1: data_out registrado fica estável para o AXI bridge
    //
    // Impacto no software (infer.c): nenhum. O polling em C é muito mais
    // lento que 1 ciclo de clock — a latência extra é imperceptível.
    //
    // Impacto no testbench (tb_reg_bank.v): checks de leitura devem
    // amostrar data_out 1 ciclo após a borda em que read_en é ativado.
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 32'h00000000;
        end else begin
            if (read_en) begin
                case (addr)

                    32'h04: begin
                        // ---------------------------------------------------------
                        // STATUS — estado atual da FSM + predição
                        //
                        // bits[1:0] = status_in  (IDLE/BUSY/DONE/ERROR)
                        // bits[5:2] = pred_in    (dígito 0..9 durante DONE)
                        // bits[31:6] = 0
                        //
                        // O ARM faz polling aqui até ver 2'b10 (DONE)
                        // ---------------------------------------------------------
                        data_out <= {26'b0, pred_in, status_in};
                    end

                    32'h0C: begin
                        // ---------------------------------------------------------
                        // RESULT — dígito previsto
                        //
                        // bits[3:0] = pred_in (0..9)
                        // bits[31:4] = 0
                        // ---------------------------------------------------------
                        data_out <= {28'b0, pred_in};
                    end

                    32'h10: begin
                        // ---------------------------------------------------------
                        // CYCLES — contador de ciclos de clock
                        //
                        // Valor inteiro de 32 bits — latência em ciclos.
                        // Congelado quando FSM chega em DONE.
                        // ---------------------------------------------------------
                        data_out <= cycles_in;
                    end

                    // Endereço não mapeado: retorna zero (comportamento seguro)
                    default: begin
                        data_out <= 32'h00000000;
                    end

                endcase
            end else begin
                // read_en=0: mantém o último valor lido (hold)
                // O AXI bridge não amostra data_out quando read_en=0,
                // portanto manter ou zerar são equivalentes funcionalmente.
                data_out <= 32'h00000000;
            end
        end
    end

endmodule