#!/usr/bin/env python3
"""
gen_hex.py — Gera arquivos .hex para $readmemh a partir dos pesos em Q4.12.

Uso:
    python3 gen_hex.py

Requisitos:
    - b_q.txt, beta_q.txt, W_in_q.txt no mesmo diretório (ou ajuste os caminhos)

Saída:
    - bias.hex   (128 linhas)
    - beta.hex   (1280 linhas)
    - w_in.hex   (131072 linhas, layout padded para addr = {neuron[6:0], pixel[9:0]})
"""

import os

# =============================================================================
# Configuração de caminhos
# =============================================================================
INPUT_DIR  = "."          # diretório com os arquivos _q.txt
OUTPUT_DIR = "."          # diretório de saída dos .hex

B_FILE    = os.path.join(INPUT_DIR, "b_q.txt")
BETA_FILE = os.path.join(INPUT_DIR, "beta_q.txt")
W_FILE    = os.path.join(INPUT_DIR, "W_in_q.txt")

# =============================================================================
# Funções auxiliares
# =============================================================================
def load_ints(path):
    with open(path) as f:
        return [int(x) for x in f.read().split()]

def to_hex16(val):
    """Converte inteiro signed para string hex 16-bit (complemento de dois)."""
    return f"{val & 0xFFFF:04X}"

def write_hex(path, values):
    with open(path, 'w') as f:
        for v in values:
            f.write(to_hex16(v) + '\n')

# =============================================================================
# Carrega os pesos
# =============================================================================
print("Carregando pesos...")
b    = load_ints(B_FILE)
beta = load_ints(BETA_FILE)
w    = load_ints(W_FILE)

print(f"  b_q:    {len(b)} entradas")
print(f"  beta_q: {len(beta)} entradas")
print(f"  W_in_q: {len(w)} entradas")

assert len(b)    == 128,   f"Esperado 128 biases,   encontrado {len(b)}"
assert len(beta) == 1280,  f"Esperado 1280 betas,   encontrado {len(beta)}"
assert len(w)    == 100352, f"Esperado 100352 pesos, encontrado {len(w)}"

# =============================================================================
# Gera bias.hex — 128 entradas, ordem linear
# =============================================================================
out_bias = os.path.join(OUTPUT_DIR, "bias.hex")
write_hex(out_bias, b)
print(f"\nGerado: {out_bias} ({len(b)} linhas)")

# =============================================================================
# Gera beta.hex — 1280 entradas, ordem linear
# addr = class_idx * 128 + hidden_idx
# =============================================================================
out_beta = os.path.join(OUTPUT_DIR, "beta.hex")
write_hex(out_beta, beta)
print(f"Gerado: {out_beta} ({len(beta)} linhas)")

# =============================================================================
# Gera w_in.hex — layout PADDED para endereçamento {neuron[6:0], pixel[9:0]}
#
# Profundidade = 2^17 = 131072
# Para neurônio n, pixel p: endereço = n * 1024 + p
# Posições n*1024 + 784 a n*1024 + 1023: zeros (padding, não acessadas pela FSM)
# =============================================================================
DEPTH   = 131072  # 2^17
N_NEURO = 128
N_PIXEL = 784

mem = ['0000'] * DEPTH
for n in range(N_NEURO):
    for p in range(N_PIXEL):
        addr = (n << 10) | p      # n * 1024 + p
        mem[addr] = to_hex16(w[n * N_PIXEL + p])

out_w = os.path.join(OUTPUT_DIR, "w_in.hex")
with open(out_w, 'w') as f:
    for v in mem:
        f.write(v + '\n')
print(f"Gerado: {out_w} ({DEPTH} linhas, padded)")

# =============================================================================
# Verificação spot-check
# =============================================================================
print("\n=== Verificação ===")
checks = [
    ("bias.hex", 0,      "FD3A", b[0]),
    ("bias.hex", 127,    "1BEA", b[127]),
    ("beta.hex", 0,      "FF7D", beta[0]),
    ("beta.hex", 1279,   "000B", beta[1279]),
]
for fname, line, expected, orig in checks:
    path = os.path.join(OUTPUT_DIR, fname)
    val = open(path).readlines()[line].strip()
    status = "✓" if val == expected else f"✗ (encontrado {val})"
    print(f"  {fname}[{line}] = {val} (esperado {expected}, original={orig}) {status}")

# w_in.hex — spot-check com endereços padded
w_lines = open(out_w).readlines()
w_checks = [
    (0,      0,   "FF78",  w[0]),
    (0,      783, "1626",  w[783]),
    (127,    0,   "FE2E",  w[127*784+0]),
    (127,    783, "EF7F",  w[127*784+783]),
]
for n, p, expected, orig in w_checks:
    addr = (n << 10) | p
    val = w_lines[addr].strip()
    status = "✓" if val == expected else f"✗ (encontrado {val})"
    print(f"  w_in.hex[{addr}] W[{n}][{p}] = {val} (esperado {expected}, original={orig}) {status}")

print("\nConcluído! Copie bias.hex, beta.hex e w_in.hex para a pasta rtl/ do projeto.")
