#!/usr/bin/env python3
"""
elm_golden.py — Golden model Python para o co-processador ELM
TEC 499 · MI Sistemas Digitais · UEFS 2026.1

Implementa a mesma aritmética Q4.12 e as mesmas funções de ativação PWL
do RTL Verilog, servindo como referência para validação do co-processador
em simulação e síntese.

Fluxo de inferência:
    1. Carrega w_in.hex, bias.hex, beta.hex do diretório de pesos
    2. Carrega imagem (HEX ou PNG)
    3. CALC_HIDDEN: h[i] = activation(sum_j(W_in[i][j]·x[j]) + b[i])
    4. CALC_OUTPUT: y[k] = sum_i(β[i][k]·h[i])
    5. ARGMAX: pred = argmax(y[0..9])

Uso:
    python elm_golden.py --img img_test.hex
    python elm_golden.py --png imagem.png [--invert]
    python elm_golden.py --img img_test.hex --activation sigmoid --verbose
    python elm_golden.py --png foto.png --weights-dir sim/ --outdir sim/

Argumentos:
    --img           Arquivo HEX da imagem (784 linhas, 1 byte/pixel em hex)
    --png           Imagem PNG qualquer tamanho (redimensionada para 28×28)
    --invert        Inverte pixels: pixel = 255 - pixel
                    Necessário quando a imagem tem fundo branco e dígito escuro,
                    pois o MNIST usa fundo preto e dígito branco.
    --activation    Função de ativação PWL: 'tanh' (padrão) ou 'sigmoid'
    --weights-dir   Diretório com w_in.hex, bias.hex, beta.hex (padrão: .)
    --outdir        Salva arquivos intermediários de depuração neste diretório
    --verbose       Exibe ativações h[0..127] e scores y[0..9]
"""

import argparse
import sys
from pathlib import Path


# =============================================================================
# Representação Q4.12
# =============================================================================
# 16 bits signed, ponto fixo: 1 bit de sinal, 3 bits inteiros, 12 fracionários.
# Intervalo: [-8.0, +7.999755...]   Resolução: 1/4096 ≈ 0.000244
# Conversão: valor_real = inteiro_q412 / 4096

Q_BITS = 12
SCALE  = 1 << Q_BITS   # 4096
MAX_Q  = 32767          # +7.999755...  (0x7FFF)
MIN_Q  = -32768         # -8.0          (0x8000)


def clamp_q412(x: int) -> int:
    """Clampa um inteiro ao range Q4.12 [-32768, 32767]."""
    return max(MIN_Q, min(MAX_Q, x))


def float_to_q412(x: float) -> int:
    """Converte float para inteiro Q4.12 com arredondamento e clamping."""
    return clamp_q412(int(round(x * SCALE)))


def q412_to_float(v: int) -> float:
    """Converte inteiro Q4.12 para float."""
    return v / SCALE


# =============================================================================
# Leitura de arquivos HEX
# =============================================================================

def load_hex_file(path: Path, n_values: int, signed: bool = True) -> list:
    """
    Lê um arquivo HEX no formato $readmemh (um valor hexadecimal por linha).

    Parâmetros:
        path     : caminho do arquivo
        n_values : número de valores a ler (ignora linhas excedentes)
        signed   : se True, interpreta como two's complement 16-bit;
                   valores com bit 15 = 1 são convertidos para negativos

    Retorna:
        Lista de n_values inteiros Python
    """
    values = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('//'):
                continue
            v = int(line, 16)
            if signed and v >= 0x8000:
                v -= 0x10000
            values.append(v)
            if len(values) == n_values:
                break

    if len(values) < n_values:
        raise ValueError(
            f"{path}: esperados {n_values} valores, arquivo tem apenas {len(values)}")
    return values


def load_image_hex(path: Path) -> list:
    """Carrega 784 pixels (0..255) de um arquivo HEX de imagem."""
    return load_hex_file(path, 784, signed=False)


def load_image_png(path: Path, invert: bool = False) -> list:
    """
    Carrega imagem PNG e converte para 784 pixels em escala de cinza.
    Redimensiona para 28×28 usando LANCZOS se necessário.

    Parâmetro invert: inverte os pixels (255 - p). Use quando o dígito
    está em preto sobre fundo branco (contrário do padrão MNIST).
    """
    try:
        from PIL import Image
    except ImportError:
        print("[ERRO] Pillow não instalado. Execute: pip install pillow")
        sys.exit(1)

    img = Image.open(path).convert("L").resize((28, 28), Image.LANCZOS)
    pixels = list(img.getdata())
    if invert:
        pixels = [255 - p for p in pixels]
    return pixels


