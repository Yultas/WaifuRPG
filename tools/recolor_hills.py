"""Recolors Sprout Lands Hills.png to match other ground palettes.

Hills.png uses the grass palette of the Basic pack. The Sorry pack ground tilesets
(Grass_Tile_Layers, snow tiles) use a lighter grass and a snow palette, so the cliffs
are recolored to match them. Cliff faces and stairs keep their colors.

Run from the project root: python3 tools/recolor_hills.py
Writes tiles/generated/hills_spring.png and tiles/generated/hills_snow.png.
"""
from pathlib import Path

from PIL import Image

SOURCE = Path("tiles/Sprout Lands - Sprites - Basic pack/Tilesets/Hills.png")
OUT = Path("tiles/generated")

# Basic pack grass role -> color in the target palette.
PALETTES = {
    "hills_spring.png": {
        (210, 224, 119): (226, 234, 155),  # highlight
        (192, 212, 112): (210, 224, 119),  # fill
        (164, 194, 99): (192, 212, 112),   # light edge
        (141, 177, 93): (178, 203, 105),   # mid edge
        (120, 161, 88): (141, 177, 93),    # outline
    },
    "hills_snow.png": {
        (210, 224, 119): (250, 251, 243),
        (192, 212, 112): (243, 244, 231),
        (164, 194, 99): (214, 241, 205),
        (141, 177, 93): (177, 224, 190),
        (120, 161, 88): (155, 212, 195),
        (232, 238, 170): (230, 243, 219),
        (234, 225, 120): (243, 244, 231),
    },
}


def main() -> None:
    source = Image.open(SOURCE).convert("RGBA")
    OUT.mkdir(parents=True, exist_ok=True)
    for name, mapping in PALETTES.items():
        image = source.copy()
        pixels = image.load()
        for y in range(image.height):
            for x in range(image.width):
                r, g, b, a = pixels[x, y]
                if a and (r, g, b) in mapping:
                    pixels[x, y] = (*mapping[(r, g, b)], a)
        image.save(OUT / name)
        print("wrote", OUT / name)


if __name__ == "__main__":
    main()
