#!/usr/bin/env python3
"""
gen_golden.py — Golden model corrigido para elm_accel
=======================================================
Três correções em relação à versão anterior com erros:

CORREÇÃO 1 — Clipping de z_h_q antes de salvar e usar
  O acumulador da MAC pode exceder o range int16 (±32767).
  Sem clipping, to_hex_16b() mascara com & 0xFFFF e salva um padrão de
  bits que o Verilog interpreta diferente do valor que o Python guardou
  internamente. Resultado: inversão de sinal nos neurônios saturados
  (diff exato de 8192 = 2×4096 no testbench).
  Solução: clip16() antes de qualquer operação subsequente.

CORREÇÃO 2 — h_ref usa pwl_tanh_q412(), não np.tanh
  np.tanh calcula em float64 e difere até 150 LSB do circuito PWL.
  Para comparação bit a bit, h_ref deve replicar exatamente os shifts
  e interceptos do pwl_activation.v.

CORREÇÃO 3 — dtype int64 em todos os arrays intermediários
  Produtos Q4.12 × Q4.12 geram valores em escala Q8.24. Com 784 parcelas,
  o acumulador pode exceder 2^31. Usar int32 causaria overflow silencioso.
"""

import numpy as np
import os

# ── Arquitetura ───────────────────────────────────────────────────────────────
N_INPUT  = 784
N_HIDDEN = 128
N_OUTPUT = 10
SCALE    = 4096          # 2^12

INT16_MAX =  32767
INT16_MIN = -32768

# ── Utilitários Q4.12 ─────────────────────────────────────────────────────────
def float_to_q412(x):
    return max(INT16_MIN, min(INT16_MAX, int(round(x * SCALE))))

def q412_to_float(q):
    return q / SCALE

def clip16(val):
    """Satura inteiro para range signed 16-bit — obrigatório após cada MAC."""
    return max(INT16_MIN, min(INT16_MAX, int(val)))

def to_hex_16b(val):
    return f"{(int(val) & 0xFFFF):04X}"

# ── PWL tanh — espelho EXATO do pwl_activation.v ─────────────────────────────
B2 = 120;  B3 = 640;  B4 = 0x074A;  B5 = 0x0B77
BP_025 = 1024;  BP_050 = 2048;  BP_100 = 4096;  BP_150 = 6144;  BP_200 = 8192
POS_ONE = 4096

def pwl_tanh_q412(x_int: int) -> int:
    """
    Replica bit a bit pwl_activation.v.
    Entrada deve ser int16 clipado — igual ao que está em z_hidden.hex.
    """
    x_int = clip16(x_int)
    x_neg = (x_int < 0)
    x_abs = (-x_int) if x_neg else x_int

    shr1 = x_abs >> 1
    shr2 = x_abs >> 2
    shr3 = x_abs >> 3
    shr4 = x_abs >> 4
    shr9 = x_abs >> 9

    if   x_abs >= BP_200: y_pos = POS_ONE
    elif x_abs >= BP_150: y_pos = shr3 + shr9 + B5
    elif x_abs >= BP_100: y_pos = shr2 + shr4 + B4
    elif x_abs >= BP_050: y_pos = shr1 + shr3 + B3
    elif x_abs >= BP_025: y_pos = (x_abs - shr3) + B2
    else:                  y_pos = x_abs

    y_pos = max(0, min(INT16_MAX, y_pos))
    return (-y_pos) if x_neg else y_pos

# ── Visualização ASCII ────────────────────────────────────────────────────────
def print_ascii_digit(flat_array):
    img = flat_array.reshape(28, 28)
    print("\nVisualização da imagem (28x28, linhas alternadas):")
    for row in img[::2]:
        line = "".join("█" if p > 0.5 else "░" if p > 0.2 else " " for p in row)
        print(line)
    print("-" * 28)

# ── Carregar modelo ───────────────────────────────────────────────────────────
print("--- Carregando model_elm_q.npz ---")
if not os.path.exists('model_elm_q.npz'):
    print("ERRO: model_elm_q.npz não encontrado.")
    exit(1)

model = np.load('model_elm_q.npz')
try:
    W_in = model['W_in_q'].astype(np.int64)
    bias = model['b_q'].astype(np.int64)
    beta = model['beta_q'].astype(np.int64)
    if beta.shape == (N_HIDDEN, N_OUTPUT):
        beta = beta.T   # garante shape (N_OUTPUT, N_HIDDEN)
    print(f"✓ Pesos: W_in{W_in.shape}  bias{bias.shape}  beta{beta.shape}")
except KeyError as e:
    print(f"ERRO: chave {e} ausente. Disponíveis: {list(model.keys())}")
    exit(1)

# ── Carregar imagem ───────────────────────────────────────────────────────────
if os.path.exists('mnist_samples.npz'):
    print("✓ Carregando imagem real de mnist_samples.npz ...")
    samples = np.load('mnist_samples.npz')
    x_raw   = samples['images'][0].flatten()
    x_float = x_raw.astype(float) / 255.0
