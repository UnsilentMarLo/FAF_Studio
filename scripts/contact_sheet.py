#!/usr/bin/env python
"""Puts several pictures into one contact sheet (the texture lab's photos): python scripts/contact_sheet.py out.png cols cellW cellH a.png b.png ..."""
import sys
from PIL import Image

out, cols, cw, ch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
files = sys.argv[5:]
rows = (len(files) + cols - 1) // cols
sheet = Image.new('RGB', (cw * cols, ch * rows))
for i, f in enumerate(files):
    im = Image.open(f).convert('RGB').resize((cw, ch))
    sheet.paste(im, ((i % cols) * cw, (i // cols) * ch))
sheet.save(out)
print('wrote', out, sheet.size)