def _count_hex_lines(path: Path) -> int:
    """Conta linhas não-vazias e não-comentário em um arquivo HEX."""
    count = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//'):
                count += 1
    return count


def _compact_to_padded(compact: list) -> list:
    """
    Converte w_in do layout compact (100.352 entradas, neuron*784+pixel)
    para o layout padded (131.072 entradas, neuron*1024+pixel).

    Layout compact:  entrada n*784+p  = W_in[n][p]
    Layout padded:   entrada n*1024+p = W_in[n][p]
                     entradas n*1024+784 .. n*1024+1023 = 0 (padding)
    """
    padded = [0] * 131072
    for n in range(128):
        for p in range(784):
            padded[n * 1024 + p] = compact[n * 784 + p]
    return padded


def load_weights(weights_dir: Path):
    """
    Carrega os três arquivos de parâmetros do modelo ELM.

    Arquivos esperados em weights_dir/:
        w_in.hex  — aceita dois layouts:
                      Padded  (131.072 linhas): posição n*1024+p = W_in[n][p]
                                                Posições n*1024+784..1023 são zeros.
                      Compact (100.352 linhas): posição n*784+p  = W_in[n][p]
                                                Sem padding entre neurônios.
                    O layout é detectado automaticamente pelo número de linhas.
        bias.hex  — 128 linhas, b[0]..b[127]
        beta.hex  — 1.280 linhas, layout hidden-major: posição h*10+k = beta[h][k]

    Retorna:
        w_in_padded : lista de 131.072 inteiros Q4.12 (sempre no layout padded)
        bias        : lista de 128 inteiros Q4.12
        beta        : lista de 1.280 inteiros Q4.12
    """
    w_in_path = weights_dir / 'w_in.hex'
    n_lines = _count_hex_lines(w_in_path)

    if n_lines == 131072:
        print(f"[golden] w_in.hex: layout padded ({n_lines} linhas)")
        w_in_padded = load_hex_file(w_in_path, 131072)
    elif n_lines == 100352:
        print(f"[golden] w_in.hex: layout compact ({n_lines} linhas) -> convertendo para padded...")
        compact = load_hex_file(w_in_path, 100352)
        w_in_padded = _compact_to_padded(compact)
    else:
        raise ValueError(
            f"w_in.hex: numero de linhas inesperado ({n_lines}). "
            f"Esperado 131072 (padded) ou 100352 (compact)."
        )

    bias = load_hex_file(weights_dir / 'bias.hex', 128)
    beta = load_hex_file(weights_dir / 'beta.hex', 1280)
    return w_in_padded, bias, beta


# =============================================================================
# Aritmética MAC — replica mac_unit.v exatamente
# =============================================================================
# mac_unit.v implementa: acc += (a * b)
#
# Estágio de produto (product_q4_12):
#   1. product = $signed(a) * $signed(b)           → Q8.24 (32 bits)
#   2. Overflow de produto: bits[31:27] ≠ extensão de sinal do bit[31]
#      → equivale a: product ∉ [-2^27, 2^27 - 1]
#   3. product_q412 = product[27:12]               → Q4.12 (truncamento)
#
# Estágio de acumulação:
#   4. acc_next = acc_internal + sign_extend(product_q412)
#   5. Overflow do acumulador: acc_next[31:15] ≠ extensão de sinal
#      → equivale a: acc_next ∉ [-32768, 32767]
#   6. is_saturated: sticky — uma vez saturado, o acumulador é congelado.
#      Acumulações posteriores são ignoradas (mesmo comportamento que o RTL).

def _mac_product(a: int, b: int) -> int:
    """
    Multiplica dois valores Q4.12 signed e retorna o produto em Q4.12.
    Replica o estágio de produto do mac_unit.v com saturação e truncamento.

    Verificação de overflow: product[31:27] ≠ extensão de sinal
    Equivale a: |product| ≥ 2^27 (134.217.728 em Q8.24 = 8.0 em Q4.12)
    """
    product = a * b  # Q8.24 — Python usa precisão arbitrária

    if product >= (1 << 27):    # prod_ovf_pos
        return MAX_Q
    if product < -(1 << 27):   # prod_ovf_neg
        return MIN_Q

    # Truncamento Q8.24 → Q4.12: shift aritmético de 12 bits
    # Em Python, >> é aritmético para negativos (arredonda em direção a -∞)
    return product >> Q_BITS


