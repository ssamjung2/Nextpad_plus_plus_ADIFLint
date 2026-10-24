#!/usr/bin/env python3
"""Writes data/relief.jpg, the Map's terrain, from Natural Earth's 1:50m Shaded Relief Basic.

Usage: python3 -I tools/gen_relief.py SR_50M.tif data/relief.jpg   (needs Pillow)

SR_50M.tif (in https://naciscdn.org/naturalearth/50m/raster/SR_50M.zip, public domain) is
10,800 x 5,400 8-bit grey in plate carree, -180..180 and -90..90 (its .tfw), with flat ground
and the sea both at 206. This scales it to 8,192 x 4,096 and maps 206 to 128, so that drawn in
soft light over the map's land colour flat ground changes nothing: darker than 128 shades a
slope away from the light, lighter lights one facing it.
"""
import sys

from PIL import Image

FLAT = 206  # measured: the sea, and flat land such as Kansas and the Netherlands


def main(src, dst):
    Image.MAX_IMAGE_PIXELS = None
    im = Image.open(src)
    if im.mode != "L" or im.size != (10800, 5400):
        sys.exit(f"expected 10800 x 5400 greyscale, got {im.mode} {im.size}")
    im = im.resize((8192, 4096), Image.LANCZOS)
    lut = [round(128 * v / FLAT) if v <= FLAT else round(128 + 127 * (v - FLAT) / (255 - FLAT)) for v in range(256)]
    im = im.point(lut)
    im.save(dst, "JPEG", quality=88, optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
