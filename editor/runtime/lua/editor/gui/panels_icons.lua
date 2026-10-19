-- The Icons panel (icongen.lua, docs/projects/MOD_UNIT_EDITOR_DESIGN.md stage S5): renders the unit icon of the unit chosen in the Units panel (or open in the Unit lab) with the fixed recipe, shows it beside
-- the icon the game ships and the difference of the two silhouettes, and writes it into the open mod project (textures/ui/common/icons/units/<id>_icon.dds, 64 x 64 DXT5).
-- "Batch" makes the icons of every unit the project edits or derives.
--
-- Lua 5.0 dialect.

local Bitmap = import('/lua/maui/bitmap.lua').Bitmap
local W = import('/lua/editor/gui/widgets.lua')
local Skin = import('/lua/editor/gui/skin.lua')
local Panels = import('/lua/editor/gui/panels.lua')
local UI = import('/lua/editor/ui.lua')
local Units = import('/lua/editor/units.lua')
local Bp = import('/lua/editor/bpedit.lua')
local Gen = import('/lua/editor/icongen.lua')

live = {}

local PREVIEW_DIR = '../icontmp'
local mounted = false
local serial = 0

local function Say(text)
    pcall(function() UI.Say(text) end)
end

--- Writes a picture to the preview folder (mounted as /icontmp) under a fresh name (textures are cached by name) and returns the VFS path.
local function Preview(img)
    serial = serial + 1
    local name = 'p' .. serial .. '.dds'
    if not ed_dds_write(PREVIEW_DIR .. '/' .. name, img.w, img.h, img.px, 1) then return nil end
    if not mounted then
        ed_vfs_mount(PREVIEW_DIR, '/icontmp')
        mounted = true
    end
    return '/icontmp/' .. name
end

local function CurrentUnit()
    local ok, lab = pcall(function() return import('/lua/editor/gui/panels_unitlab.lua').live.unitlab end)
    if ok and lab and lab.unit then return lab.unit end
    return Units.Active
end

