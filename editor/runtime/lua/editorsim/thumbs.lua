-- Editor sim callbacks of the asset browser's thumbnails (assetthumbs.lua): a prop stands in the lab spot while the offscreen renderer takes its picture.
--
--   EdThumbProp   creates the prop blueprint `bp` at (x, y, z); remembers it
--   EdThumbClear  destroys what EdThumbProp made (only that: nothing else on the map is touched)
function Register(Callbacks)
    local made = false

    Callbacks.EdThumbClear = function(data)
        if made then
            pcall(function() if not made:BeenDestroyed() then made:Destroy() end end)
            made = false
        end
    end

    Callbacks.EdThumbProp = function(data)
        Callbacks.EdThumbClear({})
        local ok, prop = pcall(function() return CreateProp(Vector(data.x, data.y, data.z), data.bp) end)
        if ok and prop then
            made = prop
            ed_write_file(data.path, 'ok\n')
        else
            ed_write_file(data.path, 'error ' .. tostring(prop) .. '\n')
        end
    end
end
