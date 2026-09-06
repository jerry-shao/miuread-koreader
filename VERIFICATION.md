# 5.8.0-beta.16 verification

Scope: fix #102 by making ReaderUI and FileManager share one live foreground Store for the same settings/data identity, while preserving isolated download-worker state, directory repair, beta.15 extension transport/cloud-write priority, beta.13 exact-position math, and beta.14 public-account navigation.

## Extension package identity

- GitHub Release remains the authority for an official package's version, asset URL, size and digest.
- A transport failure never changes an official Release asset into `archive/refs/tags/*.zip` or `main.zip`.
- Catalog-pinned packages remain deterministic. Known unpinned repositories may resolve the latest official Release dynamically.
- Release asset selection filters non-ZIP/checksum/debug/source artifacts. If the top official candidates tie, the UI asks the user instead of guessing.
- Source archives are considered only after GitHub proves that no usable Release asset exists and the Contents API positively proves `main.lua + _meta.lua` at the repository root or in one unambiguous `.koplugin` directory.
- GitHub/API/network failure is never interpreted as “no Release”.

## Extension transport v5

- Automatic route order begins with **GitHub 中文社区** (`mirrors.git-zh.com`), with GitHub official, ghfast, gh-proxy and ghproxy.net retained as fallbacks for the exact same official asset.
- Large packages (>= 5 MiB) use resumable curl directly instead of first spending a full Lua-HTTP attempt.
- Connection/DNS timeout is 20 s. The old “below 1 KiB/s for 35 s” kill rule is removed; curl only reconnects after approximately 90 s of essentially zero transfer.
- Full package downloads have no wall-clock completion deadline.
- Fresh large downloads probe at most the first three high-value routes, 128 KiB each, with a 4 s connect / 5 s total cap per probe. Successful probes sort by measured throughput; unprobed proxies remain fallbacks; freshly failed probes move behind them.
- A meaningful existing partial (>= 512 KiB) outranks a fresh speed race.
- A partial may seed another route only for the same package identity. The original route-local checkpoint is preserved. A Range rejection can restart the new route without deleting the original checkpoint.
- Recent successful route identity is cached for six hours as a tie-breaker / small-package preference.
- Transient DNS/connect/TLS/transport failures park the task in a recoverable state with its checkpoint instead of exhausting/recreating the package.

## Integrity and install transaction

- Exact asset size is checked whenever GitHub provides it.
- SHA-256 is checked whenever the Release/catalog provides a digest.
- If shell digest tools are unavailable, MiuRead now hashes files incrementally in 256 KiB chunks; 60+ MiB archives are not read into the Lua heap as one string.
- Older official assets without a digest still require size (when known), valid archive traversal and plugin-structure validation before installation.
- KOReader Archiver remains the ZIP authority; path traversal/symlink/file-count/expanded-size checks remain in the single installer path.
- `main.lua` and `_meta.lua` markers remain mandatory.
- Installation continues to stage the new plugin, journal the switch, back up the old directory and roll back on failure/interruption.
- Pinyin IME v1.2.0 remains pinned to the official 63,312,207-byte Release asset and SHA-256 `14047ed2638c32637c1dbc831f676967a221548f435443815b1c223881f4bbcb`; the 220 MiB free-space preflight and expanded-size allowance remain active.

## Persistent task and sleep behavior

- Download task identity includes official URL, version, size and SHA-256; restart only resumes a task whose identity still matches the current package.
- Pause/cancel retain partial data; only **删除下载数据** removes the task directory/checkpoints.
- A fully downloaded package is revalidated before reuse and can continue local installation offline.
- Real suspend pauses unsupported background transfers without losing partial data; screen-saver/download-hold modes can retain the worker where the existing device power layer permits it.
- A stale `paused_priority` after KOReader restart becomes an automatically recoverable network-wait state so a dead sync owner cannot strand the task.

## Critical cloud-write priority

- Reading-end progress, manual progress and annotation writes acquire one shared critical network lane.
- Book downloads pause with `cloud_sync_priority`; extension downloads pause with `paused_priority` / `sync_priority` and preserve checkpoints.
- Critical progress waits at most about three seconds for transfer-pause acknowledgement, then proceeds; a slow downloader cannot block cloud state indefinitely.
- Only transfers paused by the critical lane are resumed when the lane is released.
- ReadReport v28 writer-fence / uncertainty rules remain intact: an unknown reading-time request is not killed and blindly replayed.

## Shared foreground Store (#102)

- ReaderUI and FileManager reuse one non-isolated Store when both the settings path and data directory match.
- Local-library root changes, scan caches, deferred preferences and reloads are immediately visible from either interface.
- `isolated=true` workers are never entered into the shared Store registry.
- Runtime directories are still checked/recreated before a shared Store is returned.
- A later unrelated Home preference flush cannot resurrect an older pending progress state after a newer verified progress state has already reached disk.
- Failed settings writes recover the shared live Store from the last valid on-disk state.

## Regression boundary

beta.16 intentionally keeps schema **132**, ReadReport **v28**, and does not replace:

- beta.13 standalone/partial EPUB whole-book conversion and exact WeRead `chapter + co` encoding;
- beta.14 public-account shelf/account/article separation and Reader return/prev/next navigation;
- the six recommended Home quick actions (`刷新 / 搜索 / 下载 / 同步 / 休眠 / 设置`) — **公众号 is not reintroduced there**;
- core OTA package logic;
- KOReader native typography/CRE/input behavior.

## Automated verification

- `python tools/verify_beta16.py`: **156/156 passed**.
- Shipped Lua syntax: **136/136 passed** using `texluac -p`.
- Dynamic extension catalog selection/source-fallback regression: PASS.
- Dynamic extension download integrity/route-identity regression: PASS.
- Dynamic extension installer transaction/rollback/path-safety regression: PASS.
- Store migration/compaction regression: PASS.
- Streaming SHA-256 regression against system `sha256sum`: PASS.
- beta.13 exact partial/standalone progress regression checks: PASS.
- beta.14 #93/#97 regression checks: PASS.
- beta.15 cloud-write/download-priority invariants: PASS.
- beta.16 shared-Store/local-library/progress-freshness invariants: PASS.

## Real-device/network validation still required before stable promotion

The build environment cannot emulate Kindle Wi-Fi/CDN behavior or WeRead server timing. The implementation is complete, but stable promotion should still exercise these external conditions on hardware:

1. Pinyin IME: start the 63.3 MB official Release asset, interrupt at roughly 10%, 50% and 90%, restore Wi-Fi, and confirm the same asset resumes instead of changing to source ZIP.
2. Let Pinyin run through an extended very-slow interval; moving bytes must not trigger the former 1 KiB/s / 35 s failure.
3. Verify the GitHub Chinese Community Release route on the target network. If it is unavailable or returns altered/truncated data, MiuRead must reject it and continue with another transport while preserving official size/digest identity.
4. Background-download book A or Pinyin while reading book B; close/suspend book B and confirm exact progress / annotations reach WeRead before the download resumes.
5. Kindle screen-off download; where the existing hold mode is active, the transfer should continue. On devices that truly suspend networking, wake should resume from the checkpoint.
6. Regression-check `书架 → 公众号 → account → article → 返回文章列表` and confirm the Home quick bar still has no dedicated 公众号 button.
