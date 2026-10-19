-- P0 text lab (offline). Build and run from this folder: xmake f -m release && xmake build textlab && xmake run textlab
-- Output (PNG sheets, results.txt) goes to the run directory; keep it out of git (see .gitignore here).
set_languages("cxx17")
add_rules("mode.release")
set_runtimes("MT")

target("textlab")
    set_kind("binary")
    add_files("textlab.cpp")
    add_syslinks("dwrite", "gdi32", "user32")
    add_defines("NOMINMAX", "_CRT_SECURE_NO_WARNINGS")
    add_cxflags("/utf-8", {force = true})
    set_rundir("$(projectdir)/out")
