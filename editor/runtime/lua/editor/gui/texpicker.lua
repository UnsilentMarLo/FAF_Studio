-- A texture browser for any texture of the game data: the categorized browser (browser.lua) with a folder tree, a kind filter (albedo / normal / mask ...), thumbnails, a preview and a search field. (The layer texture browser of
-- panels_strata.lua is limited to /env layers; this one takes the folders and patterns of the caller: sky atlases, cirrus, water ramps and wave maps, cube maps ...)
--
--   Open{ title, sources = { { '/textures/environment', '*.dds' }, ... }, match = function(path) -> bool (optional), none = 'text of a "no texture" entry' (optional),
--         thumbs = false (cube maps cannot be shown as a picture), current = path (selected first), done = function(path),
--         map = false (leave out the textures of the open map's folder, which are listed first under 'This map'), mapMatch = function(path, lowerPath, name) -> bool (which of them fit) }
--   Close()
--
-- A click on a row calls done(path) and closes; Esc or a click outside closes.
--
-- Lua 5.0 dialect.

local Browser = import('/lua/editor/gui/browser.lua')
local Dialog = import('/lua/editor/gui/dialog.lua')

NONE = Browser.NONE

function Close()
    Dialog.Close()
end

function Open(spec)
    Browser.OpenTextures(spec)
end
