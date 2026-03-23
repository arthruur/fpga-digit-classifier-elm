#!/usr/bin/env python3
"""
elm_golden.py — Modelo de referência (golden model) para elm_accel
Implementa a mesma aritmética Q4.12 e PWL do hardware Verilog.
Gera arquivos HEX para alimentar tb_elm_accel.v.

Uso:
    python elm_golden.py <imagem.png> [--digit N] [--model path] [--outdir path]

Saídas:
    img_test.hex  — 784 pixels (8-bit, uma linha por pixel)
    z_hidden.hex  — 128 pré-ativações da camada oculta (Q4.12)
    h_ref.hex     — 128 ativações PWL (Q4.12)
    z_output.hex  — 10 scores da camada de saída (Q4.12)
    pred_ref.hex  — dígito predito (0-9, 1 byte)

Exemplo:
    python elm_golden.py model/test/3/30.png --digit 3 \\
           --model model_elm_q.npz --outdir sim/
"""

import sys
import argparse
import numpy as np
from PIL import Image
from pathlib import Path

# ─── Constantes Q4.12 — espelham os localparam de pwl_activation.v ───────────
POS_2    = 0x2000   # +2.0
POS_1P5  = 0x1800   # +1.5
POS_1    = 0x1000   # +1.0
POS_0P5  = 0x0800   # +0.5
POS_0P25 = 0x0400   # +0.25

B2 = 0x0078         # +120/4096  ≈ +0.02936
B3 = 0x0280         # +640/4096  = +0.15625
B4 = 0x074A         # +1866/4096 ≈ +0.45557
B5 = 0x0B77         # +2935/4096 ≈ +0.71680

Q_MAX =  32767      # 0x7FFF — teto positivo Q4.12
Q_MIN = -32768      # 0x8000 — piso negativo Q4.12


# ─── Utilitários de conversão ─────────────────────────────────────────────────

def to_s16(v):
    """Força para inteiro signed 16-bit (complemento de 2)."""
    v = int(v) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v

def to_u16(v):
    """Força para inteiro unsigned 16-bit (para escrita em hex)."""
    return int(v) & 0xFFFF


# ─── PWL — réplica exata de pwl_activation.v ─────────────────────────────────

def pwl_q412(x_int):
    """
    Aproximação piecewise linear do tanh(x) em Q4.12.
    Replica byte a byte a lógica combinacional de pwl_activation.v.

    Passos:
      1. Extrai sinal e calcula |x| com proteção contra -32768
      2. Calcula todos os shifts (sem multiplicadores)
      3. Seleciona segmento por breakpoints (mesmos >= do Verilog)
      4. Aplica propriedade de função ímpar: f(-x) = -f(x)

    Entrada/saída: inteiro signed 16-bit.
    """
    x_int = to_s16(x_int)
    x_neg = x_int < 0

    # Proteção idêntica ao Verilog:
    # abs(-32768) causaria overflow em 16-bit → forçar para +32767
    x_abs = 32767 if x_int == Q_MIN else abs(x_int)

    # Shifts aritméticos sobre valor positivo
    shr1 = x_abs >> 1
    shr2 = x_abs >> 2
    shr3 = x_abs >> 3
    shr4 = x_abs >> 4
    shr9 = x_abs >> 9

    # Seleção de segmento — ordem idêntica ao assign y_pos do Verilog
    if x_abs >= POS_2:
        y_pos = POS_1                           # saturação: +1.0
    elif x_abs >= POS_1P5:
        y_pos = (shr3 + shr9 + B5) & 0xFFFF    # seg 5: slope ≈ 1/8
    elif x_abs >= POS_1:
        y_pos = (shr2 + shr4 + B4) & 0xFFFF    # seg 4: slope = 5/16
    elif x_abs >= POS_0P5:
        y_pos = (shr1 + shr3 + B3) & 0xFFFF    # seg 3: slope = 5/8
    elif x_abs >= POS_0P25:
        y_pos = (x_abs - shr3 + B2) & 0xFFFF   # seg 2: slope = 7/8
    else:
        y_pos = x_abs                           # seg 1: identidade

    # Propriedade de função ímpar
    return to_s16(-y_pos) if x_neg else y_pos


# ─── MAC — réplica exata de mac_unit.v ───────────────────────────────────────

