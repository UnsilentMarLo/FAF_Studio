-- The editor's version. A development tree says "dev"; scripts/package_editor.py writes the real number, the build date and the git revision into the packaged copy of this file.
-- Lua 5.0 dialect.

Name = 'FAF Studio'
Version = 'dev'
Build = ''          -- date of the package, e.g. '2026-10-19'
Revision = ''       -- git revision the package was made from

-- A development run has no package: `studio.py engine build / stage` writes buildinfo.lua (git-ignored) with the number, the date and the revision of the last build, and that is shown.
do
    local ok, info = pcall(import, '/lua/editor/buildinfo.lua')
    if ok and info and info.Version and Version == 'dev' then
        Version, Build, Revision = info.Version, info.Build or '', (info.Revision or '') .. ' dev'
    end
end

--- 'FAF Studio 0.9.0 (2026-10-19, a1b2c3d)' / 'FAF Studio (development)'
function Text()
    if Version == 'dev' then return Name .. ' (development)' end
    local extra = {}
    if Build ~= '' then table.insert(extra, Build) end
    if Revision ~= '' then table.insert(extra, Revision) end
    return Name .. ' ' .. Version .. ((table.getn(extra) > 0) and (' (' .. table.concat(extra, ', ') .. ')') or '')
end
