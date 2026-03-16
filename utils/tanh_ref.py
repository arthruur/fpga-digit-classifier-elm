#!/usr/bin/env python3
"""
gen_tanh_ref.py
Gera o arquivo de referência tanh_ref.hex para o testbench Verilog,
simula as duas aproximações PWL em Python e exibe análise de erro.

Uso:
    python3 gen_tanh_ref.py

Saída:
    tanh_ref.hex   — arquivo HEX para $readmemh() no ModelSim/QuestaSim
    pwl_error.csv  — tabela de erros para análise no Excel/Python
    (imprime tabela e gráfico ASCII no terminal)
"""

import numpy as np
import math

# ── Parâmetros Q4.12 ─────────────────────────────────────────────────────────
Q_FRAC  = 12          # bits fracionários
Q_SCALE = 2**Q_FRAC   # 4096
Q_MIN   = -32768      # mínimo signed 16-bit
Q_MAX   =  32767      # máximo signed 16-bit

def float_to_q412(x: float) -> int:
    """Converte float para inteiro Q4.12 (signed 16-bit, clamp)."""
    v = round(x * Q_SCALE)
    return max(Q_MIN, min(Q_MAX, v))

def q412_to_float(x: int) -> float:
    """Converte inteiro Q4.12 para float."""
    return x / Q_SCALE

def to_signed16(x: int) -> int:
    """Garante interpretação como signed 16-bit."""
    x = x & 0xFFFF
    return x if x < 32768 else x - 65536

# ── Implementação PWL Liu 2023 (5 segmentos, semiplano positivo) ─────────────
# Eq. 6 do artigo: g(x) para x ∈ [0, 2)
# Slopes implementados como shift-and-add, interceptos arredondados para Q4.12

# Interceptos em Q4.12 (iguais ao Verilog)
B2_INT = 120   # 0.02935791015625 * 4096 = 120.27 ≈ 120
B3_INT = 640   # 0.15625 * 4096 = 640.0 (exato)
B4_INT = 0x074A  # 1856  = 0.453125 * 4096 (exato)
B5_INT = 0x0B77  # 2935  ≈ 0.71680 * 4096

def pwl_shift(x: int) -> int:
    """
    Implementação Python que espelha EXATAMENTE os shifts do Verilog.
    x: inteiro Q4.12 (pode ser negativo)
    Retorna: inteiro Q4.12
    """
    # Trabalhar com valor absoluto (espelha propriedade de função ímpar)
    x_neg = (x < 0)
    x_abs = (-x) if x_neg else x

    # Shifts (aritméticos, mas x_abs >= 0)
    shr1 = x_abs >> 1
    shr2 = x_abs >> 2
    shr3 = x_abs >> 3
    shr4 = x_abs >> 4
    shr9 = x_abs >> 9

    # Breakpoints em Q4.12
    BP_025 = float_to_q412(0.25)   # 1024
    BP_050 = float_to_q412(0.5)    # 2048
    BP_100 = float_to_q412(1.0)    # 4096
    BP_150 = float_to_q412(1.5)    # 6144
    BP_200 = float_to_q412(2.0)    # 8192

    # Selecionar segmento e calcular saída
    if x_abs >= BP_200:
        y_pos = float_to_q412(1.0)          # saturação
    elif x_abs >= BP_150:
        y_pos = (shr3 + shr9) + B5_INT      # seg 5
    elif x_abs >= BP_100:
        y_pos = (shr2 + shr4) + B4_INT      # seg 4
    elif x_abs >= BP_050:
        y_pos = (shr1 + shr3) + B3_INT      # seg 3
    elif x_abs >= BP_025:
        y_pos = (x_abs - shr3) + B2_INT     # seg 2
    else:
        y_pos = x_abs                        # seg 1 (slope=1)

    # Clamp para 16 bits
    y_pos = max(0, min(Q_MAX, y_pos))

    # Aplicar sinal
    return (-y_pos) if x_neg else y_pos


def pwl_v2(x: int) -> int:
    """
    Versão simples com 3 segmentos (breakpoints ±2, ±4).
    Plano original do roadmap.
    """
    BP_200 = float_to_q412(2.0)
    BP_400 = float_to_q412(4.0)

    x_neg = (x < 0)
    x_abs = (-x) if x_neg else x

    shr2 = x_abs >> 2
    shr3 = x_abs >> 3
    B_EXT = float_to_q412(0.5)   # 2048

    if x_abs >= BP_400:
        y_pos = float_to_q412(1.0)
    elif x_abs >= BP_200:
        y_pos = shr3 + B_EXT
    else:
        y_pos = shr2 + shr3      # slope = 3/8

    y_pos = max(0, min(Q_MAX, y_pos))
    return (-y_pos) if x_neg else y_pos


# ── Geração dos pontos de teste ───────────────────────────────────────────────
X_MIN_F = -4.0
X_MAX_F =  4.0
NPTS    = int((X_MAX_F - X_MIN_F) * Q_SCALE)  # 32768 pontos

print(f"Gerando {NPTS} pontos de referência em [{X_MIN_F}, {X_MAX_F})...\n")

x_ints   = list(range(float_to_q412(X_MIN_F),
                       float_to_q412(X_MIN_F) + NPTS))
x_floats = [q412_to_float(xi) for xi in x_ints]

# Referência: tanh real (float64) quantizada para Q4.12
tanh_ref_float = [math.tanh(xf) for xf in x_floats]
tanh_ref_int   = [float_to_q412(v) for v in tanh_ref_float]