def _mac_product(a, b):
    """
    Multiplica dois valores Q4.12 signed e retorna o produto truncado Q4.12.
    Replica a lógica produto + truncamento [27:12] + saturação do mac_unit.v.

    Retorna: (produto_q4_12: int, overflow: bool)
    """
    product = int(a) * int(b)       # 32-bit signed Q8.24 (Python não limita)

    # Representação como 32-bit unsigned para inspeção de bits
    p32    = product & 0xFFFFFFFF
    p_sign = (p32 >> 31) & 1        # bit de sinal
    p_upper= (p32 >> 27) & 0x1F    # bits [31:27]

    # Para caber em Q4.12 após truncamento, bits [31:27] devem ser todos iguais
    # (extensão de sinal de bit[27]):
    #   positivo → 5'b00000
    #   negativo → 5'b11111
    ovf_pos = (p_upper != 0x00) and (p_sign == 0)
    ovf_neg = (p_upper != 0x1F) and (p_sign == 1)

    if ovf_pos:
        return Q_MAX, True
    if ovf_neg:
        return Q_MIN, True

    # Truncamento: descarta os 12 bits fracionários inferiores
    # equivale a product[27:12] no Verilog
    return to_s16(product >> 12), False


def _mac_loop(weights, inputs, bias=None):
    """
    Simula o mac_unit.v para uma sequência completa de multiplica-acumula.

    weights, inputs: iteráveis de inteiros Q4.12 signed.
    bias: se fornecido, é adicionado como bias * 1.0 (bias * 0x1000) ao final.
          Replica o 'bias_cycle' da FSM na camada oculta.
          None = camada de saída (sem bias).

    Retorna: acumulador final Q4.12 (signed 16-bit).
    """
    acc = 0
    saturated = False

    # Monta lista de pares (w, x) — appende o bias como último par se existir
    pairs = list(zip(weights, inputs))
    if bias is not None:
        pairs.append((int(bias), 0x1000))   # bias * +1.0 em Q4.12

    for w, x in pairs:
        if saturated:
            break   # acumulador congelado — comportamento idêntico ao hardware

        p_q, ovf = _mac_product(int(w), int(x))

        if ovf:
            acc = p_q
            saturated = True
            break

        acc_next = acc + p_q

        if acc_next > Q_MAX:
            acc = Q_MAX
            saturated = True
        elif acc_next < Q_MIN:
            acc = Q_MIN
            saturated = True
        else:
            acc = acc_next

    return acc


# ─── Inferência ELM completa ──────────────────────────────────────────────────

def run_inference(W_in_q, b_q, beta_q, pixels):
    """
    Executa a inferência ELM completa em aritmética Q4.12.

    Parâmetros:
        W_in_q : (128, 784) int — pesos da camada oculta (Q4.12)
        b_q    : (128,)     int — biases da camada oculta (Q4.12)
        beta_q : (128, 10)  int — pesos da camada de saída (Q4.12)
                                  layout: beta_q[neuron][class]
        pixels : (784,)  uint8  — pixels da imagem (0..255)

    Retorna:
        z_hidden : (128,) int16 — pré-ativações da camada oculta
        h        : (128,) int16 — ativações (pós-PWL)
        z_output : (10,)  int16 — scores da camada de saída (linear)
        pred     : int          — dígito predito (0..9)
    """
    N_NEURONS = W_in_q.shape[0]   # 128
    N_CLASSES = beta_q.shape[1]   # 10

    # ── Conversão pixel → Q4.12 ───────────────────────────────────────────
    # pixel/255 ≈ pixel/256 = pixel << 4
    # pixel=0   → 0x0000 (+0.000)
    # pixel=128 → 0x0800 (+0.500)
    # pixel=255 → 0x0FF0 (+0.996)
    x_q = [int(p) << 4 for p in pixels]

    # ── Camada Oculta: h[i] = PWL(W_in[i] · x + b[i]) ───────────────────
    z_hidden = []
    h        = []

    for i in range(N_NEURONS):
        z_i = _mac_loop(W_in_q[i], x_q, bias=b_q[i])
        z_hidden.append(z_i)
        h.append(pwl_q412(z_i))

    # ── Camada de Saída: y[k] = beta[:, k] · h  (linear, sem bias) ───────
    z_output = []

    for k in range(N_CLASSES):
        # beta_q[:, k]: os 128 pesos do neurônio de saída k
        # addr no hex: neuron * 10 + k (confirmado em check_beta_hex.py)
        y_k = _mac_loop(beta_q[:, k], h, bias=None)
        z_output.append(y_k)

    pred = int(np.argmax(z_output))

    return (np.array(z_hidden, dtype=np.int16),
            np.array(h,        dtype=np.int16),
            np.array(z_output, dtype=np.int16),
            pred)


# ─── Escrita de arquivos HEX ──────────────────────────────────────────────────

def write_hex8(values, path):
    """Escreve array de uint8 em hex (2 chars por linha)."""
    with open(path, 'w') as f:
        for v in values:
            f.write(f"{int(v) & 0xFF:02X}\n")

