#!/usr/bin/env python3
"""
gen_golden.py
=============
Golden model alinhado ciclo a ciclo com:
  - mac_unit.v      (produto [27:12], overflow [31:15], flag is_saturated)
  - pwl_activation.v (B4=1866=0x074A, B5=2935=0x0B77, case 0x8000->0x7FFF)

Saidas geradas:
  x_test.hex      -- 784 pixels de 8 bits
  z_hidden.hex    -- 128 pre-ativacoes Q4.12 apos MAC
  h_ref.hex       -- 128 ativacoes Q4.12 apos PWL
  z_output.hex    -- 10 escores Q4.12 apos beta*h
  pred_ref.hex    -- 1 valor: digito predito 0..9
  golden_report.txt
"""

import numpy as np
import os

N_INPUT  = 784
N_HIDDEN = 128
N_OUTPUT = 10

# ── Conversoes de largura fixa ────────────────────────────────────────────────
def to_int32(v):
    v = int(v) & 0xFFFFFFFF
    return v - 0x100000000 if v >= 0x80000000 else v

def to_int16(v):
    v = int(v) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

def to_hex16(v):
    return f"{int(v) & 0xFFFF:04X}"

# ═══════════════════════════════════════════════════════════════════════════════
# MAC -- espelho exato de mac_unit.v
# ═══════════════════════════════════════════════════════════════════════════════
def mac_cycle(acc_internal, a, b, is_saturated):
    """Simula 1 ciclo de mac_unit.v com mac_en=1."""
    if is_saturated:
        return acc_internal, to_int16(acc_internal), True

    # product = $signed(a) * $signed(b)  [32 bits Q8.24]
    product  = a * b
    prod_u32 = product & 0xFFFFFFFF
    prod_31_27 = (prod_u32 >> 27) & 0x1F
    prod_sign  = (prod_u32 >> 31) & 1

    # prod_ovf_pos/neg: replica wire do Verilog
    prod_ovf_pos = (prod_31_27 != 0x00) and (prod_sign == 0)
    prod_ovf_neg = (prod_31_27 != 0x1F) and (prod_sign == 1)

    # product_q4_12 = saturado ou product[27:12]
    if prod_ovf_pos:
        pq = 32767
    elif prod_ovf_neg:
        pq = -32768
    else:
        pq = to_int16((prod_u32 >> 12) & 0xFFFF)

    # acc_next = acc_internal + sign_extend(pq) [32 bits]
    acc_next  = to_int32(acc_internal + pq)
    acc_u32   = acc_next & 0xFFFFFFFF
    acc_31_15 = (acc_u32 >> 15) & 0x1FFFF
    acc_sign  = (acc_u32 >> 31) & 1

    # acc_ovf: bits [31:15] -- correcao vs versao original [31:28]
    acc_ovf_pos = (acc_31_15 != 0x00000) and (acc_sign == 0)
    acc_ovf_neg = (acc_31_15 != 0x1FFFF) and (acc_sign == 1)

    overflow_pos = prod_ovf_pos or acc_ovf_pos
    overflow_neg = prod_ovf_neg or acc_ovf_neg

    if overflow_pos:
        return  32767,  32767, True
    elif overflow_neg:
        return -32768, -32768, True
    else:
        return acc_next, to_int16(acc_next), False


def mac_neuron(weights_row, inputs, bias_val):
    """Acumula W[j,:]*x[:] + b[j] como a FSM faria ciclo a ciclo."""
    acc, sat = 0, False
    for w, x in zip(weights_row, inputs):
        acc, _, sat = mac_cycle(acc, int(w), int(x), sat)
    # bias via MAC(bias, +1.0=4096): product[27:12] = bias (sem perda)
    acc, acc_out, sat = mac_cycle(acc, int(bias_val), 4096, sat)
    return acc_out

