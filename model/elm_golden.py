#!/usr/bin/env python3
"""
elm_golden.py  –  Modelo de referência do co-processador ELM
Marco 1  |  TEC 499 MI Sistemas Digitais  |  UEFS 2026.1

Implementa EXATAMENTE a mesma aritmética do hardware:
  • Q4.12 fixed-point (inteiro com 12 bits fracionários)
  • Acumulador Q8.24 (32 bits com sinal)
  • Saturação nos limites Q4.12 [-8.0, ~7.9998]
  • Ativação PWL (5 segmentos), mesmos breakpoints do pwl_activation.v

Uso:
    python3 elm_golden.py --pesos pesos.hex --bias bias.hex \
                          --beta beta.hex  --img img.hex

Formato dos arquivos .hex:
    Um valor hexadecimal de 16 bits por linha (sem prefixo "0x").
    Exemplo: 0800   → 0.5 em Q4.12

Saída JSON (stdout):
    { "pred": 3, "h": [...], "y": [...] }
"""

import argparse
import json
import sys

# ============================================================
#  Aritmética Q4.12
# ============================================================
FRAC_BITS  = 12
Q_ONE      = 1 << FRAC_BITS          # 4096  →  1.0 em Q4.12
Q_MAX      = 0x7FFF                   # +7.999756...
Q_MIN      = -0x8000                  # -8.0

# Acumulador Q8.24 (32 bits com sinal)
ACC_FRAC   = 24
ACC_MAX    = (1 << 31) - 1
ACC_MIN    = -(1 << 31)


def to_q412(x: float) -> int:
    """Converte float → Q4.12 com saturação."""
    v = round(x * Q_ONE)
    return max(Q_MIN, min(Q_MAX, v))


def from_q412(v: int) -> float:
    """Converte Q4.12 → float."""
    # Interpreta como complemento de 2 de 16 bits
    if v >= 0x8000:
        v -= 0x10000
    return v / Q_ONE


def q412_mac(acc32: int, a: int, b: int) -> int:
    """
    Acumula a × b no acumulador Q8.24.
    a, b: Q4.12 com sinal (range: -0x8000 a 0x7FFF)
    acc32: Q8.24 com sinal (32 bits)
    Retorna novo acc32 saturado em [ACC_MIN, ACC_MAX].
    """
    # Interpreta como signed 16-bit
    if a >= 0x8000: a -= 0x10000
    if b >= 0x8000: b -= 0x10000
    # Produto Q4.12 × Q4.12 = Q8.24
    product = a * b                   # resultado exato (sem arredondamento)
    acc32  += product
    # Saturação 32 bits
    return max(ACC_MIN, min(ACC_MAX, acc32))


def acc_to_q412(acc32: int) -> int:
    """
    Extrai Q4.12 do acumulador Q8.24: retorna acc32[27:12].
    Equivale a (acc32 >> 12) com saturação para 16 bits.

    Overflow se bits [31:27] não são todos iguais (extensão de sinal).
    """
    # Verifica overflow: top 5 bits devem ser idênticos
    top5 = (acc32 >> 27) & 0x1F
    if acc32 >= 0:                    # positivo
        if top5 != 0:                 # overflow
            return Q_MAX
    else:                             # negativo
        if top5 != 0x1F:              # overflow
            return Q_MIN

    # Sem overflow: extrai bits [27:12]
    shifted = acc32 >> FRAC_BITS      # Q8.12 → Q4.12 (descarta bits fracionários extras)
    # Força para 16 bits signed
    shifted &= 0xFFFF
    return shifted


# ============================================================
#  Ativação PWL  (pwl_activation.v – mesmos breakpoints)
#
#  Segmentos (x em Q4.12):
#    |x| < 2.0   →  y = (3/8)*x         (slope ≈ tanh'(0) = 1, approx)
#    2.0 ≤ |x| < 4.0  →  y = (1/8)*x ± 0.5
#    |x| ≥ 4.0   →  y = ±1.0
#
#  Implementados como bit-shifts (sem multiplicador):
#    3/8*x  = (x>>2) + (x>>3)
#    1/8*x  = (x>>3)
#    0.5    = 0x0800
#    1.0    = 0x1000
# ============================================================
BP2 = to_q412(2.0)    # 0x2000
BP4 = to_q412(4.0)    # 0x4000
HALF = 0x0800         # 0.5 em Q4.12
ONE  = 0x1000         # 1.0 em Q4.12


def pwl_activation(x_q: int) -> int:
    """
    Aplica a ativação PWL sobre valor Q4.12 (inteiro signed 16-bit).
    Retorna valor Q4.12 (inteiro signed 16-bit).
    Replica EXATAMENTE a lógica combinacional do pwl_activation.v.
    """
    # Converte para signed 16-bit (complemento de 2)
    if x_q >= 0x8000:
        x_q -= 0x10000

    if x_q >= 0:
        # Positivo
        if x_q < BP2:
            # slope 3/8: (x>>2) + (x>>3)
            y = (x_q >> 2) + (x_q >> 3)
        elif x_q < BP4:
            # slope 1/8 + 0.5
            y = (x_q >> 3) + HALF
        else:
            y = ONE
    else:
        # Negativo (simetria ímpar)
        ax = -x_q                     # magnitude (positiva)
        if ax < BP2:
            y = -((ax >> 2) + (ax >> 3))
        elif ax < BP4:
            y = -((ax >> 3) + HALF)
        else:
            y = -ONE

    # Converte de volta para unsigned 16-bit (complemento de 2)
    return y & 0xFFFF


