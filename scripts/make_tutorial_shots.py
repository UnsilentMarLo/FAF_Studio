#!/usr/bin/env python3
"""Screenshots for docs/projects/editor/TERRAIN_TUTORIAL.md, taken through the editor test harness (scripts/editor_inst.py: a window of the running instance).

    python scripts/make_tutorial_shots.py [--tag t7] [--only name,name]

The instance has to run the tree that holds the Lua (editor_inst.py start <tag> --map editor_blank_1024). Every shot is a Lua chunk that puts the editor into the state shown, then
`editor_inst.py shot`. The pictures go to docs/projects/editor/tutorial/<name>.png.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
OUT = os.path.join(ROOT, 'docs', 'projects', 'editor', 'tutorial')

PRE = """
local shell = import('/lua/editor/gui/shell.lua')
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Pal = import('/lua/editor/gui/panels_graphpalette.lua')
local Canvas = import('/lua/editor/gui/panels_graph.lua')
local function Show(ws) pcall(shell.ShowWorkspace, ws) end
local function Load(id)
    Show('Generate')
    GRun.Release()
    Graph.LoadPreset(id)
    GRun.Refresh(true)
    local cv = Canvas.live.canvas
    if cv then cv:Fit() cv:Tick(true) end
end
local function Pick(type)
    for _, n in Graph.Current.nodes do
        if n.type == type then Graph.SelectOne(n.id) return n end
    end
end
local function Tick() local cv = Canvas.live.canvas if cv then cv:Tick(true) end end
"""

# name -> Lua body (after PRE); a body may end with `return 'text'`
SHOTS = {
    # the library list with the thumbnail and the README line of the graph that was loaded
    'library': """
Show('Generate')
Pal.state.tab = 'graphs'
local Pn = Pal.live.palette
Pn:OnResize(Pn.w, Pn.h)
Pn:Rebuild()
for _, it in Pn.items do
    if it.id == 'lib_two_islands' then Pn:LoadPreset(it) end
end
GRun.Refresh(true)
Tick()
return 'ok'
""",
    # a library graph on the canvas, every node with its own thumbnail
    'canvas': """
Load('lib_duel_turn')
Graph.ClearSelection()
Tick()
return 'ok'
""",
    # the inspector of a node: sliders, choices, presets
    'inspector': """
Load('lib_highlands')
Pick('stratify')
Tick()
return 'ok'
""",
    # the colour ramp and its thumbnail
    'colour': """
Load('lib_colour_pass')
Pick('color_ramp')
Tick()
return 'ok'
""",
    # the result on the real terrain
    'on_terrain': """
Load('lib_tropics')
GRun.ShowOnTerrain()
local cam = GetCamera('WorldCamera')
cam:SnapTo(Vector(512, 40, 800), { 0, 0.72, 0 }, 1250)
return 'ok'
""",
    # the SC terrain panel (pads, symmetry, slope limit, skeleton, water)
    'sc_panel': """
Show('Terrain')
shell.FocusPanel('sctools')
return 'ok'
""",
    'paths_panel': """
Show('Terrain')
shell.FocusPanel('paths')
return 'ok'
""",
    'interop_panel': """
Show('Terrain')
shell.FocusPanel('interop')
return 'ok'
""",
}


def run(tag, name, body, out):
    chunk = PRE + body
    tmp = tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False)
    tmp.write(chunk)
    tmp.close()
    r = subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'cmd', tag, tmp.name, '--timeout', '300'], capture_output=True, text=True, cwd=ROOT)
    print(name, r.stdout.strip()[:200])
    os.unlink(tmp.name)
    subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'focus', tag], capture_output=True, text=True, cwd=ROOT)
    time.sleep(2.0)                                     # a few frames for the layout and the thumbnails
    s = subprocess.run([sys.executable, os.path.join(HERE, 'editor_inst.py'), 'shot', tag, out], capture_output=True, text=True, cwd=ROOT)
    print('   ', s.stdout.strip()[-120:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tag', default='t7')
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    names = a.only.split(',') if a.only else list(SHOTS)
    for name in names:
        run(a.tag, name, SHOTS[name], os.path.join(OUT, name + '.png'))


if __name__ == '__main__':
    main()
