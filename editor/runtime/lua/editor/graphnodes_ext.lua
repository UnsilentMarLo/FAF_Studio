-- Graph nodes for terrain made in other tools (Gaea, World Machine, Blender ...; interop.lua, docs/projects/editor/TERRAIN_INTEROP.md): the import of the Interop panel as part of a graph.
--
--   External terrain   the heightmap of the Interop panel (its file, mapping of the image to heights, alignment, orientation and filter) as a height field at the resolution of the graph. A file
--                      of the node's own overrides the panel's. The graph carries on from there: erosion, symmetry (the graph's), ground kinds, scatter.
--   External mask      an imported mask of the Masks page (target "named mask", e.g. flow / wear / deposit) as a 0..1 field; it feeds the wear / deposit / flow inputs of Ground kinds.
--
-- The nodes follow the files: the graph evaluates again when the other tool writes a new file (and has stopped writing) or the import settings change (interop.lua GraphSignature, graphrun.lua
-- Refresh). graphnodes.lua calls Install(Kit, Covers) once. Lua 5.0 dialect: no `%` (math.mod), no `#` (table.getn), no `...`.

function Install(Kit, Covers)
    local Def, N, B, T, In, Out = Kit.Def, Kit.N, Kit.B, Kit.T, Kit.In, Kit.Out
    local Fields = import('/lua/editor/fields.lua')
    local Interop = import('/lua/editor/interop.lua')

    local function Key()
        return Interop.GraphSignature(true)
    end

    Def('external_terrain', { label = 'External terrain (Gaea / World Machine)', cat = 'sources', kw = 'external terrain gaea world machine blender heightmap import interop file r16 tiff png live link',
        desc = 'The heightmap of the Interop panel as a height field: the file, the mapping of the image to heights ("Image 1 = height"), alignment, orientation and filter of its Heightmap page. A file typed here replaces the panel\'s. The graph evaluates again when the other tool writes the file. Region, blend and pads of the panel are not used: the graph does that (Pad flatten, masks, the graph\'s symmetry).',
        outputs = { Out('out', 'height') },
        liveKey = Key,
        params = { T('file', 'File (empty: the Interop panel\'s heightmap)', '') },
        eval = function(E, v, ins)
            local st = {}
            for k, x in Interop.Settings do st[k] = x end
            if v.file and v.file ~= '' then st.file = v.file end
            if st.file == '' then error('no heightmap: choose one on the Interop panel (Heightmap page) or type a file here') end
            local f, info = Interop.MappedImage(E, st, E.like)
            if not f then error(tostring(info)) end
            return { out = f }
        end })

    Def('external_mask', { label = 'External mask (Gaea / World Machine)', cat = 'sources', kw = 'external mask gaea world machine flow wear deposit erosion splat import interop named',
        desc = 'An imported mask of the Interop panel (Masks page, target "named mask": its name is the file name\'s guess, flow / wear / deposit for erosion masks) as a 0..1 field. Wire flow / wear / deposit into Ground kinds: the author\'s own erosion decides where the rock, the dirt and the wet ground go. Without such a mask the output is empty (Optional) or the node fails.',
        outputs = { Out('out', 'mask') },
        liveKey = Key,
        params = { T('name', 'Name of the named mask', 'wear'), B('optional', 'Empty when there is no such mask', true) },
        eval = function(E, v, ins)
            local f, why = Interop.NamedFieldByName(E, v.name, E.like)
            if not f then
                if v.optional then return { out = E:Op('const', { like = E.like, value = 0 }) } end
                error(tostring(why))
            end
            return { out = f }
        end })
end