def write_hex16(values, path):
    """Escreve array de int16 em hex (4 chars por linha, complemento de 2)."""
    with open(path, 'w') as f:
        for v in values:
            f.write(f"{to_u16(v):04X}\n")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='ELM golden model — inferência Q4.12 com PWL'
    )
    parser.add_argument('image',
        help='Caminho para a imagem PNG (28x28, escala de cinza)')
    parser.add_argument('--digit', type=int, default=-1,
        help='Dígito esperado para validação (opcional)')
    parser.add_argument('--model', default='model_elm_q.npz',
        help='Arquivo do modelo .npz (default: model_elm_q.npz)')
    parser.add_argument('--outdir', default='sim',
        help='Diretório de saída dos arquivos HEX (default: sim/)')
    args = parser.parse_args()

    out = Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)

    # ── Carregar modelo ────────────────────────────────────────────────────
    data   = np.load(args.model)
    W_in_q = data['W_in_q'].astype(np.int32)   # (128, 784)
    b_q    = data['b_q'].astype(np.int32)      # (128,)
    beta_q = data['beta_q'].astype(np.int32)   # (128, 10)

    print(f"Modelo  : {args.model}")
    print(f"  W_in  {W_in_q.shape}   range [{W_in_q.min():6d}, {W_in_q.max():6d}]")
    print(f"  b     {b_q.shape}     range [{b_q.min():6d}, {b_q.max():6d}]")
    print(f"  beta  {beta_q.shape}    range [{beta_q.min():6d}, {beta_q.max():6d}]")

    # ── Carregar imagem ────────────────────────────────────────────────────
    img    = Image.open(args.image).convert('L').resize((28, 28))
    pixels = np.array(img, dtype=np.uint8).flatten()

    print(f"\nImagem  : {args.image}")
    print(f"  pixels min={pixels.min()}  max={pixels.max()}")

    # ── Inferência Q4.12 ───────────────────────────────────────────────────
    print("\nExecutando inferência Q4.12 + PWL...")
    z_hidden, h, z_output, pred = run_inference(W_in_q, b_q, beta_q, pixels)

    print(f"\n  z_hidden : [{z_hidden.min():6d}, {z_hidden.max():6d}]  "
          f"(saturados: {(np.abs(z_hidden) >= 32767).sum()})")
    print(f"  h        : [{h.min():6d}, {h.max():6d}]")
    print(f"  z_output : {z_output.tolist()}")
    print(f"\n  Predição : {pred}", end="")
    if args.digit >= 0:
        ok = "✓ CORRETO" if pred == args.digit else "✗ ERRADO"
        print(f"  (esperado {args.digit} — {ok})")
    else:
        print()

    # ── Validação cruzada com float ────────────────────────────────────────
    # Roda o modelo float para verificar se Q4.12 converge para o mesmo pred
    W_f  = W_in_q.astype(np.float64) / 4096.0
    b_f  = b_q.astype(np.float64)    / 4096.0
    beta_f = beta_q.astype(np.float64) / 4096.0
    x_f  = pixels.astype(np.float64) / 255.0

    h_f   = np.tanh(W_f @ x_f + b_f)
    y_f   = beta_f.T @ h_f
    pred_f = int(np.argmax(y_f))

    match = "✓ concordam" if pred == pred_f else "✗ divergem"
    print(f"\n  Float ref: {pred_f}  ←→  Q4.12: {pred}  {match}")
    if pred != pred_f:
        print("  ATENÇÃO: divergência entre float e Q4.12.")
        print("  Verifique se a imagem é uma amostra difícil ou se há bug.")

    # ── Gerar arquivos HEX ─────────────────────────────────────────────────
    write_hex8( pixels,   out / 'img_test.hex')
    write_hex16(z_hidden, out / 'z_hidden.hex')
    write_hex16(h,        out / 'h_ref.hex')
    write_hex16(z_output, out / 'z_output.hex')

    with open(out / 'pred_ref.hex', 'w') as f:
        f.write(f"{pred:01X}\n")

    print(f"\nArquivos gerados em '{out.resolve()}':")
    print(f"  img_test.hex   — {len(pixels)} pixels (8-bit por linha)")
    print(f"  z_hidden.hex   — 128 pré-ativações (Q4.12, 16-bit)")
    print(f"  h_ref.hex      — 128 ativações PWL  (Q4.12, 16-bit)")
    print(f"  z_output.hex   — 10  scores de saída (Q4.12, 16-bit)")
    print(f"  pred_ref.hex   — predição: {pred}")


if __name__ == '__main__':
    main()