-- Protected loading of the editor's own data files (the map sidecar `<stem>_editor.lua`, a mod project's `edits.lua`, graph presets ...): files that are Lua source with
-- plain data in them, written by luaser.lua and read back with doscript / loadstring. A bare doscript lets one syntax error, one runtime error or one wrong-typed value
-- take down whatever opened the file (before this module a broken sidecar stopped the whole map open: StartCommandLineSession calls it unprotected).
--
--   File(path, opts)  -> env, info | nil, why      path = VFS path ('/maps/x/x_editor.lua') or a disk path ('../modproj/P/edits.lua')
--   Text(text, opts)  -> env, info | nil, why      the same for a text already in hand (a corrupt file, a test)
--   Problems()        the last problems found (text lines, newest last) for the status line / Console;   ClearProblems()
--
-- What it does, in order:
--   1. reads the text (a file inside an archive is run with doscript under pcall instead: no size or salvage there), refuses a non-string or one over opts.maxBytes (8 MB);
--   2. runs it in an empty environment (no globals: a data file cannot call anything; opts.globals = { name = value } adds some);
--   3. a syntax or runtime error: the file is cut into its top-level sections (`Name = ...` at column 0) and each section runs on its own, so one broken section loses only
--      itself (opts.salvage = false: all or nothing);
--   4. opts.schema = { Name = 'table' | 'number' | 'string' | 'boolean' | function(value) -> bool }: a value of the wrong type is dropped, not trusted;
--   5. the schema version: `version` in the file (missing = 0, a file from before versions). Older than opts.current: opts.migrate[v](env) runs for v, v+1 ... (nothing
--      registered for a step = nothing to change); newer: loaded as it is, info.future = true and a warning (an older editor opens a newer file as far as it understands it);
--   6. when anything was wrong and the file is on disk, the original text is kept as `<file>.bad` next to it before anything can overwrite it.
-- Returns nil, why only when nothing could be read at all; info = { version =, migrated =, future =, dropped = { names }, bad = <path of the backup> or nil, from = 'disk' | 'archive' | 'text' }.
--
-- opts = { name = 'sidecar' (for messages), maxBytes =, current = 1, migrate = {}, schema = {}, salvage = true, globals = {}, keepBad = true }
--
-- Lua 5.0 dialect: no `#`, no `%`, no string.match.

MAX_BYTES = 8 * 1024 * 1024

local problems = {}

local function Say(text)
    local warn = rawget(_G, 'WARN') or rawget(_G, 'LOG')
    if warn then warn('EDITOR safeload: ' .. text) end
    table.insert(problems, text)
    if table.getn(problems) > 40 then table.remove(problems, 1) end
end

function Problems() return problems end
function ClearProblems() problems = {} end

local function NewEnv(opts)
    local env = {}
    for k, v in opts.globals or {} do env[k] = v end
    return env
end

--- Runs `text` in `env`. -> true | false, why
local function Run(text, chunkname, env)
    local f, err = loadstring(text, chunkname)
    if not f then return false, err end
    setfenv(f, env)
    local ok, why = pcall(f)
    if not ok then return false, why end
    return true
end

--- The top-level sections of a data file: list of { name =, text = }; text before the first section is dropped (comments).
local function Sections(text)
    local list, cur = {}, nil
    for line in string.gfind(text .. '\n', '([^\n]*)\n') do
        local s, e, name = string.find(line, '^([%a_][%w_]*)%s*=')
        if s and string.sub(line, e + 1, e + 1) ~= '=' then
            cur = { name = name, text = line }
            table.insert(list, cur)
        elseif cur then
            cur.text = cur.text .. '\n' .. line
        end
    end
    return list
end

local function CheckType(v, rule)
    if type(rule) == 'function' then
        local ok, good = pcall(rule, v)
        return ok and good and true or false
    end
    return type(v) == rule
end