# ============================================================
#  Inferência ELM completa
# ============================================================
def elm_infer(pixels, weights, bias, beta,
              n_input=784, n_hidden=128, n_output=10):
    """
    Executa inferência ELM em aritmética Q4.12 pura.

    Parâmetros:
        pixels   – lista de n_input ints Q4.12 (unsigned hex)
        weights  – lista de n_hidden*n_input ints Q4.12
        bias     – lista de n_hidden ints Q4.12
        beta     – lista de n_output*n_hidden ints Q4.12

    Retorna:
        pred     – int (classe predita, 0..9)
        h        – lista de n_hidden ints Q4.12
        y        – lista de n_output ints Q4.12
    """
    h = []
    # ---- Camada oculta: h[i] = PWL( Σ W[i,j]·x[j] + b[i] ) ----
    for i in range(n_hidden):
        acc = 0
        # Acumula pixeis
        for j in range(n_input):
            w_ij = weights[i * n_input + j]
            acc  = q412_mac(acc, w_ij, pixels[j])
        # Acumula bias (b * 1.0)
        acc = q412_mac(acc, bias[i], ONE)
        # Extrai Q4.12 e aplica PWL
        h_i = pwl_activation(acc_to_q412(acc))
        h.append(h_i)

    y = []
    # ---- Camada de saída: y[c] = Σ β[c,k]·h[k] ----------------
    for c in range(n_output):
        acc = 0
        for k in range(n_hidden):
            b_ck = beta[c * n_hidden + k]
            acc  = q412_mac(acc, b_ck, h[k])
        y_c = acc_to_q412(acc)
        y.append(y_c)

    # ---- Argmax -----------------------------------------------
    pred = 0
    max_val = y[0] if y[0] < 0x8000 else y[0] - 0x10000   # signed
    for c in range(1, n_output):
        val = y[c] if y[c] < 0x8000 else y[c] - 0x10000
        if val > max_val:
            max_val = val
            pred    = c

    return pred, h, y


# ============================================================
#  Leitura de arquivos .hex
# ============================================================
def load_hex(path: str) -> list[int]:
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("//"):
                values.append(int(line, 16))
    return values


# ============================================================
#  Validação contra vetor RTL (para uso no CI)
# ============================================================
def validate(pred_golden: int, h_golden: list[int], y_golden: list[int],
             pred_rtl: int, h_rtl: list[int], y_rtl: list[int]) -> bool:
    ok = True

    if pred_golden != pred_rtl:
        print(f"FAIL  pred: golden={pred_golden}  rtl={pred_rtl}", file=sys.stderr)
        ok = False
    else:
        print(f"PASS  pred = {pred_golden}")

    for i, (g, r) in enumerate(zip(h_golden, h_rtl)):
        if g != r:
            print(f"FAIL  h[{i}]: golden=0x{g:04X}  rtl=0x{r:04X}", file=sys.stderr)
            ok = False

    for c, (g, r) in enumerate(zip(y_golden, y_rtl)):
        if g != r:
            print(f"FAIL  y[{c}]: golden=0x{g:04X}  rtl=0x{r:04X}", file=sys.stderr)
            ok = False

    return ok


# ============================================================
#  CLI
# ============================================================
def main():
    p = argparse.ArgumentParser(description="Modelo dourado ELM Q4.12")
    p.add_argument("--pesos", required=True, help="rom_pesos.hex")
    p.add_argument("--bias",  required=True, help="rom_bias.hex")
    p.add_argument("--beta",  required=True, help="rom_beta.hex")
    p.add_argument("--img",   required=True, help="ram_img.hex (uma imagem)")
    p.add_argument("--ni",    type=int, default=784)
    p.add_argument("--nh",    type=int, default=128)
    p.add_argument("--no",    type=int, default=10)
    p.add_argument("--json",  action="store_true", help="saída em JSON")
    args = p.parse_args()

    pixels  = load_hex(args.img)
    weights = load_hex(args.pesos)
    bias    = load_hex(args.bias)
    beta    = load_hex(args.beta)

    pred, h, y = elm_infer(pixels, weights, bias, beta,
                           args.ni, args.nh, args.no)

    if args.json:
        print(json.dumps({"pred": pred,
                          "h": [f"0x{v:04X}" for v in h],
                          "y": [f"0x{v:04X}" for v in y]}))
    else:
        print(f"Predição: {pred}")
        print(f"y = {[f'0x{v:04X}' for v in y]}")


if __name__ == "__main__":
    main()
