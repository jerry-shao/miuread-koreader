# 5.8.0-beta.11 verification

Scope: built-in extension market download/install engine v4. The book downloader, sync, reading-progress, annotation and OTA cores are intentionally outside this refactor.

## Completed source/build checks

- Version identity: `miuread/config.lua` is `5.8.0-beta.11`; schema is **130** and the 129→130 migration is present.
- Legacy Package Manager v3 runtime modules removed: `extension_transfer.lua`, `extension_verifier.lua`, `extension_package.lua`, `extension_installer.lua`, and `extension_task.lua` are no longer shipped or required.
- New single-chain implementation is present: `extension_download.lua` → `extension_install.lua`, with `extension_job.lua` as the sole task lifecycle owner; `extension_center.lua` no longer contains a second archive verifier/installer.
- Static v4 invariant suite: **63/63 passed**. It checks deterministic source order, no route scoring/three-source truncation, manual source fail-closed behavior, source-local partials, size+SHA gating, HTTP→curl fallback, cache revalidation, Archiver-only installation, staging/journal/rollback, lifecycle/cancel/delete rules, schema migration and deterministic catalog rules.
- Dynamic catalog test passed: **18 deterministic catalog packages** have valid HTTPS URL, exact positive size, 64-hex SHA-256 and a fixed target `.koplugin` directory. Entries without a verified official install asset do not become installable through guessing.
- Dynamic downloader fault-model test passed: direct source with a **same-size wrong SHA** is rejected and mirror 1 succeeds; direct source with a **truncated size** is rejected and mirror 1 succeeds; large-file partials for direct/mirror routes remain physically separate and are never inherited across sources; invalid manually selected mirrors fail closed instead of silently falling back to GitHub.
- Dynamic installer test passed with a mocked KOReader Archiver: normal update installs the new plugin transactionally; an injected failure during `new → target` restores the previous plugin; a `../` archive entry is rejected before it can touch the installed plugin.
- Lua syntax: **136/136** shipped plugin Lua files pass `texluac -p` after the final edits.
- Regression scope guard: compared with 5.8.0-beta.10, **240 common files remain SHA-identical**. Plugin-code changes are restricted to version/schema wiring, catalog/center/store integration, removal of the five v3 extension modules and addition of the three v4 extension modules.
- The user-supplied `appstore.koplugin.zip` was independently checked: **273,795 bytes**, SHA-256 `dde0fcb3d8254a3c573ab8c46e7e5f35b688fb4f4177909211aeae7ed7d76449`, ZIP CRC clean, with `appstore.koplugin/main.lua` and `_meta.lua`; this exactly matches the deterministic catalog record.

## Official catalog metadata rechecked

The critical problem cases are pinned to exact GitHub Release assets:

- Fanqie v2.2.1 — 126,623 bytes — SHA-256 `21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b`.
- Z-Library v1.0.49 — 445,092 bytes — SHA-256 `455423604c7c5eab20fa00f9ac31c89514202892b34347c45fc34435e1252553`.
- InkStain v3.5.7 — 9,983,676 bytes — SHA-256 `87da12b78dd941f424c617fc10fdb620ca239b60fc9b61b39089f4c4717e0bee`.
- Pinyin IME v1.2.0 — 63,312,207 bytes — SHA-256 `14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb`.

## Release package verification

- Full install ZIP: `miuread-v5.8.0-beta.11-full.zip`
- Size: **1,914,158 bytes**
- SHA-256: `8d14d3326f67190e5cef77c36d2b0ac180ae89ead8da4b0360ecf9299530e2be`
- ZIP integrity: Python `ZipFile.testzip()` and `unzip -t` both passed.
- Package structure: all **258 entries** stay under `miuread.koplugin/`; required main/meta/config and the three v4 engine modules are present; the five v3 engine files and forbidden `.md/.epub/.log` runtime files are absent.
- Manifest size/SHA and beta identity match the built ZIP.
- Deterministic rebuild using the release workflow algorithm produced a **byte-for-byte identical** ZIP.

## Still requires real-device validation

Static/fault-model verification cannot emulate Kindle/Kobo firmware networking, suspend hooks or KOReader's actual bundled Archiver/curl binaries. Before promoting this beta to a stable release, the following should still be run on real devices:

- Kindle: Fanqie, Z-Library, InkStain and Pinyin IME install; Pinyin large-file pause/resume; screen-off/background download; restart while partially downloaded; update rollback smoke test.
- Kobo: the same small-package install path plus wake/Wi-Fi-not-ready → WAIT_NETWORK → successful continuation, especially on the device class affected by issue #92.
- Confirm the device has a usable large-file SHA backend (`sha256sum`, BusyBox `sha256sum`, or OpenSSL) for Pinyin IME. Small packages have an in-process SHA fallback; the 63 MB package intentionally avoids whole-file Lua memory loading.

The source/build/fault-model gates above are complete. They deliberately do not claim to replace the final hardware matrix.
