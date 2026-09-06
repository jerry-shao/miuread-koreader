# 5.8.0-beta.18 verification

Scope: make extension versions follow the actual newest installable stable GitHub Release, allow structurally verified community extensions to install without a MiuRead allow-list, preserve the beta.15 download/integrity model, and move 公众号 out of the middle Home shortcut strip into the pull-down control center.

## Extension version authority

- “觅阅推荐” is trust/compatibility metadata, not a frozen latest-version registry.
- The center reads up to 20 recent GitHub Releases and selects the first stable release that exposes a plausible plugin ZIP.
- Drafts and prereleases are ignored. A `stable-channel`/manifest release with no plugin ZIP is skipped.
- A newest installable Release with tied top assets is not guessed; the user is asked to choose.
- InkStain canonical repo is `Estela-Zelin84/inkstain.koplugin`; `miumiupy98-art/inkstain.koplugin` remains a historical alias so existing records migrate without uninstall/reinstall.
- Curated entries retain a verified fallback package, but runtime “latest” and update checks are GitHub-driven.

## Community installation

- A repository does not need to be in the MiuRead catalog to be installable.
- Official Release assets must identify one safe `.koplugin` target; architecture-labelled foreign assets are filtered before download and the existing post-extraction platform/ELF checks still run.
- If no usable stable Release exists, source installation is considered only after GitHub Contents proves `main.lua + _meta.lua` at the repo root (with a safe `.koplugin` repo name) or inside one unambiguous `.koplugin` directory.
- Multiple source plugin directories, missing markers, unsafe install dir names, and ambiguous Release assets remain fail-closed.
- GitHub/API/network failure is never reinterpreted as “there is no Release”, so it cannot silently trigger source fallback.

## Integrity / transport

- Existing beta.15 route selection, large-file probes, resumable partials, cloud-write priority and transaction install remain unchanged.
- Mirrors transport the exact already-selected official GitHub asset; they do not choose versions/packages.
- Official size and digest are checked when GitHub exposes them.
- For historical official assets without a digest, MiuRead computes and records a local SHA-256 when the device can do so; archive traversal, plugin structure and compatibility checks remain mandatory.
- GitHub metadata cache TTL is 30 minutes to avoid repeated requests while still following new releases promptly.

## Home 公众号 placement

- Middle Home shortcut defaults remain exactly: 刷新 / 搜索 / 下载 / 同步 / 休眠 / 设置.
- `mp` is removed from legacy `action_items` during preference normalization.
- 公众号 is now a pull-down control-center candidate and opens `show_mp_shelf(false)`.
- An untouched beta.16 default control-center layout replaces Screenshot with 公众号 so the default stays within eight slots; Screenshot remains available through customization.
- Customized layouts are preserved and only gain 公众号 as an optional candidate.

## Regression boundary

beta.17 keeps schema **132** and ReadReport **v28**. It does not replace beta.16 shared Store behavior, beta.13 exact progress mapping, beta.14 public-account shelf/article navigation, beta.15 download transport/cloud-write priority, OTA core, or KOReader Reader/CRE/input internals.

## Automated verification

Run:

- `python tools/verify_beta17.py`
- `texlua tools/test_extension_catalog.lua`
- `texlua tools/test_extension_download.lua`
- `texlua tools/test_extension_install.lua`
- `texlua tools/test_store_repair.lua`
- `texlua tools/test_store_shared.lua`
- `texlua tools/test_digest_stream.lua`

The final Release ZIP must contain a single `miuread.koplugin/` root and its version must match `5.8.0-beta.18`.

## beta.18 lockscreen / device-beauty acceptance

- `设备美化` contains Appearance / InkStain / DashWallpaper / CoverProgress / Highlights Screensaver; DashWallpaper is featured.
- Only InkStain and DashWallpaper are direct external lockscreen providers in beta.18.
- Native cover / InkStain / DashWallpaper switches preserve a native rollback snapshot and never commit Dash before a valid PNG exists.
- Lock-screen-triggered extension install records a pending provider, resumes after restart, and clears the pending intent on every install failure path.
- Missing external provider falls back to the last native cover style. Android/no-suspend devices are not force-integrated.
- The Home middle quick strip still excludes 公众号; 公众号 remains in the pull-down panel.
- `python3 tools/verify_beta18.py` must pass before packaging.
