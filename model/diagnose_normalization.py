# diagnose_normalization.py
# Uso: python diagnose_normalization.py <caminho_para_imagem.png> <digito_esperado>
# Exemplo: python diagnose_normalization.py mnist_test/digit_3.png 3

import sys
import numpy as np
from PIL import Image

# ── 1. Carregar modelo ────────────────────────────────────────────────────────
MODEL_PATH = "model_elm_q.npz"  # ajuste se necessário
data = np.load(MODEL_PATH)

print("Chaves no .npz:", list(data.keys()))
print()

# Adapte os nomes das chaves conforme o que for impresso acima
# Nomes comuns: 'W_in', 'Win', 'w_in', 'b', 'bias', 'beta', 'Beta'
# Tente primeiro e ajuste se necessário
try:
    W_in_q  = data['W_in_q']   # shape esperado: (128, 784)
    b_q     = data['b_q']      # shape esperado: (128,)
    beta_q  = data['beta_q']   # shape esperado: (10, 128)
except KeyError as e:
    print(f"Chave não encontrada: {e}")
    print("Chaves disponíveis:", list(data.keys()))
    print("Ajuste os nomes no script e rode novamente.")
    sys.exit(1)

# Converter Q4.12 → float
W_in  = W_in_q.astype(np.float64)  / 4096.0
b     = b_q.astype(np.float64)     / 4096.0
beta  = beta_q.astype(np.float64)  / 4096.0

print(f"W_in  shape: {W_in.shape}   range: [{W_in.min():.4f}, {W_in.max():.4f}]")
print(f"b     shape: {b.shape}      range: [{b.min():.4f}, {b.max():.4f}]")
print(f"beta  shape: {beta.shape}   range: [{beta.min():.4f}, {beta.max():.4f}]")
print()

# ── 2. Carregar imagem ────────────────────────────────────────────────────────
img_path = sys.argv[1] if len(sys.argv) > 1 else "digit_0.png"
expected = int(sys.argv[2]) if len(sys.argv) > 2 else -1

img = Image.open(img_path).convert('L')
img = img.resize((28, 28))
pixels = np.array(img, dtype=np.uint8).flatten()  # shape (784,)

print(f"Imagem: {img_path}  |  pixels min={pixels.min()}  max={pixels.max()}")
print(f"Dígito esperado: {expected}")
print()

# ── 3. Inferência — duas versões de x ────────────────────────────────────────
def infer(x_float):
    z = W_in @ x_float + b        # (128,)
    h = np.tanh(z)                 # (128,)
    y = h @ beta                   # (10,)
    return z, h, y

# Versão A: normalizado por 255
x_norm = pixels.astype(np.float64) / 255.0
z_A, h_A, y_A = infer(x_norm)
pred_A = int(np.argmax(y_A))

# Versão B: bruto (0–255)
x_raw = pixels.astype(np.float64)
z_B, h_B, y_B = infer(x_raw)
pred_B = int(np.argmax(y_B))

# ── 4. Resultado ──────────────────────────────────────────────────────────────
print("─── Versão A: x = pixel / 255.0  (normalizado) ───")
print(f"  Scores y: {np.round(y_A, 4)}")
print(f"  Predição: {pred_A}  {'✓ CORRETO' if pred_A == expected else '✗ ERRADO'}")
print()

print("─── Versão B: x = pixel  (bruto 0–255) ───────────")
print(f"  Scores y: {np.round(y_B, 4)}")
print(f"  Predição: {pred_B}  {'✓ CORRETO' if pred_B == expected else '✗ ERRADO'}")
print()

# ── 5. Dica adicional: range de z (entrada da ativação) ──────────────────────
print("─── Range de z (entrada do tanh) ─────────────────")
print(f"  Versão A: min={z_A.min():.4f}  max={z_A.max():.4f}")
print(f"  Versão B: min={z_B.min():.4f}  max={z_B.max():.4f}")
print()
print("Dica: a versão correta deve ter z majoritariamente em [-4, +4].")
print("Se z_B tiver valores acima de 100, os pesos foram treinados com x normalizado.")