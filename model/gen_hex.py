# gen_hex.py — Gera os arquivos HEX para inicialização das ROMs
# Uso: python gen_hex.py --model model_elm_q.npz --outdir ../sim
#
# Arquivos gerados:
#   w_in.hex   — 131072 linhas (layout padded: neuron*1024 + pixel)
#   bias.hex   — 128    linhas (endereço direto: neuron)
#   beta.hex   — 1280   linhas (layout: neuron*10 + class)

import argparse
import numpy as np
from pathlib import Path
def write_mif(values, depth, width, path):
    """Gera arquivo .mif no formato Quartus."""
    with open(path, 'w') as f:
        f.write(f"DEPTH = {depth};\n")
        f.write(f"WIDTH = {width};\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n")
        f.write("CONTENT BEGIN\n")
        for i, v in enumerate(values):
            f.write(f"  {i:08X} : {int(v) & 0xFFFF:04X};\n")
        f.write("END;\n")

def to_hex16(v):
    return f"{int(v) & 0xFFFF:04X}"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model',  default='model_elm_q.npz')
    parser.add_argument('--outdir', default='../sim')
    args = parser.parse_args()

    out = Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)

    data   = np.load(args.model)
    W_in_q = data['W_in_q'].astype(np.int32)   # (128, 784)
    b_q    = data['b_q'].astype(np.int32)       # (128,)
    beta_q = data['beta_q'].astype(np.int32)    # (128, 10)

    N_NEURONS  = W_in_q.shape[0]   # 128
    N_PIXELS   = W_in_q.shape[1]   # 784
    N_CLASSES  = beta_q.shape[1]   # 10
    PADDED_PIX = 1024              # próxima potência de 2 acima de 784

    # ── w_in.hex — layout padded: neuron * 1024 + pixel ──────────────────────
    # 128 neurônios × 1024 posições = 131.072 linhas
    # posições 784..1023 de cada neurônio → zero (padding)
    print(f"Gerando w_in.hex ({N_NEURONS * PADDED_PIX} linhas)...")
    with open(out / 'w_in.hex', 'w') as f:
        for n in range(N_NEURONS):
            for p in range(PADDED_PIX):
                v = W_in_q[n, p] if p < N_PIXELS else 0
                f.write(to_hex16(v) + '\n')
    print("  OK")

    # ── bias.hex — endereço direto: neuron ───────────────────────────────────
    # 128 linhas, uma por neurônio
    print(f"Gerando bias.hex ({N_NEURONS} linhas)...")
    with open(out / 'bias.hex', 'w') as f:
        for n in range(N_NEURONS):
            f.write(to_hex16(b_q[n]) + '\n')
    print("  OK")

    # ── beta.hex — layout: neuron * 10 + class ───────────────────────────────
    # 128 × 10 = 1280 linhas
    print(f"Gerando beta.hex ({N_NEURONS * N_CLASSES} linhas)...")
    with open(out / 'beta.hex', 'w') as f:
        for n in range(N_NEURONS):
            for c in range(N_CLASSES):
                f.write(to_hex16(beta_q[n, c]) + '\n')
    print("  OK")

    print(f"\nArquivos gerados em '{out.resolve()}':")
    print(f"  w_in.hex  — {N_NEURONS * PADDED_PIX} linhas (padded)")
    print(f"  bias.hex  — {N_NEURONS} linhas")
    print(f"  beta.hex  — {N_NEURONS * N_CLASSES} linhas")

    # Verificação rápida
    print("\nVerificação:")
    print(f"  W_in[0][0]   = {W_in_q[0,0]:6d} → {to_hex16(W_in_q[0,0])}")
    print(f"  W_in[127][783]= {W_in_q[127,783]:6d} → {to_hex16(W_in_q[127,783])}")
    print(f"  b[0]         = {b_q[0]:6d} → {to_hex16(b_q[0])}")
    print(f"  b[127]       = {b_q[127]:6d} → {to_hex16(b_q[127])}")
    print(f"  beta[0][0]   = {beta_q[0,0]:6d} → {to_hex16(beta_q[0,0])}")
    print(f"  beta[127][9] = {beta_q[127,9]:6d} → {to_hex16(beta_q[127,9])}")

    # ── MIF para Quartus ──────────────────────────────────────────────────────

    # w_in.mif — 131072 posições (padded), 16 bits
    print("Gerando w_in.mif...")
    w_in_flat = []
    for n in range(N_NEURONS):
        for p in range(PADDED_PIX):
            w_in_flat.append(W_in_q[n, p] if p < N_PIXELS else 0)
    write_mif(w_in_flat, N_NEURONS * PADDED_PIX, 16, out / 'w_in.mif')
    print("  OK")

    # bias.mif — 128 posições, 16 bits
    print("Gerando bias.mif...")
    write_mif(b_q, N_NEURONS, 16, out / 'bias.mif')
    print("  OK")

    # beta.mif — 1280 posições (layout n*10+c), 16 bits
    print("Gerando beta.mif...")
    beta_flat = []
    for n in range(N_NEURONS):
        for c in range(N_CLASSES):
            beta_flat.append(beta_q[n, c])
    write_mif(beta_flat, N_NEURONS * N_CLASSES, 16, out / 'beta.mif')
    print("  OK")

    print(f"  w_in.mif  — DEPTH={N_NEURONS * PADDED_PIX}, WIDTH=16")
    print(f"  bias.mif  — DEPTH={N_NEURONS}, WIDTH=16")
    print(f"  beta.mif  — DEPTH={N_NEURONS * N_CLASSES}, WIDTH=16")
if __name__ == '__main__':
    main()