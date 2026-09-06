# 5.8.0-beta.12 verification

Scope: crash-backed fixes for issues #86, #91 and #92. The beta.11 Extension Engine v4 is kept unchanged apart from version/schema integration.

## #91 — KPW6 extreme lag / settings growth

The supplied #91 log repeatedly records `settings flush failed` with a generated `miuread.lua` around line 100,146–100,229 and `chunk has too many syntax levels`. It also records a fresh book download started with about 95 MiB available memory immediately before KOReader was killed.

Implemented safeguards:

- Schema **131** compacts historical session/report context storage. A complete chapter catalog has one durable owner (`library[bookId].catalog`) instead of being duplicated in every session/report context.
- Migration preserves exact pending progress and user/account state. If an old session contains the only complete catalog, it is promoted to the library record before the duplicate session copy is removed.
- Future `save_session` calls apply the same bounded persistent shape, so the old chapter arrays cannot simply grow back after migration.
- Every normal settings flush compacts merged session state before serialization. If serialization specifically fails with `too many syntax levels`, an emergency compaction removes regenerable duplicate/cache objects and retries one atomic write; the previous settings file is retained if the retry still fails.
- The downloader no longer stores the same full chapter map in both the library and session records.
- Fresh heavy book downloads run GC and a memory preflight before worker state/fork. Below **96 MiB** the task is deferred with a user-visible message and existing checkpoints are kept, instead of starting a worker in the same low-memory state seen immediately before the supplied crash.

Dynamic state-repair test (`tools/test_store_repair.lua`) passed. It creates a schema-130 store containing a 320-chapter duplicated catalog and deeply nested historical junk, migrates to schema 131, verifies the canonical catalog and exact pending progress survive, verifies duplicate contexts are removed, and confirms a subsequent session save cannot regrow them.

## #92 — Kobo Wi-Fi after suspend/resume

The supplied #92 log shows an underlying Kobo/KOReader network inconsistency (`dhcpcd not running`) and later remains `radio=true`, `connected=false`, `online=false` through the 52-second observation point. MiuRead must not claim to repair the firmware daemon itself.

Implemented MiuRead-side recovery:

- The pre-suspend Wi-Fi **intent** is remembered before KOReader tears networking down for Kobo suspend.
- On resume, when Wi-Fi was intended to remain available, MiuRead now calls KOReader's own `NetworkMgr.restoreWifiAsync()` and `scheduleConnectivityCheck()` path instead of merely observing `isWifiOn()`.
- If KOReader already has a connection attempt in progress, MiuRead reuses it instead of creating a competing recovery.
- Recovery is bounded and observes `.8 / 3 / 6 / 12 / 24 / 40 / 48 s`, covering KOReader's documented asynchronous restore window. Success releases the recovering state; failure stops automatic waiting and exposes a manual reconnect message.
- MiuRead's recovery code contains no direct network-daemon shell manipulation (`dhcpcd`, `wpa_supplicant`, `ifconfig`, etc.). The device-specific work stays owned by KOReader.
- While networking is recovering/down, automatic remote Home jobs (shelf, remote metadata, remote covers and WeRead stats) are gated so they cannot each spend tens of seconds failing on an interface that is not connected. Local/cache UI remains available.

This fixes MiuRead's recovery/control-flow gap. Real Kobo hardware is still required to determine whether KOReader's own device backend can recover a particular firmware/launcher state; beta.12 deliberately does not bypass KOReader and take ownership of Kobo networking.

## #86 — Home / Wi-Fi / shelf latency

The supplied #86 log contains old 5.6 paths where a Home section switch takes about 5 seconds even though the resulting layer itself is cheap, plus network-unreachable periods. The major Home cache/foreground-priority/QuickPanel changes were already introduced in beta.6/beta.7 and remain in beta.12.

This release adds the missing recovery gate relevant to #86: automatic remote work does not start while Wi-Fi is still recovering or recently down. It does not attempt to modify third-party plugins' own HTTP loops (for example, Z-Library network errors seen in the log are emitted by that plugin, not by MiuRead).

A real-device #86 regression test remains necessary because the residual cost of KOReader layout/e-ink rendering cannot be reproduced by source-level tests.

## Automated verification

- Static/invariant suite: **74/74 passed** (`python tools/verify_beta12.py`).
- Shipped Lua syntax: **136/136 passed** as part of the suite.
- Extension catalog regression: PASS — 18 deterministic packages.
- Extension download fault model: PASS.
- Extension installer transaction/rollback/path-safety model: PASS.
- Store schema-131/session-compaction dynamic test: PASS.
- Static network guard confirms the resume path uses KOReader-owned restore/connectivity APIs and does not directly execute network-daemon commands.

## Hardware validation required before stable promotion

1. **KPW6 / #91:** upgrade the affected long-lived install without deleting settings; verify the migration completes, normal settings writes resume, Home/QuickPanel/shelf switching no longer accumulates tens-of-seconds delays, and a low-memory fresh download is deferred rather than killing KOReader.
2. **Kobo Glo HD / #92:** Wi-Fi initially connected → Home → suspend → wake. Verify the panel enters recovering, KOReader restoration reconnects without returning to Nickel, and automatic shelf/stats workers remain parked until connectivity is actually restored. Also test the bounded failure message when the underlying KOReader backend cannot restore.
3. **KPW6 / #86:** repeat source/page switching and QuickPanel interaction on the original device. Cached/local navigation must remain usable while networking is unavailable.

These source/fault-model gates verify the MiuRead changes; they do not claim to emulate Kobo firmware networking or Kindle OOM behavior exactly.

## Built beta package

- Full install ZIP: `miuread-v5.8.0-beta.12-full.zip`
- Size: **1,917,935 bytes**
- SHA-256: `3767fc6ec1614af17a25969008aafb83d41c04372e3d695504ae31649fed0630`
- Runtime ZIP entries: **258**, all under `miuread.koplugin/`.
- Python `ZipFile.testzip()` and `unzip -t` both pass.
- Manifest version/size/SHA match the generated full ZIP.
