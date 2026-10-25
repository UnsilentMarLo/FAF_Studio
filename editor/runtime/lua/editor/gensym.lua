-- Symmetric generation (docs/projects/editor/GEN_SYMMETRY.md): what a generator writes on the map (heights, paint masks, terrain types, props) is made symmetric at the moment it is written.
--
-- A graph can put a Symmetrize node in the middle, but everything after it (droplet erosion, noise rules of the paint, a scatter that throws dice) breaks the symmetry again: the heights of
-- the shipped symmetric graphs were exact at the Symmetrize node and off by units after the erosion, the paint was off by up to 60 percent of a mask (symmetry_audit.lua). So the symmetry is
-- enforced where the result leaves the generator: the master part of the final field is copied over the rest (the `symmetrize` field op, a soft seam across the borders of the parts).
--
--   A SETTING says which symmetry:  nil / 'map'   the symmetry of the editor (Symmetry panel, found from the start positions when the map is loaded): nothing when it is off
--                                   'off'         none
--                                   'rot2' ...    a symmetrize mode (mirror_x, mirror_z, mirror_xz, diag, adiag, diag_both, rot2, rot4) about the middle of the map
--                                   { mode = 'rotn', n = 6 }   an N-fold turn
--   Spec(setting)       -> { mode, n, cx, cz } (world units) or false when there is no symmetry
--   FromEditor()        the spec of the editor's symmetry (centre included) or false
--   Field(S, f, spec, o) -> f made symmetric (a field owned by S): o.seam (units, default 12) is the width of the soft border; spec false / nil returns f
--   Choices()           ids, labels for a menu (the setting strings); Label(setting) the text of a setting
--
-- Lua 5.0 dialect.

local Symmetry = import('/lua/editor/symmetry.lua')

Choices_ = {
    { id = 'map', label = 'Follow the map (Symmetry panel)' },
    { id = 'off', label = 'None' },
    { id = 'mirror_x', label = 'Mirror left / right' },
    { id = 'mirror_z', label = 'Mirror top / bottom' },
    { id = 'mirror_xz', label = 'Mirror both (4)' },
    { id = 'rot2', label = 'Turn by 180' },
    { id = 'rot4', label = 'Turn by 90 (4)' },
    { id = 'diag', label = 'Diagonal mirror' },
    { id = 'adiag', label = 'Anti-diagonal mirror' },
    { id = 'diag_both', label = 'Both diagonals (4)' },
    { id = 'rotn3', label = 'Turn by 120 (3)' },
    { id = 'rotn5', label = 'Turn by 72 (5)' },
    { id = 'rotn6', label = 'Turn by 60 (6)' },
}

--- The setting as one string (a { mode = 'rotn', n } table is 'rotn<n>').
function Key(setting)
    if setting == nil then return 'map' end
    if type(setting) == 'table' then
        if setting.mode == 'rotn' then return 'rotn' .. math.floor((setting.n or 3) + 0.5) end
        return setting.mode or 'off'
    end
    return setting
end

function Label(setting)
    local k = Key(setting)
    for _, c in Choices_ do
        if c.id == k then return c.label end
    end
    return k
end

function Choices()
    local ids, labels = {}, {}
    for _, c in Choices_ do
        table.insert(ids, c.id)
        table.insert(labels, c.label)
    end
    return ids, labels
end

local function Middle()
    local w, h = 256, 256
    if ed_terrain_info then w, h = ed_terrain_info() end
    return ((w or 256) - 1) / 2, (((h or w) or 256) - 1) / 2
end

function FromEditor()
    if Symmetry.Mode == 'off' then return false end
    local cx, cz = Symmetry.Centre()
    return { mode = Symmetry.Mode, n = 3, cx = cx, cz = cz }
end

function Spec(setting)
    local k = Key(setting)
    if k == 'off' then return false end
    if k == 'map' then return FromEditor() end
    local cx, cz = Middle()
    local n = 3
    local mode = k
    if string.sub(k, 1, 4) == 'rotn' then
        mode = 'rotn'
        n = tonumber(string.sub(k, 5)) or 3
    end
    return { mode = mode, n = n, cx = cx, cz = cz }
end

--- The images of a point under a spec (the point first), the heading change in `kind` / `angle` as symmetry.lua gives it.
function Points(spec, x, z)
    return Symmetry.PointsFor(spec.mode, spec.cx, spec.cz, x, z, spec.n)
end

function Field(S, f, spec, o)
    if not spec or not f then return f end
    o = o or {}
    return S:Op('symmetrize', { a = f, mode = spec.mode, side = 0, sector = 0, n = spec.n or 3, combine = 'copy', seam = o.seam or 12, cx = spec.cx, cz = spec.cz })
end
