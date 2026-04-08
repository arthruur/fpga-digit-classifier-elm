#!/usr/bin/env python3
"""
png_to_mif.py
Converte uma imagem .png para o formato .mif compatível com MNIST (28x28, grayscale).

Uso:
    python png_to_mif.py <input.png> [output.mif]

Se o nome de saída não for fornecido, usa o mesmo nome da entrada com extensão .mif.
"""

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow não encontrado. Instale com: pip install Pillow")
    sys.exit(1)


def png_to_mif(input_path: str, output_path: str = None):
    input_path = Path(input_path)

    if not input_path.exists():
        print(f"Erro: arquivo '{input_path}' não encontrado.")
        sys.exit(1)

    if not input_path.suffix.lower() == ".png":
        print(f"Aviso: o arquivo '{input_path}' não tem extensão .png, mas tentando mesmo assim.")

    # Define o nome de saída
    if output_path is None:
        output_path = input_path.with_suffix(".mif")
    else:
        output_path = Path(output_path)

    # Abre e processa a imagem
    img = Image.open(input_path)

    # Converte para escala de cinza (L = luminance, 8 bits)
    img = img.convert("L")

    # Redimensiona para 28x28 (padrão MNIST) usando LANCZOS para melhor qualidade
    img = img.resize((28, 28), Image.LANCZOS)

    # Obtém os pixels como lista plana (row-major, esquerda→direita, cima→baixo)
    pixels = list(img.getdata())  # 784 valores de 0-255

    depth = len(pixels)   # 784
    width = 8             # bits por pixel

    # Escreve o arquivo .mif
    with open(output_path, "w") as f:
        f.write(f"DEPTH = {depth};\n")
        f.write(f"WIDTH = {width};\n")
        f.write("ADDRESS_RADIX = DEC;\n")
        f.write("DATA_RADIX = HEX;\n")
        f.write("CONTENT BEGIN\n")

        for addr, value in enumerate(pixels):
            f.write(f"\t{addr} : {value:02X};\n")

        f.write("END;\n")

    print(f"Concluído! '{input_path}' → '{output_path}' ({depth} pixels)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python png_to_mif.py <input.png> [output.mif]")
        sys.exit(1)

    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) >= 3 else None

    png_to_mif(inp, out)
