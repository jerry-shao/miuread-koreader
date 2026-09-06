# 5.8.0-beta.10 verification

Scope: Package Manager v3 / extension download transport refactor. The book download, sync, and OTA cores are intentionally kept unchanged from 5.8.0-beta.9.

Build/static checks completed in the build environment:

- Version identity: `_meta.lua` and `miuread/config.lua` are both `5.8.0-beta.10`; schema is 129 and the 128→129 migration is present.
- Package Manager v3 implementation assertions: **67/67 passed**. Coverage includes deterministic curated packages, community fallback behavior, KOReader HTTP fast path, curl recovery, persistent task ownership, task-local storage, non-destructive partial handling, route limits/speed history, network wait states, download-center integration, Kindle lifecycle hooks, verification, install rollback, and package metadata recording.
- Curated deterministic package assertions cover **Pinyin IME v1.2.0**, **fanqie v2.2.1**, **Z-Library v1.0.49**, and **墨痕壁纸 v3.5.7**, including exact Release URL/size/SHA-256 metadata.
- Dynamic route tests passed: automatic mode starts with direct when no history exists, uses at most three routes, respects a faster successful historical route, manual direct/mirror modes use exactly the selected route, and non-GitHub packages do not enter GitHub mirror routing.
- Dynamic verifier tests passed: a valid size/SHA ZIP is accepted; deliberate size mismatch is rejected as `size`; deliberate SHA mismatch is rejected as `sha256`.
- Lua syntax: **138/138** plugin Lua files pass `texluac -p`.
- Critical-core regression guard: `miuread/downloader.lua`, `download_task.lua`, `download_database.lua`, `download_plan.lua`, `download_result.lua`, `sync.lua`, and `updater.lua` are SHA-identical to 5.8.0-beta.9.
- Release/package preflight: **25/25 passed**. Required plugin files are present; every ZIP entry is under `miuread.koplugin/`; forbidden `.md`/`.epub`/`.log` and runtime-settings files are absent; AGPL identity, beta channel, manifest route, changelog section, manifest size/SHA, and summary bounds all pass.
- Deterministic build reproduction: rebuilding the full install package with the release workflow algorithm produced a byte-for-byte identical ZIP.
- Full install ZIP integrity: `ZipFile.testzip()` / `unzip -t` passed with no compressed-data errors.

Final install package:

- File: `miuread-v5.8.0-beta.10-full.zip`
- Size: **1,916,755 bytes**
- SHA-256: `f49a9880a29647d7591ea195fccc9a8eb456bac69858a68bf5f7fb378135c5b3`
- Channel: `beta`

Not statically provable and therefore still requires real-device validation on Kindle/Kobo/Android as applicable:

- Actual throughput versus 5.8.0-beta.4 on the same network.
- Pinyin IME 63,312,207-byte full transfer and final upstream SHA-256 on Kindle.
- 墨痕壁纸 9,983,676-byte deterministic Release transfer on the device that previously showed repeated download failures.
- Screen-off background transfer, forced REAL_SUSPEND fallback, wake/Wi-Fi reconnection, and resume without progress reset.
- No orphan curl/worker after a real KOReader restart/exit.
- E-ink progress refresh cadence, touch behavior, and perceived download-center responsiveness.

Static/build verification is complete; it does not substitute for the real-device tests above.
