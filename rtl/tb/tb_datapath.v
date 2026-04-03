// =============================================================================
// tb_datapath.v  —  Testbench de integracao do datapath
// TEC 499 · MI Sistemas Digitais · UEFS 2026.1
//
// TESTE 1: PWL activation (128 neuronios, comparacao bit a bit com h_ref.hex)
// TESTE 2: Argmax com escores reais de z_output.hex vs pred_ref.hex
//
// Prerequisito: rodar gen_golden.py para gerar os arquivos HEX.
// Compilar: vlog pwl_activation.v argmax_block.v tb_datapath.v
// Simular:  vsim -c tb_datapath -do "run -all"
// =============================================================================
`timescale 1ns/1ps

module tb_datapath;

parameter N_HIDDEN = 128;
parameter N_OUTPUT = 10;
parameter CLK_HALF = 5;

reg clk, rst_n;
always #CLK_HALF clk = ~clk;

// ── Memorias de referencia ────────────────────────────────────────────────────
reg signed [15:0] z_hidden_mem [0:N_HIDDEN-1];
reg signed [15:0] h_ref_mem    [0:N_HIDDEN-1];
reg signed [15:0] z_output_mem [0:N_OUTPUT-1];
reg        [3:0]  pred_ref_mem [0:0];

// ── PWL DUT ───────────────────────────────────────────────────────────────────
reg  signed [15:0] pwl_x_in;
wire signed [15:0] pwl_y_out;

pwl_activation u_pwl (.x_in(pwl_x_in), .y_out(pwl_y_out));

// ── Argmax DUT ────────────────────────────────────────────────────────────────
reg        arg_start, arg_enable;
reg  signed [15:0] arg_y_in;
reg  [3:0] arg_k_in;
wire [3:0] arg_max_idx;
wire signed [15:0] arg_max_val;
wire       arg_done;

argmax_block u_argmax (
    .clk    (clk),   .rst_n  (rst_n),
    .start  (arg_start),   .enable (arg_enable),
    .y_in   (arg_y_in),    .k_in   (arg_k_in),
    .max_idx(arg_max_idx), .max_val(arg_max_val),
    .done   (arg_done)
);

integer pass_count, fail_count, i, j;

task tick; begin @(posedge clk); #1; end endtask

function real q412f;
    input signed [15:0] v;
    q412f = $itor($signed(v)) / 4096.0;
endfunction

initial begin
    $dumpfile("tb_datapath.vcd");
    $dumpvars(0, tb_datapath);

    $readmemh("z_hidden.hex", z_hidden_mem);
    $readmemh("h_ref.hex",    h_ref_mem);
    $readmemh("z_output.hex", z_output_mem);
    $readmemh("pred_ref.hex", pred_ref_mem);

    clk=0; rst_n=0; pwl_x_in=0;
    arg_start=0; arg_enable=0; arg_y_in=0; arg_k_in=0;
    pass_count=0; fail_count=0;
    tick; tick; rst_n=1; tick;

    $display("\n====================================================");
    $display("  Testbench de Integracao: datapath elm_accel");
    $display("====================================================");

    // ── TESTE 1: PWL para 128 neuronios ──────────────────────────────────────
    $display("\n--- TESTE 1: PWL activation (%0d neuronios) ---", N_HIDDEN);
    begin : t1
        integer pwl_ok, pwl_ng, diff;
        pwl_ok=0; pwl_ng=0;
        for (j=0; j<N_HIDDEN; j=j+1) begin
            pwl_x_in = z_hidden_mem[j]; #3;
            diff = $signed(pwl_y_out) - $signed(h_ref_mem[j]);
            if (diff<0) diff = -diff;
            if (diff==0) pwl_ok=pwl_ok+1;
            else begin
                pwl_ng=pwl_ng+1;
                $display("  [FAIL] j=%0d  z_h=%0d(%0.4f)  got=%0d(%0.4f)  ref=%0d(%0.4f)  diff=%0d",
                    j,
                    $signed(z_hidden_mem[j]), q412f(z_hidden_mem[j]),
                    $signed(pwl_y_out),       q412f(pwl_y_out),
                    $signed(h_ref_mem[j]),    q412f(h_ref_mem[j]),
                    diff);
            end
        end
        $display("  %0d OK / %0d FAIL de %0d neuronios", pwl_ok, pwl_ng, N_HIDDEN);
        if (pwl_ng==0) begin
            $display("  [PASS] TESTE 1: todos os neuronios corretos");
            pass_count=pass_count+1;
        end else begin
            $display("  [FAIL] TESTE 1: %0d divergencias do golden model", pwl_ng);
            fail_count=fail_count+1;
        end
        // Amostra visual
        $display("\n  Amostra (5 primeiros neuronios):");
        $display("  %4s  %8s  %8s  %8s  %8s  %s",
            "j","z_h","z_h_f","h_got","h_ref","status");
        for (j=0; j<5; j=j+1) begin
            pwl_x_in = z_hidden_mem[j]; #3;
            $display("  %4d  %8d  %8.4f  %8d  %8d  %s",
                j,
                $signed(z_hidden_mem[j]), q412f(z_hidden_mem[j]),
                $signed(pwl_y_out), $signed(h_ref_mem[j]),
                ($signed(pwl_y_out)===$signed(h_ref_mem[j])) ? "OK" : "DIFF");
        end
    end

    tick;

    // ── TESTE 2: Argmax com dados reais ──────────────────────────────────────
    $display("\n--- TESTE 2: Argmax com escores reais ---");
    $display("  Escores z_output[0..9]:");
    for (i=0; i<N_OUTPUT; i=i+1)
        $display("    y[%0d] = %6d  (%8.4f)", i, $signed(z_output_mem[i]), q412f(z_output_mem[i]));

    arg_start=1; tick; arg_start=0;
    for (i=0; i<N_OUTPUT; i=i+1) begin
        arg_y_in=z_output_mem[i]; arg_k_in=i[3:0]; arg_enable=1; tick;
    end
    arg_enable=0; tick; tick;

    $display("\n  max_idx  = %0d", arg_max_idx);
    $display("  max_val  = %0d  (%0.4f)", $signed(arg_max_val), q412f(arg_max_val));
    $display("  Esperado = %0d  (pred_ref.hex)", pred_ref_mem[0]);

    if (arg_max_idx===pred_ref_mem[0]) begin
        $display("  [PASS] TESTE 2: pred_hardware == pred_golden (%0d)", pred_ref_mem[0]);
        pass_count=pass_count+1;
    end else begin
        $display("  [FAIL] TESTE 2: got=%0d esperado=%0d",
            arg_max_idx, pred_ref_mem[0]);
        fail_count=fail_count+1;
    end

    // ── RESUMO ────────────────────────────────────────────────────────────────
    $display("\n====================================================");
    $display("  RESULTADO: %0d PASS  /  %0d FAIL", pass_count, fail_count);
    if (fail_count==0) begin
        $display("  STATUS: DATAPATH VALIDADO");
        $display("    PWL   : 128 neuronios corretos bit a bit");
        $display("    Argmax: predicao = %0d (correto)", pred_ref_mem[0]);
    end else
        $display("  STATUS: FALHAS -- verificar alinhamento golden model x Verilog");
    $display("====================================================\n");
    $finish;
end
endmodule
