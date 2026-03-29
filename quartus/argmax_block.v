// =============================================================================
// argmax_block.v
// Bloco Argmax Sequencial para o acelerador elm_accel
//
// Função: encontrar o índice do maior valor dentre os 10 escores de saída
//         y[0..9], que representam a confiança do classificador para cada
//         dígito (0 a 9). O índice do maior escore é a predição final.
//
// Arquitetura: comparador sequencial — processa 1 escore por ciclo de clock,
//              iterando por 10 ciclos. Usa 1 comparador signed de 16 bits,
//              muito mais eficiente que 9 comparadores em paralelo.
//
// Representação: escores y[k] em ponto fixo Q4.12 signed (16 bits).
//                A camada de saída computa y = β·h sem ativação,
//                portanto os escores podem ser negativos ou maiores que 1.
//
// Interface com a FSM:
//   - A FSM deve assertar `start` por 1 ciclo para iniciar nova comparação
//   - A cada ciclo com `enable = 1`, o módulo lê `y_in` e `k_in`
//   - Após 10 enables, `done` é assertado e `max_idx` contém o resultado
//   - A FSM lê `max_idx` e escreve em RESULT quando `done = 1`
//
// Diagrama de tempo (exemplo: y = [-0.5, 0.8, 0.3, ..., 0.1]):
//
//  clk   __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
//  start __|‾|___________________________________________
//  enable_____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|__
//  k_in      0   1   2   3   4   5   6   7   8   9
//  y_in    y[0] y[1] y[2] ... ... ... ... ... ... y[9]
//  done  ______________________________________________|‾|
//  max_idx                                             1  (y[1] foi o maior)
// =============================================================================

module argmax_block (
    input  wire        clk,
    input  wire        rst_n,       // reset assíncrono ativo-baixo

    // Interface de controle (vinda da FSM)
    input  wire        start,       // pulso de 1 ciclo: inicia nova comparação
    input  wire        enable,      // 1 = escore válido presente em y_in/k_in

    // Dados de entrada
    input  wire signed [15:0] y_in, // escore atual em Q4.12 (pode ser negativo)
    input  wire [3:0]         k_in, // índice atual do escore (0 a 9)

    // Saídas
    output reg  [3:0]         max_idx,  // índice do maior escore (pred = 0..9)
    output reg  signed [15:0] max_val,  // valor do maior escore (debug/status)
    output reg                done      // 1 quando todos os 10 escores foram comparados
);

// ---------------------------------------------------------------------------
// Valor inicial do máximo: menor valor representável em Q4.12 signed
// 0x8000 = -32768 → qualquer escore real será maior que este valor,
// garantindo que o primeiro escore sempre vença a comparação inicial.
// ---------------------------------------------------------------------------
localparam signed [15:0] MIN_Q412 = 16'h8000;

// ---------------------------------------------------------------------------
// Contador interno de comparações realizadas
// ---------------------------------------------------------------------------
reg [3:0] cmp_count;  // conta de 0 a 9

// ---------------------------------------------------------------------------
// Lógica principal — máquina de estados implícita de 2 estados:
//   IDLE: aguardando start
//   RUNNING: comparando escores (enable = 1 por 10 ciclos consecutivos)
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        max_idx   <= 4'd0;
        max_val   <= MIN_Q412;
        done      <= 1'b0;
        cmp_count <= 4'd0;
    end
    else begin
        // ── Início de nova comparação ──────────────────────────────────────
        if (start) begin
            max_val   <= MIN_Q412;  // resetar máximo atual
            max_idx   <= 4'd0;      // resetar índice
            done      <= 1'b0;      // limpar flag de conclusão
            cmp_count <= 4'd0;
        end
        // ── Comparação de escore ───────────────────────────────────────────
        else if (enable) begin
            // Comparação signed: y_in supera o máximo atual?
            if ($signed(y_in) > $signed(max_val)) begin
                max_val <= y_in;
                max_idx <= k_in;
            end

            // Controlar término após 10 escores (k = 0..9)
            if (cmp_count == 4'd9) begin
                done      <= 1'b1;
                cmp_count <= 4'd0;
            end
            else begin
                done      <= 1'b0;
                cmp_count <= cmp_count + 1'b1;
            end
        end
        // ── Limpar done após 1 ciclo ───────────────────────────────────────
        else begin
            done <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// Verificação formal (assertions) — ativo apenas em simulação
// Verifica que k_in nunca ultrapassa 9 enquanto enable está ativo
// ---------------------------------------------------------------------------
`ifdef SIMULATION
always @(posedge clk) begin
    if (enable && (k_in > 4'd9)) begin
        $display("[ARGMAX ERROR] k_in = %0d > 9 no tempo %0t", k_in, $time);
    end
end
`endif

endmodule