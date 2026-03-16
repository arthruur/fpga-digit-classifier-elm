#!/usr/bin/env python3
"""
gen_golden.py
Golden model do datapath ELM para validação do tb_datapath.v
Modificado para utilizar o modelo real (model_elm_q.npz) e imagens reais/MNIST.
"""

import numpy as np
import os

# -----------------------------------------------------------------------------
# CONFIGURAÇÕES DA ARQUITETURA
# -----------------------------------------------------------------------------
N_INPUT  = 784  # 28x28 pixels (MNIST)
N_HIDDEN = 128  # Camada oculta
N_OUTPUT = 10   # Classes (0-9)
SCALE    = 4096 # 2^12 para formato Q4.12

# -----------------------------------------------------------------------------
# UTILITÁRIOS DE CONVERSÃO E VISUALIZAÇÃO
# -----------------------------------------------------------------------------
def float_to_q412(x):
    """Converte float para inteiro Q4.12 com saturação"""
    val = int(round(x * SCALE))
    return max(-32768, min(32767, val))

def q412_to_float(q):
    """Converte inteiro Q4.12 para float"""
    return q / SCALE

def to_hex_16b(val):
    """Converte inteiro para string hex de 4 dígitos (16-bit)"""
    return f"{(int(val) & 0xFFFF):04X}"

def print_ascii_digit(flat_array):
    """Exibe uma representação visual simples da imagem 28x28 no terminal"""
    img = flat_array.reshape(28, 28)
    print("\nVisualização da Imagem de Entrada (28x28):")
    for row in img[::2]: # Salta linhas para não ficar muito alto
        line = ""
        for pixel in row[::1]:
            if pixel > 0.5: line += "█"
            elif pixel > 0.2: line += "░"
            else: line += " "
        print(line)
    print("-" * 28)

# -----------------------------------------------------------------------------
# CARREGAMENTO DO MODELO .NPZ
# -----------------------------------------------------------------------------
print(f"--- Carregando modelo quantizado: model_elm_q.npz ---")
if not os.path.exists('model_elm_q.npz'):
    print("ERRO: O arquivo 'model_elm_q.npz' não foi encontrado!")
    exit(1)

model = np.load('model_elm_q.npz')

try:
    # Ajustado para as chaves reais do seu arquivo: W_in_q, b_q, beta_q
    W_in = model['W_in_q']   
    bias = model['b_q']   
    beta = model['beta_q']   
    
    # Se o bias estiver em formato float, escalar para Q4.12
    # Mas como o arquivo termina em '_q', assume-se que já está em ponto fixo
    
    if beta.shape == (N_HIDDEN, N_OUTPUT):
        beta = beta.T
        
    print(f"✓ Pesos carregados: W_in{W_in.shape}, bias{bias.shape}, beta{beta.shape}")
except KeyError as e:
    print(f"ERRO: Chave {e} não encontrada no .npz.")
    print(f"Chaves disponíveis no seu arquivo: {list(model.keys())}")
    exit(1)

# -----------------------------------------------------------------------------
# CARREGAMENTO DA IMAGEM DE TESTE (MNIST REAL OU SINTÉTICA)
# -----------------------------------------------------------------------------
if os.path.exists('mnist_samples.npz'):
    print("✓ Carregando imagem real de 'mnist_samples.npz'...")
    samples = np.load('mnist_samples.npz')
    x_float = samples['images'][0].flatten() / 255.0 # Normaliza 0..1
else:
    print("! 'mnist_samples.npz' não encontrado. Gerando dígito sintético (Dígito '1')...")
    img_synth = np.zeros((28, 28))
    img_synth[5:23, 13:15] = 1.0  
    img_synth[5:8, 11:13] = 0.8   
    x_float = img_synth.flatten()

# Converter para Ponto Fixo Q4.12
x_q = np.array([float_to_q412(v) for v in x_float])
print_ascii_digit(x_float)

# -----------------------------------------------------------------------------
# INFERÊNCIA GOLDEN (SIMULAÇÃO DO HARDWARE)
# -----------------------------------------------------------------------------
print("Simulando inferência em ponto fixo...")

# 1. Camada Oculta: z_h = W_in * x + bias
# Nota: Como os pesos já estão quantizados no NPZ, o resultado do np.dot 
# estará em escala Q8.24 (se x_q e W_in forem Q4.12). 
# O bias_q também deve estar na mesma escala final para a soma.
z_h_full = np.dot(W_in, x_q) + (bias * SCALE) 
z_h_q = np.floor(z_h_full / SCALE).astype(int)

# 2. Ativação: h = tanh(z_h)
h_float = np.tanh(z_h_q / SCALE)
h_q = np.array([float_to_q412(v) for v in h_float])

# 3. Camada de Saída: y = beta * h
z_o_full = np.dot(beta, h_q)
z_output_q = np.floor(z_o_full / SCALE).astype(int)

# 4. Predição: argmax
pred = np.argmax(z_output_q)

# -----------------------------------------------------------------------------
# EXPORTAÇÃO PARA ARQUIVOS .HEX
# -----------------------------------------------------------------------------
print("Gerando ficheiros .hex para o testbench...")

def save_hex(filename, data):
    with open(filename, 'w') as f:
        for val in data:
            f.write(to_hex_16b(val) + "\n")

save_hex("z_hidden.hex", z_h_q)
save_hex("h_ref.hex", h_q)
save_hex("z_output.hex", z_output_q)

with open("x_test.hex", "w") as f:
    for v in (x_float * 255).astype(int):
        f.write(f"{v:02X}\n")

# -----------------------------------------------------------------------------
# RELATÓRIO FINAL
# -----------------------------------------------------------------------------
with open("golden_report.txt", "w") as f:
    f.write("RELATÓRIO DE INFERÊNCIA COM DADOS REAIS (NPZ ATUALIZADO)\n")
    f.write("=" * 45 + "\n")
    f.write(f"Arquivo do modelo: model_elm_q.npz\n")
    f.write(f"Predição do Modelo: {pred}\n\n")
    f.write("Escores por Classe (y):\n")
    for i, val in enumerate(z_output_q):
        marker = " <--- VENCEDOR" if i == pred else ""
        f.write(f"  Classe {i}: {q412_to_float(val):8.4f} (hex: {to_hex_16b(val)}){marker}\n")

print(f"\n✓ Sucesso! O modelo previu que esta imagem é o dígito: {pred}")
print(f"✓ Ficheiros prontos para o Icarus Verilog.")