def run_mac(pairs: list) -> int:
    """
    Executa sequência de acumulações MAC, replicando mac_unit.v.

    Comportamento is_saturated:
        Uma vez que overflow ocorre (produto ou acumulador), o acumulador
        é congelado no valor saturado (MAX_Q ou MIN_Q). Pares subsequentes
        são ignorados — exatamente como o RTL.

    Parâmetros:
        pairs : lista de tuplas (a, b) com valores Q4.12 signed

    Retorna:
        Valor final Q4.12 do acumulador (inteiro Python em [-32768, 32767])
    """
    acc = 0
    saturated = False
    sat_val = 0

    for a, b in pairs:
        if saturated:
            break

        p = _mac_product(a, b)

        # Verifica se o overflow veio do produto
        raw = a * b
        if raw >= (1 << 27) or raw < -(1 << 27):
            saturated = True
            sat_val = p
            break

        acc_next = acc + p

        # Overflow do acumulador: acc_next ∉ [-32768, 32767]
        if acc_next > MAX_Q:
            saturated = True
            sat_val = MAX_Q
        elif acc_next < MIN_Q:
            saturated = True
            sat_val = MIN_Q
        else:
            acc = acc_next

    return sat_val if saturated else acc


# =============================================================================
# Funções de ativação PWL
# =============================================================================

def pwl_tanh(x: int) -> int:
    """
    Aproximação PWL do tanh em aritmética Q4.12.
    Replica pwl_activation.v — lógica combinacional, latência zero.

    Segmentos (|x| em Q4.12):
        Seg 1: 0     ≤ |x| < 0.25  → y = |x|             (slope = 1, identidade)
        Seg 2: 0.25  ≤ |x| < 0.5   → y = 7/8·|x| + 0.029 (slope = x - x>>3)
        Seg 3: 0.5   ≤ |x| < 1.0   → y = 5/8·|x| + 0.156 (slope = x>>1 + x>>3)
        Seg 4: 1.0   ≤ |x| < 1.5   → y = 5/16·|x| + 0.453 (slope = x>>2 + x>>4)
        Seg 5: 1.5   ≤ |x| < 2.0   → y = 1/8·|x| + 0.717  (slope = x>>3)
        Sat:   |x|   ≥ 2.0          → y = ±1.0

    Simetria (função ímpar): tanh(-x) = -tanh(x)
    Saída em [-4096, +4096] = [-1.0, +1.0] em Q4.12.
    """
    # Breakpoints em Q4.12
    BP1 = 1024   # 0.25
    BP2 = 2048   # 0.50
    BP3 = 4096   # 1.00
    BP4 = 6144   # 1.50
    BP5 = 8192   # 2.00

    # Interceptos em Q4.12 (int(round(valor * 4096)))
    B2 = 119     # 0.029  ≈ 119/4096
    B3 = 639     # 0.156  ≈ 639/4096
    B4 = 1855    # 0.453  ≈ 1855/4096
    B5 = 2937    # 0.717  ≈ 2937/4096
    ONE = SCALE  # 1.0 = 4096

    # Proteção contra extremo assimétrico do complemento de 2 (0x8000 → 0x8001)
    if x == MIN_Q:
        x = -MAX_Q

    x_neg = x < 0
    x_abs = -x if x_neg else x

    # Seleciona segmento e computa saída positiva via shifts
    if x_abs >= BP5:
        y_pos = ONE
    elif x_abs >= BP4:
        y_pos = (x_abs >> 3) + B5                      # 1/8·x + 0.717
    elif x_abs >= BP3:
        y_pos = (x_abs >> 2) + (x_abs >> 4) + B4       # 5/16·x + 0.453
    elif x_abs >= BP2:
        y_pos = (x_abs >> 1) + (x_abs >> 3) + B3       # 5/8·x + 0.156
    elif x_abs >= BP1:
        y_pos = x_abs - (x_abs >> 3) + B2              # 7/8·x + 0.029
    else:
        y_pos = x_abs                                   # identidade

    return -y_pos if x_neg else y_pos


