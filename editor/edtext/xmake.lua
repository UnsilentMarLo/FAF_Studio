-- edtext.dll: DirectWrite text backend for the editor engine. Build from this folder:
--   xmake f -P . -y -c -p windows -a x64 --toolchain=msvc -m release && xmake -P . -y
-- Output: build/windows/x64/release/edtext.dll (copy next to the engine exe; see docs/projects/editor_research/P1_TEXT_BACKEND.md).
set_languages("cxx17")
add_rules("mode.release")
set_runtimes("MT")

target("edtext")
    set_kind("shared")
    add_files("edtext.cpp")
    add_headerfiles("edtext.h", "edraster.h")
    add_syslinks("dwrite", "user32")
    add_defines("NOMINMAX", "_CRT_SECURE_NO_WARNINGS")
    add_cxflags("/utf-8", {force = true})
