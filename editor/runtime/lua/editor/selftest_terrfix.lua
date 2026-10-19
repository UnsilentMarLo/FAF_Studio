-- Self test of the texture / terrain type fixes: the overlay window of a node grid (overlaywin.lua), the terrain type codes under it (terraintype.lua NodeCodes), removing a layer's texture with
-- what it painted (strata.lua RemoveTexture), the engine's coarse node grids and the editor's terrain shader (the normal passes weigh the masks like the albedo passes). Run in the live editor:
--   return import('/lua/editor/selftest_terrfix.lua').Run()
-- Returns a report; the first line is PASS or FAIL (Run(true) lists every check).
--
-- Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn).

local Win = import('/lua/editor/overlaywin.lua')
local TT = import('/lua/editor/terraintype.lua')
local Strata = import('/lua/editor/strata.lua')
local Fields = import('/lua/editor/fields.lua')

function Run(verbose)
    local failures, lines = {}, {}
    local function check(name, ok, detail)
        if ok then
            table.insert(lines, '  ok   ' .. name)
        else
            table.insert(failures, name)
            table.insert(lines, '  FAIL ' .. name .. ' ' .. tostring(detail or ''))
        end
    end

    -- ---- the overlay window ---------------------------------------------------------------------------------------------------------------
    local function IsPow2(n) return n >= 1 and math.floor(math.log(n) / math.log(2) + 0.5) == math.log(n) / math.log(2) end
    local boxes = {
        { 0, 0, 1024, 1024, 1024 }, { 100, 100, 140, 150, 1024 }, { 300, 40, 900, 700, 1024 }, { 0, 0, 256, 256, 256 }, { 10, 10, 60, 60, 256 }, { 0, 0, 4096, 4096, 4096 },
    }
    local allOk, detail = true, ''
    for _, b in boxes do
        local x0, z0, nw, nh, step = Win.Fit(b[1], b[2], b[3], b[4], b[5], 290)
        local snap = math.max(8, step)
        local cx1 = x0 + (nw - 1) * step
        local cz1 = z0 + (nh - 1) * step
        local ok = nw >= 2 and nh >= 2 and nw <= 290 and nh <= 290 and IsPow2(step) and math.mod(x0, snap) == 0 and math.mod(z0, snap) == 0
            and x0 <= b[1] and z0 <= b[2] and cx1 >= math.min(b[5], b[3]) - 0.001 and cz1 >= math.min(b[5], b[4]) - 0.001
        if not ok then
            allOk = false
            detail = detail .. string.format(' [%d %d %d %d / %d -> %d %d %d %d step %d]', b[1], b[2], b[3], b[4], b[5], x0, z0, nw, nh, step)
        end
    end
    check('window covers the box in at most 290 nodes, power of two steps, snapped', allOk, detail)
    local _, _, nw1, nh1, s1 = Win.Fit(0, 0, 1024, 1024, 1024, 290)
    check('a whole 20 km map is drawn at 4 units per node', s1 == 4 and nw1 == 257 and nh1 == 257, s1 .. ' ' .. nw1)
    local _, _, _, _, s2 = Win.Fit(100, 100, 140, 150, 1024, 290)
    check('a close view keeps one node per unit', s2 == 1)
    local x0, z0, nw2 = Win.Fit(0, 0, 250, 250, 256, 290)
    check('a whole 5 km map is drawn at one node per unit', x0 == 0 and z0 == 0 and nw2 == 257, nw2)

    -- ---- terrain type codes under a node grid ------------------------------------------------------------------------------------------------
    local gw, gh = ed_tt_info()
    local size = ed_terrain_info()
    if gw and size then
        local cs = (size - 1) / gw
        local before = ed_tt_read(0, 0, gw - 1, gh - 1)
        local base = {}
        for i = 1, gw * gh do base[i] = 80 end
        ed_tt_write(0, 0, gw - 1, gh - 1, base)
        -- a block of code 150 in the cells x 64..127, z 32..95 (world units: times the cell size)
        local blockW, blockH = 64, 64
        local vals = {}
        for i = 1, blockW * blockH do vals[i] = 150 end
        ed_tt_write(64, 32, 127, 95, vals)
        local function At(codes, nw, step, x, z, x0g, z0g) return codes[math.floor((z - z0g) / step) * nw + math.floor((x - x0g) / step) + 1] end
        local codes = TT.NodeCodes(0, 0, 130, 100, 1)
        local inside = At(codes, 130, 1, 64 * cs + 2, 32 * cs + 2, 0, 0)
        local outsideX = At(codes, 130, 1, 64 * cs - 2, 32 * cs + 2, 0, 0)
        local outsideZ = At(codes, 130, 1, 64 * cs + 2, 32 * cs - 2, 0, 0)
        check('codes under a fine grid', inside == 150 and outsideX == 80 and outsideZ == 80, tostring(inside) .. ' ' .. tostring(outsideX) .. ' ' .. tostring(outsideZ))
        local coarse = TT.NodeCodes(0, 0, 33, 33, 4)
        local ci = At(coarse, 33, 4, 80 * cs, 40 * cs, 0, 0)
        local co = At(coarse, 33, 4, 8 * cs, 8 * cs, 0, 0)
        check('codes under a coarse grid (4 units per node)', ci == 150 and co == 80, tostring(ci) .. ' ' .. tostring(co))
        check('a grid beyond the map edge is clamped', TT.NodeCodes(size - 20, size - 20, 40, 40, 1)[1600] ~= nil)
        ed_tt_write(0, 0, gw - 1, gh - 1, before)
    else
        table.insert(lines, '  skip terrain type tests (no grid)')
    end

    -- ---- the engine's node grid takes a step ------------------------------------------------------------------------------------------------------
    if rawget(_G, 'ed_overlay_nodes') then
        local grid = {}
        for i = 1, 40 * 40 do grid[i] = 100 end
        check('overlay nodes with a step', ed_overlay_nodes('selftest:nodes', 0, 0, 40, 40, grid, 'FF0000', 100, 4) == true)
        ed_overlay_remove('selftest:nodes')
    end

    -- ---- removing a layer's texture ----------------------------------------------------------------------------------------------------------------
    local mw, mh = ed_stratum_info()
    if mw then
        local snap2, snap9 = Strata.Snapshot(2), Strata.Snapshot(9)
        Strata.SetTexture(2, '/env/evergreen/layers/rockmed_albedo.dds', nil, 6, 6)
        Strata.ClearMask(2)
        Strata.FillMask(2)
        local function Sum() return Fields.Run(function(S) return Fields.Checksum(S:Stratum(2, true)) end) end
        local full = Sum()
        local entry = Strata.RemoveTexture(2)
        check('remove texture makes an entry', entry ~= nil)
        if entry then
            check('the layer is transparent now', ed_stratum_layer(2) == Strata.CLEAR, ed_stratum_layer(2))
            local mn, mx = Fields.Run(function(S) local a, b = Fields.Stats(S:Stratum(2)) return a, b end)
            check('what it painted is gone', mn == 0 and mx == 0, mn .. ' ' .. mx)
            entry.undo()
            check('undo brings the texture back', ed_stratum_layer(2) == '/env/evergreen/layers/rockmed_albedo.dds' and ed_stratum_layer(12) == '/env/evergreen/layers/rockmed_normals.dds',
                tostring(ed_stratum_layer(2)) .. ' ' .. tostring(ed_stratum_layer(12)))
            check('undo brings the mask back exactly', Sum() == full)
            entry.redo()
            local mn2, mx2 = Fields.Run(function(S) local a, b = Fields.Stats(S:Stratum(2)) return a, b end)
            check('redo removes both again', ed_stratum_layer(2) == Strata.CLEAR and mx2 == 0)
        end
        Strata.ClearMask(2)
        Strata.Restore(snap2)
        local up = Strata.RemoveTexture(9)
        check('the upper layer has no mask to clear', up ~= nil and ed_stratum_layer(9) == Strata.CLEAR)
        if up then up.undo() end
        Strata.Restore(snap9)
    else
        table.insert(lines, '  skip strata tests (no mask)')
    end

    -- ---- the editor's terrain shader ---------------------------------------------------------------------------------------------------------------
    local disk = rawget(_G, 'ed_vfs_to_disk') and ed_vfs_to_disk('/effects/terrain.fx')
    check('the editor shadows /effects/terrain.fx', disk and string.find(string.lower(disk), 'override', 1, true) ~= nil, tostring(disk))
    local text = disk and rawget(_G, 'ed_read_file') and ed_read_file(disk)
    check('its normal passes weigh the masks like the albedo passes', text and string.find(text, "EDITOR: the albedo's weight", 1, true) ~= nil)

    local shown = lines
    if not verbose then
        shown = {}
        for _, l in lines do
            if string.sub(l, 1, 6) ~= '  ok  ' then table.insert(shown, l) end
        end
        table.insert(shown, '  ' .. (table.getn(lines) - table.getn(shown)) .. ' checks ok')
    end
    if table.getn(failures) > 0 then
        return 'FAIL (' .. table.getn(failures) .. ': ' .. table.concat(failures, ', ') .. ')\n' .. table.concat(shown, '\n')
    end
    return 'PASS\n' .. table.concat(shown, '\n')
end
