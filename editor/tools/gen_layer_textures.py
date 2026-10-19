"""Writes the editor's small layer textures (editor/runtime/override/textures/editor/layers).

clear_albedo.dds   4 x 4, fully transparent: the "no texture" of the Upper layer (the terrain shader lerps the Upper albedo over everything
                   below with its alpha, so an Upper layer that is not transparent hides the base layer and every painted layer).
"""
import os
import struct

root = os.path.join(os.path.dirname(__file__), '..', 'runtime', 'override', 'textures', 'editor', 'layers')
os.makedirs(root, exist_ok=True)
header = (b'DDS ' + struct.pack('<7I', 124, 0x100F, 4, 4, 16, 0, 0) + b'\0' * 44
          + struct.pack('<8I', 32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000) + struct.pack('<5I', 0x1000, 0, 0, 0, 0))
with open(os.path.join(root, 'clear_albedo.dds'), 'wb') as f:
    f.write(header + b'\0' * 64)
