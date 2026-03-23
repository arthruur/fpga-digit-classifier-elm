# check_beta_hex.py
import numpy as np

data = np.load("model_elm_q.npz")
beta_q = data['beta_q']   # shape (128, 10)
print("beta_q shape:", beta_q.shape)

# Lê as primeiras 5 linhas do hex existente
with open("beta_q.hex", "r") as f:
    hex_lines = [f.readline().strip() for _ in range(5)]

print("\nPrimeiras 5 linhas do beta_q.hex:")
for i, line in enumerate(hex_lines):
    print(f"  linha {i}: {line} = {int(line, 16) if line else 'vazia'}")

# O que esperamos se o hex foi gerado linha a linha da matriz (128,10):
# posição 0 = beta[0][0], posição 1 = beta[0][1], ..., posição 9 = beta[0][9]
# posição 10 = beta[1][0], etc.
print("\nbeta_q[0][0..4] direto:", beta_q[0, :5])
print("beta_q[0..4][0] transposto:", beta_q[:5, 0])