Panels.Register{
    id = 'icons', title = 'Icons', stack = { workspace = 'Mod', with = 'unitview' },
    create = function(group, host)
        local P = { id = false, last = false, shipped = false, busy = false, text = '' }
        live.icons = P

        local function Btn(text, w, fn, opts) return W.Button(group, text, 0, 0, Skin.S(w), Skin.S(22), fn, opts) end

        local function Thumb(caption)
            local t = { frame = Bitmap(group), pic = Bitmap(group) }
            t.frame:SetSolidColor(Skin.color.panelAlt)
            t.frame.Depth:Set(function() return group.Depth() + 4 end)
            t.pic.Depth:Set(function() return group.Depth() + 6 end)
            t.pic:DisableHitTest()
            t.label = W.Label(group, caption, 0, 0, { color = Skin.color.textDim, size = 'small' })
            return t
        end
        P.tGen = Thumb('Render')
        P.tShip = Thumb('Game')
        P.tDiff = Thumb('Difference')
        local function Show(t, img)
            local path = img and Preview(img)
            if path then t.pic:SetTexture(path) t.pic:Show() else t.pic:Hide() end
        end

        local function Recipe(r) return Gen.Recipe end
        P.sHeading = W.Slider(group, { label = 'Heading (radians)', compact = true, min = 0, max = 6.3, step = 0.05, fmt = '%.2f', get = function() return Gen.Recipe.heading end, set = function(v) Gen.Recipe.heading = v end })
        P.sPitch = W.Slider(group, { label = 'Pitch (radians)', compact = true, min = 0.1, max = 1.5, step = 0.02, fmt = '%.2f', get = function() return Gen.Recipe.pitch end, set = function(v) Gen.Recipe.pitch = v end })
        P.sFov = W.Slider(group, { label = 'Field of view (deg)', compact = true, min = 8, max = 70, step = 1, fmt = '%d', get = function() return Gen.Recipe.fov end, set = function(v) Gen.Recipe.fov = v end })
        P.sFill = W.Slider(group, { label = 'Fill (picture share)', compact = true, min = 0.4, max = 1, step = 0.01, fmt = '%.2f', get = function() return Gen.Recipe.fill end, set = function(v) Gen.Recipe.fill = v end })
        P.sGlow = W.Slider(group, { label = 'Light edge (px, 0 off)', compact = true, min = 0, max = 6, step = 0.5, fmt = '%.1f', get = function() return Gen.Recipe.glow end, set = function(v) Gen.Recipe.glow = v end })
        P.status = W.Label(group, '', 0, 0, { color = Skin.color.textDim, size = 'small' })
        P.metrics = W.Label(group, '', 0, 0, { color = Skin.color.text, size = 'small' })

        local function Finish(msg)
            P.busy = false
            P.text = msg
            P:Refresh()
        end

        --- Renders the unit and compares it with the game's icon.
        local function Render(id, quiet)
            -- a derived unit is not in the running game until the project is enabled and the session reloaded; it looks like its base unit (same mesh), so the base is rendered
            local source = id
            if not (__blueprints and __blueprints[id]) and Bp.Derived[id] then source = Bp.Derived[id].base end
            local r, why = Gen.Capture(source, nil)
            if not r then Finish('icon: ' .. tostring(why)) return nil end
            P.id, P.last = id, r
            P.shipped = Gen.Shipped(source)
            Show(P.tGen, r)
            Show(P.tShip, P.shipped)
            if P.shipped then
                local c = Gen.Compare(r, P.shipped)
                Show(P.tDiff, Gen.DiffImage(r, P.shipped))
                W.Fit(P.metrics, string.format('overlap %.0f%%   colour %.0f   alpha %.0f   area %d / %d', c.iou * 100, c.color, c.alpha, c.areaA, c.areaB), (P.w or 300) - Skin.S(16))
            else
                Show(P.tDiff, nil)
                W.Fit(P.metrics, 'the game has no icon for ' .. id, (P.w or 300) - Skin.S(16))
            end
            if not quiet then Finish('rendered ' .. id) end
            return r
        end

        P.render = Btn('Render', 60, function()
            local id = CurrentUnit()
            if not id then Say('pick a unit in the Units panel first') return end
            if P.busy then return end
            P.busy = true
            Gen.Run(function() Render(id) end)
        end)
        P.write = Btn('Write', 50, function()
            if not Bp.Project then Say('open or create a mod project first (Unit lab)') return end
            if not P.last then Say('render an icon first') return end
            local path, bytes = Gen.Write(Bp.Project, P.id, P.last, 1)
            Say(path and ('icon written: ' .. path .. ' (' .. bytes .. ' bytes)') or ('icon: ' .. tostring(bytes)))
        end)
        P.batch = Btn('Batch', 54, function()
            if not Bp.Project then Say('open or create a mod project first (Unit lab)') return end
            if P.busy then return end
            -- every unit the project edits, derives or made with the wizard (icongen.Batch: the recipe of each unit's category)
            local ids = Gen.ProjectUnits()
            if table.getn(ids) == 0 then Say('the project has no unit yet') return end
            P.busy = true
            Gen.Run(function()
                local res = Gen.Batch(ids, { progress = function(id, i, n) P.text = 'batch ' .. i .. ' / ' .. n .. ': ' .. id P:Refresh() end })
                local failed, skipped = 0, 0
                for _ in res.failed do failed = failed + 1 end
                for _ in res.skipped do skipped = skipped + 1 end
                Finish('batch done: ' .. table.getn(res.done) .. ' icon(s) written' .. (failed > 0 and (', ' .. failed .. ' failed') or '') .. (skipped > 0 and (', ' .. skipped .. ' not in the game yet (Test the project)') or ''))
            end)
        end)

        function P:Refresh()
            for _, s in { P.sHeading, P.sPitch, P.sFov, P.sFill, P.sGlow } do s:Refresh() end
            W.Fit(P.status, (Bp.Project and ('Project: ' .. Bp.Project) or 'No project (Unit lab)') .. '   Unit: ' .. tostring(CurrentUnit() or 'none') .. '   ' .. P.text, (P.w or 300) - Skin.S(16))
        end

        function P:OnResize(w, h)
            P.w = w
            local pad = Skin.S(8)
            W.Place(P.render, group, pad, pad, Skin.S(60), Skin.S(22))
            W.Place(P.write, group, pad + Skin.S(64), pad, Skin.S(50), Skin.S(22))
            W.Place(P.batch, group, pad + Skin.S(118), pad, Skin.S(54), Skin.S(22))
            W.Place(P.status, group, pad, pad + Skin.S(28))
            local ty = pad + Skin.S(48)
            local size = math.max(Skin.S(64), math.min(Skin.S(64), math.floor((w - 4 * pad) / 3)))
            local x = pad
            for _, t in { P.tGen, P.tShip, P.tDiff } do
                W.Place(t.frame, group, x, ty, size, size)
                W.Place(t.pic, group, x, ty, size, size)
                W.Place(t.label, group, x, ty + size + Skin.S(2))
                x = x + size + pad
            end
            W.Place(P.metrics, group, pad, ty + size + Skin.S(20))
            -- two sliders per row (the five of them in one column did not fit the panel's default height)
            local y = ty + size + Skin.S(38)
            local half = math.floor((w - 3 * pad) / 2)
            local rows = { { P.sHeading, P.sPitch }, { P.sFov, P.sFill }, { P.sGlow } }
            for _, row in rows do
                for i, sl in row do sl:Place(pad + (i - 1) * (half + pad), y, half) end
                y = y + Skin.S(46)
            end
            P:Refresh()
        end
        return P
    end,
}
