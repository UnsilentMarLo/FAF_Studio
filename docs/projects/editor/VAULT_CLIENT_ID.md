# Vault sign-in: which OAuth client the editor presents as

Decision (user, 2026-11-11): **keep it the same as upstream's editor.** The vault client (`ed_vault_*`, WP4, `docs/projects/editor/EDITOR_PORT_ANALYSIS.md`) signs in with the device-code flow against FAF's identity service using the same public client id that upstream's editor uses (`kFafClientId` in upstream `src/editor/EdFafApi.h`, chosen by upstream on 2026-11-10 and described there as the FAF client's own id). We do not register a client id of our own for now, and we do not change the constant.

What this means, so nobody is surprised later:

- The id is a **public device-flow client**: no secret exists anywhere in our code, our logs or our files. The sign-in token is stored per user in a DPAPI-protected file in the user folder and never logged.
- To FAF's server the editor therefore looks like the FAF client / upstream's editor. That is the behaviour upstream ships; ours stays identical on purpose so there is one thing to explain to FAF, not two.
- We did **not** check the id against FAF's own client registry; that is upstream's claim. If FAF ever objects, or upstream changes the id, the change is one constant in `EdUpVaultLua.cpp` / the library header (and a line here).
- Anything FAF should be told (an editor that downloads maps with this id) is for whoever talks to FAF about upstream's editor; this note is the record that ours does the same.

Not decided and not needed yet: a client id of our own for FAF Studio as a separate product. If FAF Studio is ever released outside this repository, ask FAF for one then.

## Related decision recorded here

WP3 (exact save): retail map X1MP_007 saves 34 bytes different from its file because the editor gives a layer with an albedo but an empty normal path the neutral `none_normal.dds` on load (`strata.Normalize`). **Decision (user, 2026-11-11): keep that fix.** The other 60 of 61 retail maps in this install save byte-identical.
