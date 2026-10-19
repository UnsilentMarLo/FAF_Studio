-- A software preview icon of a unit mesh (no game session needed): the mesh seen from the front left above (the direction of the engine recipe, icongen.lua), flat shaded with a faction tint,
-- fitted to the 64 x 64 picture and reduced with a 4 x 4 box filter. The new unit wizard writes it when the project has no icon for the unit yet, so that the build menu shows something and the
-- validators find a file; the Icons panel replaces it with the engine render (same path, `icongen.lua`) once the unit is in the running game.
--
--   Render(mesh [, opts]) -> { px, w, h }      px = flat r, g, b, a ... (0..255, not premultiplied, empty pixels white and transparent), like icongen.lua
--   opts: size (64), eye ({x, y, z} direction to the camera), tint ({r, g, b}), fill (0.88)
--
-- Lua 5.0 dialect.

local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

local function Norm(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-12 then return 0, 0, 0 end
    return x / l, y / l, z / l
end

function Render(mesh, opts)
    opts = opts or {}
    local size = opts.size or 64
    local ss = 4
    local S = size * ss
    local eye = opts.eye or { -0.5, 0.55, 0.67 }
    local tint = opts.tint or { 170, 178, 190 }
    local fill = opts.fill or 0.88
    -- view basis (left handed world like the game's): f looks at the unit, right = up x f, up2 = f x right
    local fx, fy, fz = Norm(-eye[1], -eye[2], -eye[3])
    local rx, ry, rz = Norm(1 * fz - 0 * fy, 0 * fx - 0 * fz, 0 * fy - 1 * fx)          -- cross(up = (0,1,0), f)
    local ux, uy, uz = fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx
    local pos, idx = mesh.pos, mesh.idx
    local n = mesh.n
    -- project every vertex: screen x, y (unit scale) and depth
    local sx, sy, sd = {}, {}, {}
    local x0, y0, x1, y1 = 1e30, 1e30, -1e30, -1e30
    for i = 0, n - 1 do
        local px, py, pz = pos[i * 3 + 1], pos[i * 3 + 2], pos[i * 3 + 3]
        local x = px * rx + py * ry + pz * rz
        local y = px * ux + py * uy + pz * uz
        sx[i + 1], sy[i + 1], sd[i + 1] = x, y, px * fx + py * fy + pz * fz
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    local w, h = x1 - x0, y1 - y0
    if w < 1e-9 or h < 1e-9 then return nil, 'the mesh has no area' end
    local scale = fill * S / max(w, h)
    local ox = S / 2 - (x0 + x1) / 2 * scale
    local oy = S / 2 + (y0 + y1) / 2 * scale                    -- screen y grows downwards
    local zbuf, col = {}, {}
    local lx, ly, lz = Norm(-0.4, 0.8, 0.45)                    -- light, from above and the front left
    local nt = table.getn(idx) / 3
    for t = 0, nt - 1 do
        local a, b, c = idx[t * 3 + 1], idx[t * 3 + 2], idx[t * 3 + 3]
        local ax, ay, az = sx[a] * scale + ox, -sy[a] * scale + oy, sd[a]
        local bx, by, bz = sx[b] * scale + ox, -sy[b] * scale + oy, sd[b]
        local cx, cy, cz = sx[c] * scale + ox, -sy[c] * scale + oy, sd[c]
        local area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if area ~= 0 then
            -- face normal in the world, for the shading
            local pa, pb, pc = (a - 1) * 3, (b - 1) * 3, (c - 1) * 3
            local e1x, e1y, e1z = pos[pb + 1] - pos[pa + 1], pos[pb + 2] - pos[pa + 2], pos[pb + 3] - pos[pa + 3]
            local e2x, e2y, e2z = pos[pc + 1] - pos[pa + 1], pos[pc + 2] - pos[pa + 2], pos[pc + 3] - pos[pa + 3]
            local nx, ny, nz = Norm(e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x)
            local facing = nx * eye[1] + ny * eye[2] + nz * eye[3]
            if facing < 0 then nx, ny, nz = -nx, -ny, -nz end           -- shade the side that faces the camera, whatever the winding
            local lambert = max(0, nx * lx + ny * ly + nz * lz)
            local shade = 0.35 + 0.65 * lambert
            local minx, maxx = max(0, floor(min(ax, bx, cx))), min(S - 1, floor(max(ax, bx, cx)))
            local miny, maxy = max(0, floor(min(ay, by, cy))), min(S - 1, floor(max(ay, by, cy)))
            local inv = 1 / area
            for py = miny, maxy do
                local yy = py + 0.5
                for px = minx, maxx do
                    local xx = px + 0.5
                    local w0 = ((bx - xx) * (cy - yy) - (cx - xx) * (by - yy)) * inv
                    local w1 = ((cx - xx) * (ay - yy) - (ax - xx) * (cy - yy)) * inv
                    local w2 = 1 - w0 - w1
                    if w0 >= 0 and w1 >= 0 and w2 >= 0 then
                        local d = w0 * az + w1 * bz + w2 * cz
                        local k = py * S + px + 1
                        if not zbuf[k] or d < zbuf[k] then
                            zbuf[k] = d
                            col[k] = shade
                        end
                    end
                end
            end
        end
    end
    -- reduce
    local out = {}
    local cnt = ss * ss
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local covered, sum = 0, 0
            for dy = 0, ss - 1 do
                for dx = 0, ss - 1 do
                    local k = (y * ss + dy) * S + (x * ss + dx) + 1
                    if col[k] then
                        covered = covered + 1
                        sum = sum + col[k]
                    end
                end
            end
            local i = (y * size + x) * 4
            if covered > 0 then
                local s = sum / covered
                out[i + 1], out[i + 2], out[i + 3] = floor(min(255, tint[1] * s * 1.25)), floor(min(255, tint[2] * s * 1.25)), floor(min(255, tint[3] * s * 1.25))
                out[i + 4] = floor(covered / cnt * 255 + 0.5)
            else
                out[i + 1], out[i + 2], out[i + 3], out[i + 4] = 255, 255, 255, 0
            end
        end
    end
    return { px = out, w = size, h = size }
end
