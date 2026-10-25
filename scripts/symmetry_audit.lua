-- How symmetric is the result of a graph? Builds each graph of SYM = { { id, mode, n }, ... } and measures the difference between the map and the average of its images under the symmetry
-- (heights in units, paint masks 0..1): rms and the worst cell. Run in a test instance with a map open (square, e.g. 257): python scripts/editor_inst.py cmd <tag> scripts/symmetry_audit.lua
--
-- Lua 5.0 dialect.
local Graph = import('/lua/editor/graph.lua')
local GRun = import('/lua/editor/graphrun.lua')
local Fields = import('/lua/editor/fields.lua')
local S_ = rawget(_G, 'SYM') or {}
local out = { 'id\tmode\theight rms\theight max\tpaint rms (layers 1-8)\tpaint max' }

local function Diff(S, f, mode, n)
    local avg = S:Op('symmetrize', { a = f, mode = mode, n = n or 3, combine = 'avg', seam = 0 })
    local d = S:Op('sub', { a = f, b = avg })
    local sq = S:Op('mul', { a = d, b = d })
    local _, _, ms = Fields.Stats(sq)
    local lo, hi = Fields.Stats(d)
    return math.sqrt(ms), math.max(math.abs(lo), math.abs(hi))
end

for _, e in S_ do
    local ok, why = Graph.LoadPreset(e.id)
    if not ok then
        table.insert(out, e.id .. '\tLOAD FAILED ' .. tostring(why))
    else
        if e.set then for _, s in e.set do Graph.SetParam(s[1], s[2], s[3]) end end
        GRun.Refresh(true)
        local r, why2 = GRun.Build()
        if not r then
            table.insert(out, e.id .. '\tBUILD FAILED ' .. tostring(why2))
        else
            Fields.Run(function(S)
                local H = S:Height(1)
                local hr, hm = Diff(S, H, e.mode, e.n)
                local pr, pm, cnt = 0, 0, 0
                for layer = 1, 8 do
                    local ok2, m = pcall(function() return S:Stratum(layer) end)
                    if ok2 and m then
                        local f = S:Op('resample', { a = m, like = H })
                        local r1, m1 = Diff(S, f, e.mode, e.n)
                        pr = pr + r1 cnt = cnt + 1
                        if m1 > pm then pm = m1 end
                    end
                end
                table.insert(out, string.format('%s\t%s\t%.3f\t%.2f\t%.3f\t%.2f', e.id, e.mode, hr, hm, cnt > 0 and pr / cnt or 0, pm))
            end)
        end
    end
end
Graph.New('untitled')
return table.concat(out, '\n')