# ═══════════════════════════════════════════════════════════════════════════════
# PWL -- espelho exato de pwl_activation.v
# ═══════════════════════════════════════════════════════════════════════════════
B2 = 120;   B3 = 640;   B4 = 1866;  B5 = 2935   # localparam do Verilog
BP_025 = 1024; BP_050 = 2048; BP_100 = 4096
BP_150 = 6144; BP_200 = 8192

def pwl_activation(x_int):
    """Replica bit a bit pwl_activation.v."""
    x_int = to_int16(x_int)
    x_neg = (x_int < 0)
    # Caso especial: 0x8000 -> x_abs = 0x7FFF
    if   x_int == -32768: x_abs = 32767
    elif x_neg:            x_abs = -x_int
    else:                  x_abs =  x_int

    shr1 = x_abs >> 1; shr2 = x_abs >> 2; shr3 = x_abs >> 3
    shr4 = x_abs >> 4; shr9 = x_abs >> 9

    y_seg1 = x_abs
    y_seg2 = to_int16((x_abs - shr3) + B2)
    y_seg3 = to_int16((shr1 + shr3)  + B3)
    y_seg4 = to_int16((shr2 + shr4)  + B4)
    y_seg5 = to_int16((shr3 + shr9)  + B5)

    if   x_abs >= BP_200: y_pos = 4096
    elif x_abs >= BP_150: y_pos = y_seg5
    elif x_abs >= BP_100: y_pos = y_seg4
    elif x_abs >= BP_050: y_pos = y_seg3
    elif x_abs >= BP_025: y_pos = y_seg2
    else:                  y_pos = y_seg1

    return to_int16(-y_pos) if x_neg else y_pos

# ═══════════════════════════════════════════════════════════════════════════════
# CARREGAR MODELO
# ═══════════════════════════════════════════════════════════════════════════════
print("Carregando model_elm_q.npz ...")
if not os.path.exists('model_elm_q.npz'):
    print("ERRO: model_elm_q.npz nao encontrado.")
    exit(1)

model = np.load('model_elm_q.npz')
try:
    W_in = model['W_in_q'].astype(np.int64)
    bias = model['b_q'].astype(np.int64)
    beta = model['beta_q'].astype(np.int64)
    if beta.shape == (N_HIDDEN, N_OUTPUT):
        beta = beta.T
    print(f"  W_in: {W_in.shape}  bias: {bias.shape}  beta: {beta.shape}")
except KeyError as e:
    print(f"ERRO: chave {e} ausente. Disponiveis: {list(model.keys())}")
    exit(1)

# ═══════════════════════════════════════════════════════════════════════════════
# CARREGAR IMAGEM
# ═══════════════════════════════════════════════════════════════════════════════
if os.path.exists('mnist.npz'):
    print("Carregando imagem de mnist.npz ...")
    samples = np.load('mnist.npz')
    
    # Suporta tanto o formato do Keras ('x_test') quanto o formato antigo ('images')
    if 'x_test' in samples:
        x_raw = samples['x_test'][0].flatten()
    elif 'images' in samples:
        x_raw = samples['images'][0].flatten()
    else:
        # Se não encontrar nenhum dos dois, pega a primeira chave disponível
        primeira_chave = list(samples.keys())[0]
        x_raw = samples[primeira_chave][0].flatten()
        
    x_float = x_raw.astype(float) / 255.0
    
elif os.path.exists('mnist_sample.npy'):
    print("Carregando imagem de mnist_sample.npy ...")
    x_float = np.load('mnist_sample.npy')
    x_raw   = (x_float * 255.0).astype(int)
    
else:
    print("mnist.npz ausente -- digito sintetico.")
    img = np.zeros((28, 28))
    img[5:23, 13:15] = 1.0
    img[5:8, 11:13]  = 0.8
    x_float = img.flatten()
    x_raw   = (x_float * 255).astype(int)

x_q = np.array([to_int16(round(v * 4096)) for v in x_float], dtype=np.int64)