def pwl_sigmoid(x: int) -> int:
    """
    Aproximação PWL da função logística sigmóide σ(x) em aritmética Q4.12.
    Replica pwl_sigmoid.v — lógica combinacional, latência zero.

    Baseado em: Oliveira (2017), Apêndice A.

    Segmentos para |x| (Q4.12):
        Seg 1: 0.0  ≤ |x| < 1.0  → σ = 0.25·|x| + 0.5        (slope = x>>2)
        Seg 2: 1.0  ≤ |x| < 2.5  → σ = 0.125·|x| + 0.625      (slope = x>>3)
        Seg 3: 2.5  ≤ |x| < 4.5  → σ = 0.03125·|x| + 0.859375 (slope = x>>5)
        Seg 4: |x|  ≥ 4.5         → σ = 1.0

    Interceptos em Q4.12 (valores exatos de pwl_sigmoid.v):
        B1 = 0x0800 = 2048  (0.5)
        B2 = 0x0A00 = 2560  (0.625)
        B3 = 0x0DC0 = 3520  (0.859375)

    Simetria: σ(-x) = 1 - σ(x) — NÃO é função ímpar (centrada em 0.5).
    Saída em [0x0000, 0x1000] = [0.0, 1.0] em Q4.12.
    """
    # Breakpoints em Q4.12 (valores exatos de pwl_sigmoid.v)
    BP1 = 0x1000   # 1.0 = 4096
    BP2 = 0x2800   # 2.5 = 10240
    BP3 = 0x4800   # 4.5 = 18432

    # Interceptos em Q4.12 (valores exatos de pwl_sigmoid.v)
    B1  = 0x0800   # 0.5        = 2048
    B2  = 0x0A00   # 0.625      = 2560
    B3  = 0x0DC0   # 0.859375   = 3520
    ONE = 0x1000   # 1.0        = 4096

    # Proteção contra 0x8000
    if x == MIN_Q:
        x = MAX_Q

    x_neg = x < 0
    x_abs = -x if x_neg else x

    # Slopes via shifts aritméticos
    x_shr2 = x_abs >> 2    # 0.25·|x|
    x_shr3 = x_abs >> 3    # 0.125·|x|
    x_shr5 = x_abs >> 5    # 0.03125·|x|

    # Seleciona segmento
    if x_abs >= BP3:
        y_pos = ONE
    elif x_abs >= BP2:
        y_pos = x_shr5 + B3    # 0.03125·|x| + 0.859375
    elif x_abs >= BP1:
        y_pos = x_shr3 + B2    # 0.125·|x| + 0.625
    else:
        y_pos = x_shr2 + B1    # 0.25·|x| + 0.5

    # Simetria: σ(-x) = 1 - σ(x)
    return (ONE - y_pos) if x_neg else y_pos


# =============================================================================
# Inferência ELM
# =============================================================================

def elm_inference(pixels: list, w_in_padded: list, bias: list, beta: list,
                  activation: str = 'tanh', verbose: bool = False):
    """
    Executa inferência ELM completa em aritmética Q4.12.

    Replica os estados CALC_HIDDEN, CALC_OUTPUT e ARGMAX da fsm_ctrl.v.

    Parâmetros:
        pixels       : 784 inteiros [0..255] — pixels da imagem
        w_in_padded  : 131.072 Q4.12 — pesos W_in (layout padded n*1024+p)
        bias         : 128 Q4.12 — biases da camada oculta
        beta         : 1.280 Q4.12 — pesos β (layout hidden-major h*10+k)
        activation   : 'tanh' ou 'sigmoid'
        verbose      : imprime h[0..127] e y[0..9]

    Retorna:
        pred  : inteiro [0..9] — dígito predito
        h_arr : lista de 128 Q4.12 — ativações da camada oculta
        y_arr : lista de 10 Q4.12  — scores da camada de saída
    """
    act_fn = pwl_tanh if activation == 'tanh' else pwl_sigmoid

    # ── Normalização dos pixels ────────────────────────────────────────────
    # pixel_q412 = {4'b0, pixel[7:0], 4'b0}  →  pixel << 4
    # Aproxima pixel/255 em Q4.12 com erro máximo de 0.004 (irrelevante).
    pixel_q412 = [p << 4 for p in pixels]   # range [0x0000, 0x0FF0]

    # ── CALC_HIDDEN ────────────────────────────────────────────────────────
    # Para cada neurônio i = 0..127:
    #   z[i] = sum_{j=0..783}(W_in[i][j] · x[j]) + b[i]   (784 acum. + bias)
    #   h[i] = activation(z[i])
    #
    # Na FSM: j percorre 1..N_PIXELS na acumulação; j=N_PIXELS+1 é o bias.
    # O bias é adicionado como mac_a=bias[i], mac_b=1.0 (0x1000).
    h_arr = []
    for i in range(128):
        pairs = []
        for j in range(784):
            w = w_in_padded[i * 1024 + j]      # layout padded
            pairs.append((w, pixel_q412[j]))
        pairs.append((bias[i], SCALE))           # bias: · 1.0

        z_i = run_mac(pairs)
        h_i = act_fn(z_i)
        h_arr.append(h_i)

    # ── CALC_OUTPUT ────────────────────────────────────────────────────────
    # Para cada classe k = 0..9:
    #   y[k] = sum_{i=0..127}(β[i][k] · h[i])   (128 acum., sem ativação)
    #
    # Na FSM: addr_beta = i*10 + k  →  beta[i*10+k] = β[hidden=i][class=k]
    y_arr = []
    for k in range(10):
        pairs = [(beta[i * 10 + k], h_arr[i]) for i in range(128)]
        y_k = run_mac(pairs)
        y_arr.append(y_k)

    # ── ARGMAX ────────────────────────────────────────────────────────────
    pred = y_arr.index(max(y_arr))

    # ── Verbose ───────────────────────────────────────────────────────────
    if verbose:
        print("\n── Ativações h[0..127] (Q4.12) ──")
        for i, h in enumerate(h_arr):
            print(f"  h[{i:3d}] = 0x{h & 0xFFFF:04X}  ({q412_to_float(h):+.4f})")

        print("\n── Scores y[0..9] (Q4.12) ──")
        for k, y in enumerate(y_arr):
            marker = " ← pred" if k == pred else ""
            print(f"  y[{k}] = 0x{y & 0xFFFF:04X}  ({q412_to_float(y):+.4f}){marker}")

    return pred, h_arr, y_arr


