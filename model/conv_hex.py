#!/usr/bin/env python3
"""
conv.py — Conversor de imagem PNG para HEX compatível com $readmemh
TEC 499 · MI Sistemas Digitais · UEFS 2026.1

Converte uma imagem PNG qualquer para o formato HEX usado pelo co-processador
ELM: 784 linhas (28×28 pixels), um byte por linha em hexadecimal maiúsculo.
O arquivo gerado pode ser carregado diretamente via:
  - $readmemh em simulação (Icarus Verilog, ModelSim)
  - STORE_IMG via MMIO pelo driver Linux (Marco 2)
  - elm_golden.py --img para validação pelo golden model

Fluxo de conversão:
    PNG (qualquer tamanho/modo)
        → escala de cinza (modo L)
        → redimensiona para 28×28 pixels com filtro LANCZOS
        → [opcional] inverte: pixel = 255 - pixel
        → escreve 784 linhas "XX\\n" em hexadecimal maiúsculo

Nota sobre inversão:
    O conjunto MNIST usa convenção fundo preto (pixel=0), dígito branco (pixel=255).
    Imagens capturadas em papel branco têm a convenção oposta e precisam de --invert.
    O golden model e o hardware não fazem essa distinção — a responsabilidade
    de normalizar a polaridade da imagem é do pré-processamento (este script).

Uso:
    python conv.py entrada.png saida.hex
    python conv.py entrada.png saida.hex --invert

Argumentos posicionais:
    entrada.png   Imagem de entrada (qualquer formato suportado pelo Pillow)
    saida.hex     Arquivo HEX de saída (784 linhas, formato $readmemh)

Opções:
    --invert      Inverte a intensidade de cada pixel (255 - pixel)

Exemplos:
    # Converte imagem MNIST padrão (fundo preto)
    python conv.py test/3/1278.png sim/img_test.hex

    # Converte foto de dígito escrito em papel branco
    python conv.py foto_digito.png sim/img_test.hex --invert

    # Verifica o resultado com o golden model
    python elm_golden.py --img sim/img_test.hex --weights-dir sim/

Dependências:
    pip install pillow
"""

import sys
from pathlib import Path
from PIL import Image


def convert(input_path: str, output_path: str, invert: bool = False) -> None:
    """
    Converte PNG para HEX de 784 pixels.

    Parâmetros:
        input_path  : caminho da imagem de entrada
        output_path : caminho do arquivo HEX de saída
        invert      : se True, aplica pixel = 255 - pixel antes de escrever
    """
    # Converte para escala de cinza e redimensiona para 28×28
    img = Image.open(input_path).convert("L").resize((28, 28), Image.LANCZOS)
    pixels = list(img.getdata())   # 784 inteiros [0..255], ordem raster (linha a linha)

    if invert:
        pixels = [255 - p for p in pixels]

    # Escreve um byte por linha em hexadecimal maiúsculo de 2 dígitos
    # Formato compatível com $readmemh do Verilog e com load_image_hex() do golden model
    with open(output_path, "w") as f:
        for p in pixels:
            f.write(f"{p:02X}\n")

    print(f"OK: {len(pixels)} pixels → {output_path}")
    if invert:
        print("(inversão aplicada: pixel = 255 - pixel)")


def main():
    if len(sys.argv) < 3:
        print("Uso: python conv.py entrada.png saida.hex [--invert]")
        print("     --invert   Inverte pixels (fundo branco → fundo preto)")
        sys.exit(1)

    input_path  = sys.argv[1]
    output_path = sys.argv[2]
    invert      = "--invert" in sys.argv

    convert(input_path, output_path, invert)


if __name__ == "__main__":
    main()