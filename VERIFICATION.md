# 5.8.0-beta.13 verification

Scope: restore standalone/partial EPUB whole-book progress synchronization, fix #94 progress-vs-reading-time writer contention, make progress persistence dispatch-aware, and keep the already-stable beta.12 full-book/Reader behavior unchanged.

## Standalone / partial progress regression

Implemented safeguards:

- A standalone or partial EPUB can capture the exact WeRead native `chapter + co` coordinate before a trusted whole-book catalog is available. Whole-book `progress` is completed later from the verified catalog; the local partial EPUB percentage is never uploaded as whole-book progress.
- New partial downloads keep the complete WeRead catalog separate from the selected local chapters and keep time-only read reporting enabled.
- Schema **132** safely promotes legacy partial catalogs only when the stored `core_catalog_hash` matches the actual catalog and the catalog is larger than the local partial selection. An ambiguous one-chapter catalog is not auto-promoted; it must be remotely confirmed once.
- Missing/untrusted catalogs are recovered through the existing WeRead context path and then persisted with explicit `catalog_complete`, `catalog_chapter_count`, and `core_catalog_hash` metadata.
- Manual progress, Reader close, Home return, and suspend/finalizer paths preserve `pending_progress_coordinate` when exact chapter/co is available but whole-book percentage is not yet ready. Home recovery later completes the percentage and continues the same durable transaction.

## #94 — progress writer vs reading-time writer

- Progress writes now place a soft fence in front of the periodic reading-time service. No new time request can start while progress is waiting.
- An already-dispatched time request is never forcibly killed/replayed. The progress fence waits for that request to return, then takes ownership of `/web/book/read`; the previous hard 15-second `progress_writer_busy` failure path is no longer the normal contention behavior.
- The maximum soft wait is bounded at 115 seconds, longer than the compatibility worker's request timeout. If the writer still cannot be acquired, the exact progress snapshot remains durable and is classified as definitely unsent rather than being discarded.

## Dispatch-aware pending state

Progress is persisted as one of three effective transport states:

- `pending_send`: the request is definitely unsent and may be resumed automatically.
- `submitted`: the request was sent, or dispatch outcome is uncertain; recovery performs cloud readback only and does **not** replay the same position.
- `verified`: cloud chapter/co has confirmed the submitted position; pending state is cleared.

Cloud confirmation latency, old position readback, or temporary `0/0` does not erase the local exact position. The latest exact position for a book supersedes older pending positions.

## Reading-time safety for chapter downloads

- Historical `partial_range` downloads are migrated from `read_report_enabled=false` to safe time-only reporting when normal sync remains enabled.
- Time-only reporting repeats an already safe cloud position; it does not submit the local partial-document percentage.
- The service carries forward only seconds that are **provably unsent**. Once `/web/book/read` has been entered, the attempted interval is never replayed merely because the response was lost.
- Legacy pending reading-time debt from older builds has no dispatch proof and is therefore cleared during schema-132 migration instead of being replayed and potentially double-counted.

## Normal full-book / Reader regression boundary

Source-level function comparison against the supplied 5.8.0-beta.12 source passed **11/11** unchanged core functions:

- `Sync:position`
- `Sync:local_position`
- `Sync:_prefer_inverse_cloud_mapping`
- `Plugin:_remote_matches`
- `Plugin:_verify_progress_submission`
- `Plugin:onReaderReady`
- `Plugin:onCloseDocument`
- `Plugin:onResume`
- `Plugin:onSuspend`
- `Plugin:_begin_koreader_exit`
- `Plugin:_quiesce_download_for_exit`

Therefore beta.13 does not replace the existing full-book position algorithm, cloud matching/verification algorithm, KOReader Reader lifecycle, CRE handling, input handling, or native Exit/Restart download quiesce path. #87/#90 remain real-device regression items rather than another speculative Reader rewrite.

## Automated verification

- `python tools/verify_beta13.py`: **100/100 passed**.
- Shipped Lua syntax: **136/136 passed** using `texluac -p`.
- Extension catalog regression: PASS — 18 deterministic packages.
- Extension download fault model: PASS.
- Extension installer transaction/rollback/path-safety model: PASS.
- Store migration/compaction regression: PASS, including schema-132 partial catalog promotion, old partial read-report enablement, pending progress normalization, and non-replay of ambiguous legacy reading-time debt.
- Standalone/partial whole-book fault model: PASS.
- Progress transport state model (`pending_send` / `submitted` / `verified`): PASS.

## Hardware validation still required

Source/fault-model checks cannot emulate WeRead response timing, Kindle process scheduling, or KOReader input-device failure. Before stable promotion, real-device validation should cover:

1. **Standalone chapter:** download one chapter, read to several positions, manually upload, return Home, close/suspend, and verify the phone/Web WeRead location follows the same chapter and approximate text position.
2. **Legacy standalone chapter:** upgrade without redownloading; verify a hash-valid stored whole-book catalog is promoted and progress resumes automatically.
3. **Catalog recovery:** force/remove trusted catalog metadata while keeping a partial EPUB; verify exact chapter/co is retained first, the full catalog is recovered later, and the same pending transaction continues.
4. **#94:** trigger manual/end-of-reading progress while the reading-time service is actively writing. There must be no lost local position and no automatic replay of a request whose dispatch is uncertain.
5. **#87/#90:** KPW4/KPW5 open → page-turn → suspend/resume → Home. Confirm no regression in Reader rebuild/white-screen behavior; if `Broken pipe` recurs, capture a fresh beta.13 log because beta.13 intentionally does not modify KOReader's input subsystem.

## Built beta package

- Full install ZIP: `miuread-v5.8.0-beta.13-full.zip`
- Size: **1,915,272 bytes**
- SHA-256: `ffe3a41a59152af705562740a1681cac70343494477e7638b04f73c01ffb3a78`
- Runtime ZIP entries: **236**, all under `miuread.koplugin/`.
- Python `ZipFile.testzip()` and `unzip -t` both pass.
- `update.json` version/size/SHA match the generated full ZIP.
