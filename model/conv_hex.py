#!/usr/bin/env python3
# conv_hex.py — converte PNG 28x28 para hex compatível com $readmemh
# Uso: python3 conv_hex.py entrada.png saida.hex [--invert]

import sys
from PIL import Image

def convert(input_path, output_path, invert=False):
    img = Image.open(input_path).convert("L").resize((28, 28), Image.LANCZOS)
    pixels = list(img.getdata())
    if invert:
        pixels = [255 - p for p in pixels]
    with open(output_path, "w") as f:
        for p in pixels:
            f.write(f"{p:02X}\n")
    print(f"OK: {len(pixels)} pixels → {output_path}")
    if invert:
        print("(inversão aplicada: fundo branco → fundo preto)")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Uso: python3 conv_hex.py entrada.png saida.hex [--invert]")
        sys.exit(1)
    invert = "--invert" in sys.argv
    convert(sys.argv[1], sys.argv[2], invert)