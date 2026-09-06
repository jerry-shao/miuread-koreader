# 5.8.0-beta.14 verification

Scope: close the #93 public-account navigation regression and the #97 KPW5 Home/read-report/progress/network-state regressions without changing the beta.13 chapter/partial-book progress algorithm, downloader, extension installer, OTA flow, or KOReader native Reader plumbing.

## #93 — public-account navigation

- Home quick actions include **公众号** by default; the action layout supports seven visible items and preserves user customization.
- `书架 → 公众号` is populated from WeRead public-account rows, even when no public-account article has been cached locally.
- `本机 → 公众号` remains local cached public-account articles; account collections and local articles are not conflated.
- Selecting the public-account source with no cached account list requests one refresh while retaining any previous cache on failure.
- A public-account article opened in Reader routes `更多` to the public-account reader menu first, exposing `返回文章列表 / 上一篇 / 下一篇 / 当前文章 / 全部阅读功能`.
- `返回文章列表` returns to the current public account's article list.

## #97 — Home interaction and refresh semantics

- Single-click Home refresh never opens the local-library folder chooser. An unconfigured local library shows a message instead; folder selection remains an explicit settings/file-management action.
- The Sync quick action no longer displays a fixed “submitted” notice. Its visible state is produced by the real pending/sync state.
- On low-memory devices, direct user interaction can cancel optional Home metadata/cover work in addition to statistics/shelf-summary work. Downloads and actual sync transactions are not cancelled by this rule.

## #97 — Wi-Fi state consistency

- A real NetworkManager association with a Kindle SSID immediately exits stale `recovering` presentation state.
- Association state and Internet reachability remain separate, so an associated network can be shown correctly even while Internet probing is still pending/failing.
- Home and Reader therefore no longer intentionally disagree merely because the previous recovery phase has not timed out.

## #97 — read-report worker health

- Read-report service version is **28**.
- The child service writes a lightweight heartbeat outside blocking WeRead report calls.
- The parent distinguishes startup grace, idle-stall timeout, and legitimate in-flight HTTP reporting timeout.
- A living-but-stalled service is retired and restarted automatically, with a bounded number of automatic restarts.
- Restart does **not** replay an interval whose network dispatch outcome is unknown.
- Writer-barrier callers receive a cancellation result when a stuck service is restarted, so they cannot remain blocked on a dead generation.

## #97 — progress priority and conflict persistence

- The exact final `chapter + co` position is persisted locally before network-dependent finalization.
- Reading-end gives an already-running reading-time writer only a short **4-second** handoff window. If it is still busy, progress is parked durably for later recovery instead of blocking suspend/Home for tens of seconds or writing concurrently.
- The foreground progress writer fence is bounded to **8 seconds**; an uncertain in-flight reading-time request is never killed and blindly replayed.
- Choosing **使用本机位置** stores an exact-position fingerprint. The same unresolved local position resumes its saved upload/verification transaction after resume rather than showing the same cloud-conflict question again.
- A genuinely new local position, a remote-position choice, or successful cloud verification clears/replaces that remembered decision as appropriate.

## Regression boundary

beta.14 intentionally keeps schema **132** and does not replace:

- beta.13 standalone/partial EPUB whole-book progress conversion;
- exact WeRead `chapter + co` encoding/verification;
- download/extension installation transactions;
- Kindle/Kobo background download implementation;
- OTA/update transport;
- KOReader native typography/CRE/input behavior.

## Automated verification

- `python tools/verify_beta14.py`: **120/120 passed**.
- Shipped Lua syntax: **136/136 passed** using `texluac -p`.
- Extension catalog regression: PASS.
- Extension download fault model: PASS.
- Extension installer transaction/rollback/path-safety model: PASS.
- Store migration/compaction regression: PASS.
- beta.13 partial/standalone progress regression checks: PASS.
- #93 Home/account/Reader navigation checks: PASS.
- #97 refresh/Wi-Fi/read-report-health/progress-priority/conflict-persistence checks: PASS.

## Real-device validation still required

Static, syntax, and deterministic regression tests cannot emulate Kindle scheduling, Wi-Fi firmware behavior, or WeRead server timing. Before stable promotion, KPW5/KPW6 real-device verification should cover:

1. Home → 公众号 → account → article → Reader → 返回文章列表.
2. An account with zero locally cached articles still appears in `书架 → 公众号`; `本机 → 公众号` remains empty until an article is cached.
3. KPW5 continuous reading for at least two hours, then Home/suspend; compare WeRead reading time and final cloud location.
4. Force/observe a slow read-report call; Home/suspend must not wait tens of seconds, and the final exact position must recover later without duplicate time replay.
5. Choose local progress once during a conflict, suspend/resume before cloud confirmation, and verify the same exact position is not prompted again.
6. Resume Wi-Fi on KPW5/KPW6: once SSID association is visible, Home must stop showing `恢复中`.
7. On an unconfigured local library, tap refresh: it must not open a directory chooser.
