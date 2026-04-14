"""
png_to_mif.py
-------------
Converte imagens .png de dígitos para o formato .mif (Memory Initialization File).

Estrutura esperada de pastas:
    pasta_raiz/
        0/
            img_001.png
            img_002.png
        1/
            img_001.png
        ...
        9/
            ...

Uso:
    python png_to_mif.py --input <pasta_raiz> --output <pasta_saida>

Requisitos:
    pip install Pillow
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("[ERRO] Biblioteca 'Pillow' não encontrada.")
    print("       Instale com: pip install Pillow")
    sys.exit(1)

# Constantes do formato MIF (padrão MNIST 28x28 grayscale)
EXPECTED_WIDTH  = 28
EXPECTED_HEIGHT = 28
DEPTH           = EXPECTED_WIDTH * EXPECTED_HEIGHT  # 784
BIT_WIDTH       = 8


def pixel_to_hex(value: int) -> str:
    """Converte valor de pixel (0-255) para string hex de 2 dígitos maiúsculos."""
    return f"{value:02X}"


def generate_mif(pixels: list[int]) -> str:
    """Gera o conteúdo completo de um arquivo .mif a partir de uma lista de 784 pixels."""
    lines = [
        f"DEPTH = {DEPTH};",
        f"WIDTH = {BIT_WIDTH};",
        "ADDRESS_RADIX = DEC;",
        "DATA_RADIX = HEX;",
        "CONTENT BEGIN",
    ]

    for addr, value in enumerate(pixels):
        lines.append(f"\t{addr} : {pixel_to_hex(value)};")

    lines.append("END;")
    return "\n".join(lines) + "\n"


def validate_and_load_image(png_path: Path) -> list[int] | None:
    """
    Carrega e valida uma imagem PNG.
    Retorna lista de pixels ou None se a imagem for inválida (com log do motivo).
    """
    try:
        img = Image.open(png_path)
    except Exception as e:
        print(f"  [PULADO] {png_path.name} — não foi possível abrir: {e}")
        return None

    # Validação de modo de cor
    if img.mode != "L":
        print(f"  [PULADO] {png_path.name} — modo de cor '{img.mode}' (esperado: grayscale 'L')")
        return None

    # Validação de dimensões
    if img.size != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
        print(f"  [PULADO] {png_path.name} — dimensões {img.size} (esperado: {EXPECTED_WIDTH}x{EXPECTED_HEIGHT})")
        return None

    return list(img.getdata())


def convert_digit_folder(digit_folder: Path, output_folder: Path, digit: str) -> tuple[int, int]:
    """
    Converte todos os PNGs de uma pasta de dígito para .mif.
    Retorna (convertidos, pulados).
    """
    png_files = sorted(digit_folder.glob("*.png"))

    if not png_files:
        print(f"\n[AVISO] Pasta '{digit_folder.name}' não contém arquivos .png. Pulando.")
        return 0, 0

    digit_output = output_folder / f"digito_{digit}"
    digit_output.mkdir(parents=True, exist_ok=True)

    converted = 0
    skipped   = 0

    print(f"\n[Dígito {digit}] {len(png_files)} arquivo(s) encontrado(s) em '{digit_folder}'")

    for png_path in png_files:
        pixels = validate_and_load_image(png_path)

        if pixels is None:
            skipped += 1
            continue

        mif_filename = f"digito{digit}_{png_path.stem}.mif"
        mif_path     = digit_output / mif_filename

        mif_content = generate_mif(pixels)
        mif_path.write_text(mif_content, encoding="utf-8")

        print(f"  [OK] {png_path.name} → {mif_path.relative_to(output_folder.parent)}")
        converted += 1

    return converted, skipped


def main():
    parser = argparse.ArgumentParser(
        description="Converte imagens .png de dígitos para o formato .mif"
    )
    parser.add_argument(
        "--input", "-i",
        required=True,
        help="Pasta raiz contendo subpastas nomeadas por dígito (0-9)"
    )
    parser.add_argument(
        "--output", "-o",
        default="mif_output",
        help="Pasta de saída para os arquivos .mif (padrão: ./mif_output)"
    )
    args = parser.parse_args()

    input_root  = Path(args.input)
    output_root = Path(args.output)

    # Valida pasta de entrada
    if not input_root.is_dir():
        print(f"[ERRO] Pasta de entrada não encontrada: '{input_root}'")
        sys.exit(1)

    # Busca subpastas nomeadas de 0 a 9
    digit_folders = sorted(
        [d for d in input_root.iterdir() if d.is_dir() and d.name.isdigit()],
        key=lambda d: int(d.name)
    )

    if not digit_folders:
        print(f"[ERRO] Nenhuma subpasta de dígito (0-9) encontrada em '{input_root}'")
        sys.exit(1)

    output_root.mkdir(parents=True, exist_ok=True)

    print("=" * 55)
    print("         Conversão PNG → MIF")
    print("=" * 55)
    print(f"Entrada : {input_root.resolve()}")
    print(f"Saída   : {output_root.resolve()}")
    print(f"Dígitos encontrados: {[d.name for d in digit_folders]}")

    total_converted = 0
    total_skipped   = 0

    for digit_folder in digit_folders:
        converted, skipped = convert_digit_folder(
            digit_folder, output_root, digit_folder.name
        )
        total_converted += converted
        total_skipped   += skipped

    print("\n" + "=" * 55)
    print(f"  Concluído: {total_converted} convertido(s), {total_skipped} pulado(s)")
    print("=" * 55)


if __name__ == "__main__":
    main()
