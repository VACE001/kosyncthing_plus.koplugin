# Changelog

## [v1.1.4] — 2026-06-08

### Changed
- **Manual Stop is now session-only** — Syncthing starts again on the next
  KOReader launch; only turning off the Autostart toggle stops it for good.
- **Conflict list shows readable names** — book/file name and detection time
  instead of the raw `…sync-conflict-…` filename.
- **Redesigned Copy diagnostic info** — labelled sections and aligned columns;
  fixes wrapped/doubled separators on Kindle.

### Fixed
- **Reading-progress conflicts no longer swap "Mine" and "Theirs"** when this
  device wrote the moved-aside copy — the dialog now offers **Keep incoming** /
  **Restore mine** with the correct percentages.
- Conflict-resolution messages are now orientation-aware.
- Missing reading percentage shows **unknown** instead of **no date**.
- **Autostart now starts on a cold launch.**
- **Android: auto-merge after Rescan waits for the rescan to land** instead of
  running before any conflicts exist.

### Removed
- Dead `SyncthingStateChanged` event (no listener; the broadcasts did nothing).
  `SyncthingSyncCompleted` and `SyncthingConflictDetected` are unchanged.

## [v1.1.3] — 2026-06-07

### Added
- Richer **Copy diagnostic info** — binary ELF check, process RSS/threads/CPU,
  filesystem type & free space, network loopback & Kindle firewall ports
  (22000 TCP, 21027 UDP), folder/device counts.
- Kindle firewall now opens TCP 22000 (sync) and UDP 21027 (discovery)
  automatically, fixing pairing issues.
- **Autostart respects manual pause** — manually stopping Syncthing from the
  menu now pauses Autostart until you start it again. Previously Autostart
  would immediately restart the daemon after a manual stop.
- **LAN-only network support** — Autostart and sync timers now use
  `NetworkMgr:isConnected()` (has IP association) before falling back to
  `isOnline()` (has internet route). Syncthing can sync on local networks
  without internet access.

### Changed
- Binary download validates ELF & gzip magic and enforces a minimum file size
  before extraction.
- Binary installation is atomic (`.new` file replaced only after ELF check).
- Notifications say "network unavailable / disconnected" instead of
  "Wi‑Fi unavailable / disconnected" to match the new LAN-only behaviour.

### Fixed
- Text file named `syncthing` (Kobo app‑stream metadata) no longer accepted as
  a valid binary.
- Curl is tried before wget for more reliable GitHub downloads.
- Architecture detection now uses a single shared helper
  (`st_utils.detectArch`).
  
- **Autostart no longer breaks after network loss.** Automatic stops
  (network disconnect, app close) were incorrectly setting the `user_paused`
  flag, causing Autostart to stay disabled after reconnecting or restarting
  the app. Only an explicit manual stop now sets the flag.
  
- **Conflict dialog no longer shows "unknown" for older devices.** Older
  KOReader builds (pre-2022) write `last_percent` instead of
  `percent_finished`; both fields are now recognised when reading progress
  from metadata sidecar files.
- **Conflict dialog now appears when only one side has a percent field.**
  Previously the "reading progress conflict" dialog was suppressed when the
  conflict copy lacked `percent_finished` even though the local copy had it
  (or vice versa). The dialog now opens whenever either side carries progress
  data, showing the known percentage and "unknown" only for the side that
  genuinely has none.
- **`getConflictsDetailed` now reports `has_progress = true` when at least
  one side has a percent field** (previously required both sides). This
  affects the auto-merge menu display and any companion plugins that read
  conflict metadata.

## [v1.1.2] — 2026-06-06

### Added
- **Auto-merge conflicts after sync** — Android remote mode, menu.

## [v1.1.1] — 2026-06-06

### Added
- **Auto-merge conflicts after sync** — opt-in checkbox in `Automation` menu.
  After every Quick Sync, reading-progress conflicts are merged automatically
  (higher `percent_finished` wins). Off by default.

### Fixed
- Architecture detection unified into a single helper (`st_utils.detectArch`).
  LuaJIT is tried first, `uname -m` as fallback. Fixes potential mismatch on
  Libra Colour and similar devices where the two previous independent parsers
  (in `st_update.lua` and `legacy.lua`) could disagree.
- `InfoMessage` was used in `main.lua` without a local `require`, relying on
  load-order side effects. Now required explicitly.

---

## [v1.1.0] — 2026-05-01

Initial public release.

- **Quick Sync** — one-tap sync with automatic Wi-Fi on/off, disk-space check,
  progress notifications, and transfer summary.
- **Autostart & Periodic Sync** — background daemon management with Wi-Fi
  awareness, exponential backoff, and a charging gate.
- **Conflict resolution** — scan, auto-merge reading progress, keep-local, or
  use-remote; per-file and bulk actions.
- **Folder & device management** — pause, rescan, add/remove via the KOReader
  menu without opening the Syncthing web UI.
- **Pairing wizard** — guided setup for adding new devices.
- **Legacy mode** — runs an older Syncthing binary (v1.27.12 or v1.2.2) on
  devices with kernels ≤ 3.1 (Kindle PW2/PW3, Kobo Touch 2, etc.).
- **Android remote mode** — connects to an existing Syncthing app on Android
  instead of managing a local daemon.
- **Binary auto-update** — checks GitHub Releases and downloads the correct
  architecture binary over Wi-Fi.
- **Companion plugin API** — public Lua API for other KOReader plugins to
  query status and trigger sync actions.
- **Bulgarian translation** (`bg.po`).