local function Load(text, opts, info)
    local env = NewEnv(opts)
    local ok, why = Run(text, opts.name or 'data', env)
    if ok then return env end
    Say((opts.name or 'data') .. ' could not be read as a whole (' .. tostring(why) .. ')' .. (opts.salvage == false and '' or ': reading its sections one by one'))
    info.bad = true
    if opts.salvage == false then return nil, why end
    env = NewEnv(opts)
    info.dropped = info.dropped or {}
    local kept = 0
    for _, section in Sections(text) do
        local part = NewEnv(opts)
        local good, err = Run(section.text, section.name, part)
        if good then
            for k, v in part do
                if opts.globals == nil or opts.globals[k] == nil then env[k] = v end
            end
            kept = kept + 1
        else
            table.insert(info.dropped, section.name)
            Say((opts.name or 'data') .. ': section ' .. section.name .. ' dropped (' .. tostring(err) .. ')')
        end
    end
    if kept == 0 and string.find(text, '%S') then
        return nil, why
    end
    return env
end

function Text(text, opts)
    opts = opts or {}
    local info = { dropped = {}, from = 'text', migrated = {} }
    if type(text) ~= 'string' then return nil, 'not a text' end
    if string.len(text) > (opts.maxBytes or MAX_BYTES) then
        Say((opts.name or 'data') .. ' is ' .. string.len(text) .. ' bytes, over the limit of ' .. (opts.maxBytes or MAX_BYTES) .. ': not read')
        return nil, 'too large'
    end
    local env, why = Load(text, opts, info)
    if not env then return nil, why, info end
    for name, rule in opts.schema or {} do
        local v = env[name]
        if v ~= nil and not CheckType(v, rule) then
            Say((opts.name or 'data') .. ': ' .. name .. ' has the wrong type (' .. type(v) .. '), dropped')
            env[name] = nil
            table.insert(info.dropped, name)
            info.bad = true
        end
    end
    local current = opts.current
    local v = env.version
    if v ~= nil and type(v) ~= 'number' then
        Say((opts.name or 'data') .. ': version is not a number, read as a file without version')
        v = nil
        info.bad = true
    end
    info.version = v or 0
    if current then
        if info.version > current then
            info.future = true
            Say((opts.name or 'data') .. ' was written by a newer editor (version ' .. info.version .. ', this one reads ' .. current .. '): loaded as far as it is understood')
        else
            while info.version < current do
                local fn = opts.migrate and opts.migrate[info.version]
                if fn then
                    local ok, err = pcall(fn, env)
                    if not ok then
                        Say((opts.name or 'data') .. ': migration from version ' .. info.version .. ' failed (' .. tostring(err) .. ')')
                        info.bad = true
                        return nil, 'migration failed: ' .. tostring(err), info
                    end
                    table.insert(info.migrated, info.version)
                end
                info.version = info.version + 1
            end
            env.version = current
        end
    end
    return env, info
end

--- The disk path behind a path: a VFS path ('/...') is looked up in the VFS, anything else is a disk path already.
local function DiskPath(path)
    if string.sub(path, 1, 1) ~= '/' then return path end
    local toDisk = rawget(_G, 'ed_vfs_to_disk')
    return toDisk and toDisk(path) or nil
end

function File(path, opts)
    opts = opts or {}
    opts.name = opts.name or path
    if type(path) ~= 'string' or path == '' then return nil, 'no path' end
    local disk = DiskPath(path)
    local text = disk and rawget(_G, 'ed_read_file') and ed_read_file(disk)
    if text then
        local env, why, info = Text(text, opts)
        if env then info = why end                      -- (a success returns env, info; a failure nil, why, info)
        if info then
            info.from = 'disk'
            if info.bad and opts.keepBad ~= false then
                local bad = disk .. '.bad'
                if ed_write_file(bad, text) then
                    info.bad = bad
                    Say(opts.name .. ': the original is kept as ' .. bad)
                end
            end
        end
        if env then return env, info end
        return nil, why, info
    end
    -- inside an archive (or not on disk at all): the engine's own reader, protected
    local info = { dropped = {}, from = 'archive', migrated = {} }
    local env = NewEnv(opts)
    local ok, why = pcall(doscript, path, env)
    if not ok then
        Say(opts.name .. ' could not be read (' .. tostring(why) .. ')')
        return nil, tostring(why), info
    end
    info.version = type(env.version) == 'number' and env.version or 0
    if opts.current and info.version > opts.current then
        info.future = true
        Say(opts.name .. ' was written by a newer editor (version ' .. info.version .. '): loaded as far as it is understood')
    end
    return env, info
end
