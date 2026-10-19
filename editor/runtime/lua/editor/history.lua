-- One undo / redo order for terrain strokes (their own stack in terrain.lua) and object edits (markers, areas): a list of entries,
-- `pos` of them applied. A terrain entry only says "the next terrain undo belongs here"; an object entry carries its own undo / redo.
--
-- Temporary: when objects move onto the native MapDocument command stack (milestone M2) this module goes away and ui.lua's
-- DoUndo / DoRedo call the native stack only.

local Terrain = import('/lua/editor/terrain.lua')

local stack = {}
local pos = 0
local LIMIT = 200

--- An entry that leaves the history (redo branch cut off, oldest dropped, cleared) frees what it holds: native copies of masks and terrain types (entry.release).
local function Drop(entry)
    if entry and entry.release then pcall(entry.release) end
end

--- Bumped by every push, undo and redo: whoever wants to know whether the document changed (autosave) compares it.
Version = 0

--- Records a finished terrain stroke.
function PushTerrain()
    Push({ kind = 'terrain', label = 'terrain stroke' })
end

--- Records an object edit: `entry.undo()` and `entry.redo()` revert / reapply it.
function Push(entry)
    -- table.remove, not `stack[i] = nil`: table.getn does not shrink after an assignment of nil, so a push after an undo left a hole in the stack and the next undos stopped there
    for i = table.getn(stack), pos + 1, -1 do
        Drop(table.remove(stack, i))
    end
    table.insert(stack, entry)
    if table.getn(stack) > LIMIT then
        Drop(table.remove(stack, 1))
    end
    pos = table.getn(stack)
    Version = Version + 1
end

local function Apply(entry, undo)
    if entry.kind == 'terrain' then
        if undo then return Terrain.Undo() else return Terrain.Redo() end
    end
    local fn = undo and entry.undo or entry.redo
    if fn then fn() end
    return true
end

--- Undoes the latest entry; returns its label, or false when there is nothing to undo.
local function PreviewUsed()
    if PreUndo and PreUndo() then return true end
    for _, fn in PreUndoHooks do
        if fn() then return true end
    end
    return false
end

function Undo()
    if PreviewUsed() then return 'preview' end
    local entry = stack[pos]
    if not entry then
        return false
    end
    pos = pos - 1
    Apply(entry, true)
    Version = Version + 1
    return entry.label or 'edit'
end

function Redo()
    if PreviewUsed() then return 'preview' end
    local entry = stack[pos + 1]
    if not entry then
        return false
    end
    pos = pos + 1
    Apply(entry, false)
    Version = Version + 1
    return entry.label or 'edit'
end

--- Folds the `count` latest entries into one: a symmetric placement is one undo step. A terrain entry (a stroke: the next terrain undo belongs here) may be one of the parts: the parts
--- are undone newest first and redone oldest first, which is the order of the terrain's own stack. (Entries with a terrain part used to be refused: "Apply skeleton" said "one undo entry"
--- and took two Ctrl+Z.)
function Merge(count, label)
    local n = table.getn(stack)
    if count < 2 or pos ~= n or n < count then return end
    local parts = {}
    for i = n - count + 1, n do table.insert(parts, stack[i]) end
    for i = 1, count do table.remove(stack) end
    table.insert(stack, {
        label = label or parts[1].label,
        undo = function() for i = table.getn(parts), 1, -1 do Apply(parts[i], true) end end,
        redo = function() for i = 1, table.getn(parts) do Apply(parts[i], false) end end,
        release = function() for _, part in parts do Drop(part) end end,
    })
    pos = table.getn(stack)
end

--- The latest applied entry (nil when there is none): lets a caller fold a drag of one slider into a single entry.
function Top()
    return stack[pos]
end

--- Forgets the entries that were undone (what a new edit does): code that edits the document without an entry of its own calls this first.
function DropRedo()
    for i = table.getn(stack), pos + 1, -1 do
        local entry = table.remove(stack, i)
        if entry and entry.release then pcall(entry.release) end
    end
end

--- The entry a redo would apply (nil when there is none): for menu labels.
function RedoTop()
    return stack[pos + 1]
end

--- Entries that can be undone, entries that can be redone.
function Depth()
    return pos, table.getn(stack) - pos
end

function Clear()
    for _, entry in stack do Drop(entry) end
    stack = {}
    pos = 0
end

-- Hooks of code that edits the document without an entry of its own (the live preview of paths.lua): Before(entry) runs before an entry joins the stack (Push), PreUndo() before an
-- undo or redo and returns true when it used the request up. Both are set by that code; nothing here depends on it. PushQuiet is Push without the hook.
Before = false
PreUndo = false
PushQuiet = Push

-- More than one module can have a live preview: AddBefore(fn) / AddPreUndo(fn) register further hooks beside the single `Before` / `PreUndo` slots (paths.lua sets those). A PreUndo hook
-- that returns true has used the request up.
BeforeHooks = {}
PreUndoHooks = {}
function AddBefore(fn) table.insert(BeforeHooks, fn) end
function AddPreUndo(fn) table.insert(PreUndoHooks, fn) end

local pushWithHook = Push
Push = function(entry)
    if Before then Before(entry) end
    for _, fn in BeforeHooks do fn(entry) end
    pushWithHook(entry)
end

-- ---- the list of entries (History panel) ---------------------------------------------------------------------------------------------------------------

--- The entries as { label } in order (oldest first) and the number of applied ones (`pos`): entry i is applied when i <= pos.
function Entries()
    local list = {}
    for i, e in stack do list[i] = { label = e.label or 'edit', kind = e.kind } end
    return list, pos
end

--- Undoes or redoes until `target` entries are applied (0 = the state before the first one). Returns the number of steps taken.
function JumpTo(target)
    local n = table.getn(stack)
    if target < 0 then target = 0 end
    if target > n then target = n end
    local steps = 0
    while pos > target do
        if not Undo() then break end
        steps = steps + 1
    end
    while pos < target do
        if not Redo() then break end
        steps = steps + 1
    end
    return steps
end
