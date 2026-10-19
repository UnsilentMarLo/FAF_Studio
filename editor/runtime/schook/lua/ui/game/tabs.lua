-- The game's top menu (Main Menu, Restart, Exit, Save ... in lua/ui/game/tabs.lua) is not part of a test run in the editor: the editor owns leaving the run
-- (the Stop button), restarting and quitting. In an editor session (/editor) the bar is created hidden and nothing shows it again.
-- Base module: Create(parent), ToggleTabDisplay(state), ToggleTab(tabID), Expand(), Contract(), InitialAnimation() (module functions; `controls` is the module's control table).
do
    local baseCreate = Create
    function Create(parent)
        baseCreate(parent)
        if HasCommandLineArg('/editor') then
            if controls.parent then controls.parent:Hide() end
            if controls.collapseArrow then controls.collapseArrow:Hide() end
        end
    end

    local baseToggleTabDisplay = ToggleTabDisplay
    function ToggleTabDisplay(state)
        if HasCommandLineArg('/editor') then return end
        return baseToggleTabDisplay(state)
    end

    local baseToggleTab = ToggleTab
    function ToggleTab(tabID)
        if HasCommandLineArg('/editor') then return end
        return baseToggleTab(tabID)
    end

    local baseExpand = Expand
    function Expand()
        if HasCommandLineArg('/editor') then return end
        return baseExpand()
    end

    local baseInitialAnimation = InitialAnimation
    function InitialAnimation()
        if HasCommandLineArg('/editor') then return end
        return baseInitialAnimation()
    end
end