img_2d = x_float.reshape(28, 28)
print("\nImagem de entrada (28x28, linhas alternadas):")
for row in img_2d[::2]:
    print("".join("X" if p > 0.5 else "." if p > 0.2 else " " for p in row))
print("-" * 28)

# ═══════════════════════════════════════════════════════════════════════════════
# INFERENCIA Q4.12
# ═══════════════════════════════════════════════════════════════════════════════
print("\nExecutando inferencia Q4.12 ...")

print(f"  Camada oculta ({N_HIDDEN} neuronios)...", end="", flush=True)
z_hidden = np.array([mac_neuron(W_in[j], x_q, bias[j]) for j in range(N_HIDDEN)], dtype=np.int64)
sat_h = int(np.sum((z_hidden == 32767) | (z_hidden == -32768)))
print(f" OK  (saturados: {sat_h}/{N_HIDDEN})")

h = np.array([pwl_activation(int(v)) for v in z_hidden], dtype=np.int64)

print(f"  Camada de saida ({N_OUTPUT} classes)...", end="", flush=True)
z_output = np.array([mac_neuron(beta[k], h, 0) for k in range(N_OUTPUT)], dtype=np.int64)
print(" OK")

pred = int(np.argmax(z_output))

# ═══════════════════════════════════════════════════════════════════════════════
# SALVAR ARQUIVOS
# ═══════════════════════════════════════════════════════════════════════════════
with open("x_test.hex",   "w") as f:
    [f.write(f"{int(v)&0xFF:02X}\n") for v in x_raw]

with open("z_hidden.hex", "w") as f:
    [f.write(f"{to_hex16(v)}\n") for v in z_hidden]

with open("h_ref.hex",    "w") as f:
    [f.write(f"{to_hex16(v)}\n") for v in h]

with open("z_output.hex", "w") as f:
    [f.write(f"{to_hex16(v)}\n") for v in z_output]

with open("pred_ref.hex", "w") as f:
    f.write(f"{pred:01X}\n")

with open("golden_report.txt", "w") as f:
    f.write("GOLDEN MODEL -- elm_accel datapath\n")
    f.write("Alinhado com: mac_unit.v (v2) + pwl_activation.v (Liu 2023)\n")
    f.write("=" * 55 + "\n\n")
    f.write(f"Predicao: {pred}\n\n")
    zh_f = z_hidden / 4096
    f.write(f"z_hidden: min={zh_f.min():.4f}  max={zh_f.max():.4f}  saturados={sat_h}/{N_HIDDEN}\n\n")
    f.write("Primeiros 10 neuronios:\n")
    f.write(f"  {'j':>3}  {'z_h':>7}  {'z_h_f':>8}  {'h':>7}  {'h_f':>8}\n")
    for j in range(10):
        f.write(f"  {j:>3}  {int(z_hidden[j]):>7}  {z_hidden[j]/4096:>8.4f}"
                f"  {int(h[j]):>7}  {h[j]/4096:>8.4f}\n")
    f.write("\nEscores de saida y[k]:\n")
    for k in range(N_OUTPUT):
        m = "  <- PRED" if k == pred else ""
        f.write(f"  y[{k}] = {int(z_output[k]):6d}  ({z_output[k]/4096:8.4f}){m}\n")

print("\nArquivos gerados:")
print("  x_test.hex  z_hidden.hex  h_ref.hex  z_output.hex  pred_ref.hex")
print("  golden_report.txt")
print("\n" + "=" * 55)
print("ESCORES DE SAIDA y[0..9]:")
for k in range(N_OUTPUT):
    bar = "X" * max(0, int((z_output[k]/4096 + 2) * 6))
    m = "  <- PRED" if k == pred else ""
    print(f"  y[{k}] = {z_output[k]/4096:8.4f}  {bar}{m}")
print(f"\nPREDICAO FINAL: {pred}")