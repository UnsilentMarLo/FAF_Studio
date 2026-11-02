name = "Editor example: crater tool"
version = 1
author = "FAF Studio"
copyright = "FAF Studio"
description = "Example editor mod. Adds a Crater tool to the editor tool panel by hooking /lua/editor/ui.lua."
uid = "ED170000-5C0A-4D57-9E1F-000000000001"
-- The editor extension API this mod was written for (lua/editor/api.lua ApiVersion). The editor does not load a mod that needs a newer one.
editor_api = 1
exclusive = false
ui_only = true
-- Marks this as an editor mod: always loaded, not listed in the editor's mod browser, and allowed to hook the
-- editor's own Lua files (hook/lua/editor/*.lua).
editor_mod = true
