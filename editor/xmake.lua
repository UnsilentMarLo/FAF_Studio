-- SC Editor suite: engine-independent core (formats, textures, meshes) and its tools. Docs: docs/projects/MAP_EDITOR.md
set_languages("cxx17")
add_rules("mode.release", "mode.debug")
set_warnings("all")
set_runtimes("MT")

target("edcore")
    set_kind("static")
    add_includedirs("core/include", {public = true})
    add_files("core/src/*.cpp")
    add_defines("NOMINMAX", "_CRT_SECURE_NO_WARNINGS", {public = true})

target("edtool")
    set_kind("binary")
    add_deps("edcore")
    add_files("tools/edtool.cpp")
