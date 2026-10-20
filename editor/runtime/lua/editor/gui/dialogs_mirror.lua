-- The "Mirror the whole half" dialog (Edit > Mirror the whole half...): which region of the symmetry is the source, which kinds of objects follow, whether units go to the mirrored army,
-- and whether the other regions are emptied first. The source region is drawn in the viewport while the dialog is open. Logic: mirrorhalf.lua.
--
--   Open()
--
-- Lua 5.0 dialect.

local Skin = import('/lua/editor/gui/skin.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')
local H = import('/lua/editor/mirrorhalf.lua')
local Symmetry = import('/lua/editor/symmetry.lua')

local REPORT_LINES = 6

Options = { sector = 1, cats = { markers = true, areas = true, props = true, decals = true, units = true }, mode = 'add', armies = false }

local function Say(text)
    pcall(function() import('/lua/editor/ui.lua').Say(text) end)
end

local LABELS = { markers = 'Markers', areas = 'Areas', props = 'Props', decals = 'Decals', units = 'Units' }

function Open()
    local O = Options
    O.armies = O.armies or H.ArmyMode
    if Symmetry.Mode == 'off' then
        Say('mirror: set a symmetry mode first (Symmetry panel)')
        return
    end
    local sectors = H.Sectors()
    if O.sector > table.getn(sectors) then O.sector = 1 end
    local d = Dialog.Open('Mirror the whole half  (one undo step)', 560, 410, function() H.ClearSector() end)
    local c = Skin.color
    local catButtons, lines = {}, {}
    local sectorBtn, modeBtn, armyBtn, go

    local function Redraw()
        local plan = H.Plan({ sector = O.sector, cats = O.cats, mode = O.mode, armies = O.armies })
        sectorBtn:SetText(sectors[O.sector].label)
        modeBtn:SetText(O.mode == 'replace' and 'Replace what is in the other regions' or 'Add the images (keep what is there)')
        armyBtn:SetText(O.armies == 'map' and 'to the army of the mirrored start position' or 'stay with their army')
        for k, b in catButtons do b:SetOn(O.cats[k] and true or false) end
        for i = 1, REPORT_LINES do
            local text, color = '', c.text
            if plan.error then
                if i == 1 then text, color = plan.error, c.error end
            else
                local s = plan.source
                if i == 1 then text = 'Source region: ' .. plan.sector.label .. ' (' .. plan.nSource .. ' objects)'
                elseif i == 2 then text = 'markers ' .. table.getn(s.markers) .. ', areas ' .. table.getn(s.areas) .. ', props ' .. table.getn(s.props) .. ', decals ' .. table.getn(s.decals) .. ', units ' .. table.getn(s.units)
                elseif i == 3 then text = plan.images .. ' copies will be made'
                elseif i == 4 and plan.others then text = plan.nOthers .. ' objects in the other regions will be removed first' color = c.warn
                elseif i == 5 and O.cats.markers then text = 'start positions are never mirrored; copies are not added to the chains of their originals' color = c.textDim
                elseif i == 6 and O.cats.units and O.armies == 'map' then text = 'units go to the army whose start position mirrors the start position of their own army' color = c.textDim
                end
            end
            lines[i]:SetText(text)
            lines[i]:SetColor(color)
        end
        H.ShowSector(sectors[O.sector])
    end

    d:Label('Symmetry: ' .. string.gsub(Symmetry.Mode, '_', ' '), 14, 38, { color = c.textDim })
    d:Label('Copy from', 14, 70, { color = c.textDim })
    sectorBtn = d:Button('', 120, 66, 420, 24, function()
        O.sector = math.mod(O.sector, table.getn(sectors)) + 1
        Redraw()
    end, { tip = 'The region of the map that is copied. Click to step to the next region.' })
    d:Label('Objects', 14, 106, { color = c.textDim })
    local x = 120
    for _, k in H.CATEGORIES do
        local key = k
        catButtons[k] = d:Button(LABELS[k], x, 102, 80, 24, function()
            O.cats[key] = not O.cats[key]
            Redraw()
        end, { toggle = true })
        x = x + 84
    end
    d:Label('Units', 14, 142, { color = c.textDim })
    armyBtn = d:Button('', 120, 138, 420, 24, function()
        O.armies = (O.armies == 'map') and 'keep' or 'map'
        Redraw()
    end, { tip = 'Whether copied units go to the mirrored army or stay with their own. Click to change.' })
    d:Label('Result', 14, 178, { color = c.textDim })
    modeBtn = d:Button('', 120, 174, 420, 24, function()
        O.mode = (O.mode == 'replace') and 'add' or 'replace'
        Redraw()
    end, { tip = 'Replace what is on the other side, or add to it. Click to change.' })
    d:Label('What happens', 14, 216, { color = c.textDim })
    for i = 1, REPORT_LINES do lines[i] = d:Label('', 14, 236 + (i - 1) * 18, { color = c.text, size = 'small' }) end
    d:Label('Images cannot be flipped: a mirrored prop or decal keeps its image; only its heading is mirrored.', 14, 350, { color = c.textDim, size = 'small' })
    go = d:Button('Mirror', 14, 372, 110, 26, function()
        local opts = { sector = O.sector, cats = O.cats, mode = O.mode, armies = O.armies }
        Dialog.Close()
        local made, removed, why = H.Run(opts)
        if made > 0 or removed > 0 then
            Say('mirror: ' .. made .. ' copies' .. (removed > 0 and (', ' .. removed .. ' objects removed') or '') .. ' (one undo step)')
        else
            Say('mirror: ' .. tostring(why))
        end
    end)
    d:Button('Cancel', 134, 372, 110, 26, function() Dialog.Close() end)
    Redraw()
end