# =============================================================================
# Saída de arquivos intermediários
# =============================================================================

def write_hex(values: list, path: Path, width: int = 4):
    """
    Escreve lista de inteiros em arquivo HEX no formato $readmemh.
    width: número de dígitos hex por valor (4 para Q4.12, 2 para pixels).
    """
    mask = (1 << (width * 4)) - 1
    with open(path, 'w') as f:
        for v in values:
            f.write(f"{v & mask:0{width}X}\n")


# =============================================================================
# Interface de linha de comando
# =============================================================================

def parse_args():
    p = argparse.ArgumentParser(
        description='Golden model Python para co-processador ELM (Q4.12 RTL-exact)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split('Uso:')[0].strip()
    )

    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument('--img', metavar='FILE',
                     help='Arquivo HEX da imagem (784 linhas, 1 byte/pixel)')
    src.add_argument('--png', metavar='FILE',
                     help='Imagem PNG (redimensionada para 28x28 internamente)')

    p.add_argument('--invert', action='store_true',
                   help='Inverte pixels: p = 255 - p (fundo branco → preto)')
    p.add_argument('--activation', choices=['tanh', 'sigmoid'], default='tanh',
                   help='Função de ativação PWL (padrão: tanh)')
    p.add_argument('--weights-dir', metavar='DIR', default='.',
                   help='Diretório com w_in.hex, bias.hex, beta.hex (padrão: .)')
    p.add_argument('--outdir', metavar='DIR', default=None,
                   help='Salva arquivos intermediários neste diretório')
    p.add_argument('--verbose', action='store_true',
                   help='Exibe h[0..127] e y[0..9] completos')

    return p.parse_args()


def main():
    args = parse_args()
    weights_dir = Path(args.weights_dir)

    # Carrega pesos
    print(f"[golden] Carregando pesos de '{weights_dir}/'...")
    try:
        w_in_padded, bias, beta = load_weights(weights_dir)
    except (FileNotFoundError, ValueError) as e:
        print(f"[ERRO] {e}")
        sys.exit(1)
    print(f"[golden] W_in: {len(w_in_padded)} entradas | b: {len(bias)} | β: {len(beta)}")

    # Carrega imagem
    if args.img:
        print(f"[golden] Imagem HEX: {args.img}")
        pixels = load_image_hex(Path(args.img))
    else:
        print(f"[golden] Imagem PNG: {args.png}")
        pixels = load_image_png(Path(args.png), invert=args.invert)
        if args.invert:
            print("[golden] Inversão de pixels aplicada.")

    # Inferência
    print(f"[golden] activation={args.activation} | {len(pixels)} pixels")
    pred, h_arr, y_arr = elm_inference(
        pixels, w_in_padded, bias, beta,
        activation=args.activation,
        verbose=args.verbose
    )

    print(f"\n[golden] Predição: {pred}")

    # Arquivos de depuração
    if args.outdir:
        outdir = Path(args.outdir)
        outdir.mkdir(parents=True, exist_ok=True)
        write_hex(pixels,  outdir / 'img_test.hex', width=2)
        write_hex(h_arr,   outdir / 'h_ref.hex',    width=4)
        write_hex(y_arr,   outdir / 'z_output.hex', width=4)
        write_hex([pred],  outdir / 'pred_ref.hex', width=1)
        print(f"[golden] Intermediários salvos em '{outdir}/'")

    return pred


if __name__ == '__main__':
    main()