# Aproximações PWL
pwl_liu_int = [pwl_shift(xi) for xi in x_ints]
pwl_v2_int  = [pwl_v2(xi)    for xi in x_ints]

# ── Escrever arquivo HEX para $readmemh ───────────────────────────────────────
with open("tanh_ref.hex", "w") as f:
    for v in tanh_ref_int:
        # Converter para unsigned 16-bit hex
        f.write(f"{v & 0xFFFF:04X}\n")

print("✓ tanh_ref.hex gerado.")

# ── Calcular métricas de erro ─────────────────────────────────────────────────
errors_liu = [abs(q412_to_float(pwl_liu_int[i]) - tanh_ref_float[i])
              for i in range(NPTS)]
errors_v2  = [abs(q412_to_float(pwl_v2_int[i])  - tanh_ref_float[i])
              for i in range(NPTS)]

mae_liu = np.mean(errors_liu)
mae_v2  = np.mean(errors_v2)
max_liu = np.max(errors_liu)
max_v2  = np.max(errors_v2)
x_maxliu = x_floats[np.argmax(errors_liu)]
x_maxv2  = x_floats[np.argmax(errors_v2)]

# ── Exibir tabela de resultados ───────────────────────────────────────────────
print("=" * 65)
print(f"{'MÉTRICA':<30} {'PWL Liu (5-seg)':>15} {'PWL V2 (3-seg)':>15}")
print("-" * 65)
print(f"{'MAE (Mean Absolute Error)':<30} {mae_liu:>15.6f} {mae_v2:>15.6f}")
print(f"{'MaxAE (pior caso)':<30} {max_liu:>15.6f} {max_v2:>15.6f}")
print(f"{'x no pior caso':<30} {x_maxliu:>15.4f} {x_maxv2:>15.4f}")
print(f"{'Melhora Liu vs V2 (MAE)':<30} {mae_v2/mae_liu:>14.1f}x {'':>15}")
print(f"{'Limite aceitável MAE':<30} {'0.010':>15} {'--':>15}")
print(f"{'Status':<30} {'PASS' if mae_liu <= 0.010 else 'FAIL':>15} "
      f"{'--':>15}")
print("=" * 65)

# ── Verificar pontos críticos ─────────────────────────────────────────────────
print("\nPONTOS CRÍTICOS (breakpoints e saturações):")
print(f"{'x':>8} | {'tanh(x)':>10} | {'PWL Liu':>10} | {'Err Liu':>8} | {'PWL V2':>10} | {'Err V2':>8}")
print("-" * 65)

critical = [-4.0, -2.0, -1.5, -1.0, -0.5, -0.25, 0.0,
             0.25, 0.5, 1.0, 1.5, 2.0, 4.0]
for xc in critical:
    xi   = float_to_q412(xc)
    ref  = math.tanh(xc)
    ref_q = q412_to_float(float_to_q412(ref))
    liu  = q412_to_float(pwl_shift(xi))
    v2   = q412_to_float(pwl_v2(xi))
    print(f"{xc:8.3f} | {ref_q:10.6f} | {liu:10.6f} | {abs(liu-ref_q):8.5f} | "
          f"{v2:10.6f} | {abs(v2-ref_q):8.5f}")

# ── Verificar propriedade de função ímpar ─────────────────────────────────────
print("\nPROPRIEDADE DE FUNÇÃO ÍMPAR (f(-x) == -f(x)):")
sym_ok = True
for xc in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]:
    xi   = float_to_q412(xc)
    yp   = pwl_shift(xi)
    yn   = pwl_shift(-xi)
    ok   = (yp == -yn)
    if not ok:
        print(f"  FALHA em x={xc}: f(x)={yp}  -f(-x)={-yn}")
        sym_ok = False
if sym_ok:
    print("  PASS — simetria verificada em 8 pontos")

# ── Escrever CSV detalhado ────────────────────────────────────────────────────
with open("pwl_error.csv", "w") as f:
    f.write("x_float,tanh_ref,pwl_liu,pwl_v2,ae_liu,ae_v2\n")
    step = 16  # 1 em cada 16 pontos (~2048 linhas)
    for i in range(0, NPTS, step):
        f.write(f"{x_floats[i]:.6f},"
                f"{tanh_ref_float[i]:.6f},"
                f"{q412_to_float(pwl_liu_int[i]):.6f},"
                f"{q412_to_float(pwl_v2_int[i]):.6f},"
                f"{errors_liu[i]:.6f},"
                f"{errors_v2[i]:.6f}\n")
print("\n✓ pwl_error.csv gerado.")

# ── Histograma ASCII do erro da PWL Liu ───────────────────────────────────────
print("\nHISTOGRAMA DO ERRO ABSOLUTO (PWL Liu, 5 segmentos):")
bins  = [0, 0.002, 0.004, 0.006, 0.008, 0.010, 0.012, 0.015, 0.020, 0.030]
counts = [0] * (len(bins) - 1)
for e in errors_liu:
    for j in range(len(bins) - 1):
        if bins[j] <= e < bins[j+1]:
            counts[j] += 1
            break

total = sum(counts)
for j in range(len(counts)):
    bar = "█" * int(counts[j] / total * 50)
    print(f"  [{bins[j]:.3f},{bins[j+1]:.3f}): {bar} {counts[j]:6d} ({100*counts[j]/total:5.1f}%)")

print(f"\n  Referência artigo Liu 2023: MAE = 0.0049, MaxAE < 0.025")
print(f"  Nossa implementação Q4.12:  MAE = {mae_liu:.4f}, MaxAE = {max_liu:.4f}")