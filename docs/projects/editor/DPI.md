# Editor and the Windows display scale (2026-10-20)

## The problem

On a display scaled above 100 % (125 %, 150 %) Windows treats a process that is not DPI aware as a 96 dpi program: it lets it render at 96 dpi and stretches the finished window to the
display scale. The editor was such a process. Everything on screen is then resampled, text most visibly (12 px text becomes blurry, whatever the glyph rasteriser does).

How it was found: in a screenshot of the Validation panel the buttons measured 105.0, 125.0 and 112.5 px wide and 27.5 px high. The panel code asks for 84, 100 and 90 px wide and 22 px
high (`Skin.S`, UI 100 %), and a button of 112.5 px cannot be drawn at native size: the screenshot is the editor magnified by exactly 1.25 (text cap height 10.3 px instead of 8.3 px).
Screenshots taken at native size have one-pixel edges with no intermediate colour.

## What the exe does now

No launcher, no script, no environment variable to set: `moho/editor/EdBootstrap.cpp` (engine patch 0034) runs first in `WinMain` of the editor build (`FAF_STUDIO_EDITOR`, an exe that has
`init_editor.lua` next to it or is started with `/editor`):

- the process becomes **system DPI aware** (`SetProcessDpiAwarenessContext(SYSTEM_AWARE)`, else `SetProcessDPIAware`) before any window exists, for every start, also the ones that have `/init`
  (scripts, tests): nothing is stretched, glyphs and edges land on real pixels;
- a start **without** `/init` (a double click) also sets `FAFSTUDIO_UISCALE` to the display scale (`GetDpiForSystem`, rounded to 0.25, 1 to 3) unless it is already set. `init_editor.lua` writes
  it to `editor_dpi.txt` (only the init state may read the environment) and `gui/shell.lua` uses it as the UI scale **when no UI scale was saved yet** (a first run), so the editor is as large on screen
  as before but sharp. Test instances (`editor_inst.py`, always with `/init`) stay at UI 100 %, whatever the display;
- the window is sized in real pixels (90 % of the work area, at most 1920 x 1080).

`FAFSTUDIO_DPI=0` switches the DPI awareness and the scale off (old behaviour: stretched by Windows).

## If you already have saved settings

A saved UI scale wins over the Windows scale. With the editor now DPI aware, a saved 100 % looks smaller than before on a 125 % display: press `+` in the top bar once (or delete the user folder's
`settings.lua` entry for a fresh start).

## Not verified

Written without a Windows machine: the module is built and tested on its own with mingw-w64 under Wine (`scripts/edbootstrap_test.py`: arguments, folders, copies, messages; Wine can neither
make junctions nor symbolic links, so those were not exercised), but the DPI calls, the junction code and the engine build with `FAF_STUDIO_EDITOR` have not run on Windows. A permanent alternative
to the call at start is an application manifest in the exe (`dpiAware`, `scripts/brand_exe.py` already rewrites the copied exe's resources).