else:
    print("! mnist_samples.npz ausente — dígito sintético.")
    img = np.zeros((28, 28))
    img[5:23, 13:15] = 1.0
    img[5:8, 11:13]  = 0.8
    x_float = img.flatten()
    x_raw   = (x_float * 255).astype(int)

x_q = np.array([float_to_q412(v) for v in x_float], dtype=np.int64)
print_ascii_digit(x_float)

# ── Inferência Q4.12 ──────────────────────────────────────────────────────────
print("Simulando inferência em Q4.12 ...")

# --- Camada oculta ---
# W_in[j,i] e x_q[i] são Q4.12 inteiros.
# Produto W*x está em escala Q8.24 → divide por SCALE para voltar a Q4.12.
# CLIP16 obrigatório: sem isso o Python usa o valor int64 completo para tanh
# enquanto o HEX salva apenas os 16 bits menos significativos, causando
# divergência de sinal quando o valor excede ±32767.
z_h_raw = np.dot(W_in, x_q) + (bias * SCALE)   # int64, escala Q8.24
z_h_q   = np.array([clip16(v // SCALE) for v in z_h_raw])   # int16 range

# --- Ativação PWL ---
# NÃO usar np.tanh aqui. O hardware implementa PWL com slopes como shifts,
# e a diferença chega a 150 LSB Q4.12 em alguns pontos. Para comparação
# bit a bit no testbench, h_ref deve sair da mesma função que o Verilog usa.
h_q = np.array([pwl_tanh_q412(int(v)) for v in z_h_q], dtype=np.int64)

# --- Camada de saída (SEM ativação) ---
z_o_raw    = np.dot(beta, h_q)   # int64, escala Q8.24
z_output_q = np.array([clip16(v // SCALE) for v in z_o_raw])  # int16 range

pred = int(np.argmax(z_output_q))

# ── Salvar HEX ───────────────────────────────────────────────────────────────
def save_hex(filename, data):
    with open(filename, 'w') as f:
        for val in data:
            f.write(to_hex_16b(val) + "\n")

save_hex("z_hidden.hex", z_h_q)
save_hex("h_ref.hex",    h_q)
save_hex("z_output.hex", z_output_q)

with open("x_test.hex", "w") as f:
    for v in x_raw:
        f.write(f"{int(v) & 0xFF:02X}\n")

with open("pred_ref.txt", "w") as f:
    f.write(f"{pred}\n")

# ── Relatório ─────────────────────────────────────────────────────────────────
with open("golden_report.txt", "w") as f:
    f.write("GOLDEN MODEL — elm_accel (clipping int16 + PWL exato)\n")
    f.write("=" * 55 + "\n\n")
    f.write(f"Modelo: model_elm_q.npz\n")
    f.write(f"Predição: {pred}\n\n")
    zh_f = z_h_q / SCALE
    f.write(f"z_hidden: min={zh_f.min():.4f}  max={zh_f.max():.4f}"
            f"  saturados={np.sum(np.abs(zh_f)>=2.0)}/{N_HIDDEN}\n\n")
    f.write("Escores de saída y[k] = beta*h  (SEM ativação):\n")
    for k in range(N_OUTPUT):
        m = "  ← pred" if k == pred else ""
        f.write(f"  y[{k}] = {int(z_output_q[k]):6d}"
                f"  ({q412_to_float(int(z_output_q[k])):8.4f})"
                f"  [{to_hex_16b(z_output_q[k])}]{m}\n")
    f.write("\nPrimeiros 10 neurônios ocultos:\n")
    f.write(f"  {'j':>3}  {'z_h_q':>7}  {'z_h_f':>7}  {'h_q':>7}  {'h_f':>7}\n")
    for j in range(10):
        f.write(f"  {j:>3}  {int(z_h_q[j]):>7}  {z_h_q[j]/SCALE:>7.4f}"
                f"  {int(h_q[j]):>7}  {h_q[j]/SCALE:>7.4f}\n")

# ── Resumo terminal ───────────────────────────────────────────────────────────
print(f"\n✓ HEX prontos: z_hidden.hex  h_ref.hex  z_output.hex  x_test.hex")
print(f"✓ golden_report.txt")
print("\n" + "=" * 55)
print("ESCORES DE SAÍDA y[0..9]:")
for k in range(N_OUTPUT):
    bar = "█" * max(0, int((q412_to_float(int(z_output_q[k])) + 2) * 6))
    m = "  ← pred" if k == pred else ""
    print(f"  y[{k}] = {q412_to_float(int(z_output_q[k])):8.4f}  {bar}{m}")
print(f"\nPREDIÇÃO FINAL: {pred}")
print(f"\n>>> Atualize EXPECTED_PRED no tb_datapath.v para {pred} <<<")