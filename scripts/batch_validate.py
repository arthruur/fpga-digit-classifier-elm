# batch_validate.py — Validação em lote do elm_accel
# Uso: python batch_validate.py --testdir ../model/test --simdir ../sim --n 50
#
# Para cada imagem:
#   1. Roda elm_golden.py → gera img_test.hex e pred_ref.hex em sim/
#   2. Executa vvp tb_elm_accel → captura RESULT do hardware
#   3. Compara hardware vs golden model
#   4. Reporta acurácia final

import argparse
import subprocess
import re
import sys
from pathlib import Path

# ── Configuração do projeto ───────────────────────────────────────────────────
# Ajuste esses caminhos se necessário
GOLDEN_SCRIPT = Path("../model/elm_golden.py")
TB_BINARY     = Path("../sim/tb_elm_accel")   # sem extensão no Linux/Mac
TB_BINARY_WIN = Path("../sim/tb_elm_accel")   # vvp aceita sem extensão

def run_golden(image_path, digit, sim_dir):
    """Roda elm_golden.py para uma imagem e retorna a predição do golden model."""
    cmd = [
        sys.executable,
        str(GOLDEN_SCRIPT),
        str(image_path),
        "--digit", str(digit),
        "--model", "../model/model_elm_q.npz",
        "--outdir", str(sim_dir)
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)

    # Extrai predição da saída
    match = re.search(r"Predição\s*:\s*(\d+)", result.stdout)
    if not match:
        return None, result.stdout
    return int(match.group(1)), result.stdout


def run_hardware(sim_dir):
    """Executa o testbench e retorna a predição do hardware."""
    cmd = ["vvp", str(TB_BINARY)]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=str(sim_dir)
    )

    # Extrai resultado do hardware
    match = re.search(r"Hardware prediz\s*:\s*(\d+)", result.stdout)
    if not match:
        return None, result.stdout
    return int(match.group(1)), result.stdout


def collect_images(test_dir, n_per_digit):
    """
    Coleta até n_per_digit imagens de cada subpasta (0..9).
    Estrutura esperada: test_dir/0/*.png, test_dir/1/*.png, ...
    """
    images = []
    test_path = Path(test_dir)

    for digit in range(10):
        digit_dir = test_path / str(digit)
        if not digit_dir.exists():
            print(f"  Aviso: pasta {digit_dir} não encontrada, pulando dígito {digit}")
            continue

        pngs = sorted(digit_dir.glob("*.png"))[:n_per_digit]
        for p in pngs:
            images.append((p, digit))

    return images


def main():
    parser = argparse.ArgumentParser(
        description="Validação em lote do elm_accel"
    )
    parser.add_argument("--testdir", default="../model/test",
        help="Pasta raiz com subpastas 0..9 contendo as imagens PNG")
    parser.add_argument("--simdir", default="../sim",
        help="Pasta de simulação (onde estão os hex de pesos e o tb compilado)")
    parser.add_argument("--n", type=int, default=10,
        help="Número de imagens por dígito (default: 10 → 100 imagens total)")
    parser.add_argument("--skip-divergent", action="store_true",
        help="Pula imagens onde float e Q4.12 divergem no golden model")
    args = parser.parse_args()

    sim_dir  = Path(args.simdir).resolve()
    images   = collect_images(args.testdir, args.n)

    print("=" * 60)
    print(f" Validação em lote — elm_accel")
    print(f" Imagens por dígito : {args.n}")
    print(f" Total de imagens   : {len(images)}")
    print(f" Pasta de simulação : {sim_dir}")
    print("=" * 60)

    # Contadores globais
    total        = 0
    hw_correct   = 0
    golden_correct = 0
    hw_golden_agree = 0
    skipped      = 0
    errors       = 0

    # Resultados por dígito
    per_digit = {d: {"total": 0, "hw_ok": 0, "gold_ok": 0}
                 for d in range(10)}

    for img_path, true_digit in images:
        # ── Golden model ──────────────────────────────────────────────────────
        pred_golden, golden_out = run_golden(img_path, true_digit, sim_dir)

        # ── DIAGNÓSTICO: verificar se img_test.hex foi atualizado ─────────────────
        with open(sim_dir / "img_test.hex") as f:
            first_pixel = f.readline().strip()
        print(f"    [DBG] img_test.hex primeiro pixel: {first_pixel}")


        if pred_golden is None:
            print(f"  [ERR] {img_path.name}: golden model falhou")
            errors += 1
            continue

        # Detecta divergência float vs Q4.12
        divergent = "divergem" in golden_out
        if divergent and args.skip_divergent:
            skipped += 1
            continue

        # ── Hardware ──────────────────────────────────────────────────────────
        pred_hw, hw_out = run_hardware(sim_dir)

        if pred_hw is None:
            print(f"  [ERR] {img_path.name}: testbench falhou")
            print(hw_out[-500:])   # últimas 500 chars do output
            errors += 1
            continue

        # ── Contabilização ────────────────────────────────────────────────────
        total += 1
        per_digit[true_digit]["total"] += 1

        gold_ok = (pred_golden == true_digit)
        hw_ok   = (pred_hw == true_digit)
        agree   = (pred_hw == pred_golden)

        if gold_ok:
            golden_correct += 1
            per_digit[true_digit]["gold_ok"] += 1
        if hw_ok:
            hw_correct += 1
            per_digit[true_digit]["hw_ok"] += 1
        if agree:
            hw_golden_agree += 1

        # ── Status por imagem ─────────────────────────────────────────────────
        status = "✓" if agree else "✗"
        div_tag = " [DIV]" if divergent else ""
        print(f"  {status} {img_path.parent.name}/{img_path.name:<12} "
              f"true={true_digit}  gold={pred_golden}  hw={pred_hw}{div_tag}")

    # ── Relatório final ───────────────────────────────────────────────────────
    print("\n" + "=" * 60)
    print(" RELATÓRIO FINAL")
    print("=" * 60)
    print(f" Total avaliado     : {total}")
    print(f" Pulados (divergentes): {skipped}")
    print(f" Erros de execução  : {errors}")
    print()

    if total > 0:
        print(f" Acurácia golden    : {golden_correct}/{total} "
              f"= {100*golden_correct/total:.1f}%")
        print(f" Acurácia hardware  : {hw_correct}/{total} "
              f"= {100*hw_correct/total:.1f}%")
        print(f" HW == Golden       : {hw_golden_agree}/{total} "
              f"= {100*hw_golden_agree/total:.1f}%")

        print("\n Acurácia por dígito (hardware):")
        print(f"  {'Dígito':>6}  {'HW ok':>6}  {'Total':>6}  {'Acc':>6}")
        for d in range(10):
            t = per_digit[d]["total"]
            h = per_digit[d]["hw_ok"]
            if t > 0:
                print(f"  {d:>6}  {h:>6}  {t:>6}  {100*h/t:>5.1f}%")

    print("=" * 60)


if __name__ == "__main__":
    main()