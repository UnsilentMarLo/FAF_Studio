# Editor and the Windows display scale (2026-10-20)

## The problem

On a display scaled above 100 % (125 %, 150 %) Windows treats a process that is not DPI aware as a 96 dpi program: it lets it render at 96 dpi and stretches the finished window to the
display scale. The editor was such a process. Everything on screen is then resampled, text most visibly (12 px text becomes blurry, whatever the glyph rasteriser does).

How it was found: in a screenshot of the Validation panel the buttons measured 105.0, 125.0 and 112.5 px wide and 27.5 px high. The panel code asks for 84, 100 and 90 px wide and 22 px
high (`Skin.S`, UI 100 %), and a button of 112.5 px cannot be drawn at native size: the screenshot is the editor magnified by exactly 1.25 (text cap height 10.3 px instead of 8.3 px).
Screenshots taken at native size have one-pixel edges with no intermediate colour.

## What the launchers do now

`editor/packaging/launch.ps1` (the packaged editor) and `scripts/editor_inst.py start` (test instances):

- set `__COMPAT_LAYER=HighDpiAware` for the engine process: it is DPI aware, nothing is stretched, glyphs and edges land on real pixels;
- read the display scale from the registry (`HKCU\Control Panel\Desktop\WindowMetrics\AppliedDPI`, else `LogPixels`), round it to 0.25 and pass it as `FAFSTUDIO_UISCALE`;
  `init_editor.lua` writes it to `editor_dpi.txt` (only the init state may read the environment) and `gui/shell.lua` uses it as the UI scale **when no UI scale was saved yet**
  (a first run), so the editor is as large on screen as before but sharp;
- `launch.ps1` sizes the window in real pixels (90 % of the work area times the scale, at most 1920 x 1080).

`FAFSTUDIO_DPI=0` switches all of this off (old behaviour: stretched by Windows).

## If you already have saved settings

A saved UI scale wins over the Windows scale. With the editor now DPI aware, a saved 100 % looks smaller than before on a 125 % display: press `+` in the top bar once (or delete
`userdata` of the instance for a fresh start; `editor_inst.py start` clears it unless `--keep-userdata` is given).

## Trying it without the new launcher

Right-click the editor exe, Properties, Compatibility, Change high DPI settings, tick "Override high DPI scaling behavior", scaling performed by: Application. Then press the UI `+`
button until the size suits (125 % on a 125 % display).

## Not verified

Written without a Windows machine: the registry reading and the environment variable were exercised with a faked registry only, and `__COMPAT_LAYER=HighDpiAware` was not tried
against the engine exe. A permanent fix in the exe (an application manifest with `dpiAware` / `permonitorv2`, or `SetProcessDpiAwarenessContext` before the window is created in
the engine) would replace the environment variable; `scripts/brand_exe.py` already rewrites the copied exe's resources.
