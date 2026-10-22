"""Writes the editor's small layer textures (editor/runtime/override/textures/editor/layers).

clear_albedo.dds   4 x 4, fully transparent: the "no texture" of the Upper layer (the terrain shader lerps the Upper albedo over everything
                   below with its alpha, so an Upper layer that is not transparent hides the base layer and every painted layer).
pbr_atlas_neutral.dds   4 x 4, the same value everywhere: the Upper layer of the PBR shaders (Terrain1xx / 2xx) is a 2 x 2 atlas with roughness in R and B and height in G and A
                   (R, G: Base and layers 1-3; B, A: layers 4-7). Roughness 0.65, height 0.5: every layer alike (stratumconv.lua puts it there when a map is converted to those shaders).
"""
import os
import struct

root = os.path.join(os.path.dirname(__file__), '..', 'runtime', 'override', 'textures', 'editor', 'layers')
os.makedirs(root, exist_ok=True)
header = (b'DDS ' + struct.pack('<7I', 124, 0x100F, 4, 4, 16, 0, 0) + b'\0' * 44
          + struct.pack('<8I', 32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000) + struct.pack('<5I', 0x1000, 0, 0, 0, 0))
with open(os.path.join(root, 'clear_albedo.dds'), 'wb') as f:
    f.write(header + b'\0' * 64)

rough, height = 166, 128
pixel = struct.pack('4B', rough, height, rough, height)        # stored B, G, R, A: R and B = roughness, G and A = height
with open(os.path.join(root, 'pbr_atlas_neutral.dds'), 'wb') as f:
    f.write(header + pixel * 16)
