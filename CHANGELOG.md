# Changelog

## [v1.1.3] — 2026-06-07

### Added
- Richer **Copy diagnostic info** — binary ELF check, process RSS/threads/CPU,
  filesystem type & free space, network loopback & Kindle firewall ports
  (22000 TCP, 21027 UDP), folder/device counts.
- Kindle firewall now opens TCP 22000 (sync) and UDP 21027 (discovery)
  automatically, fixing pairing issues.

### Changed
- Binary download validates ELF & gzip magic and enforces a minimum file size
  before extraction.
- Binary installation is atomic (`.new` file replaced only after ELF check).

### Fixed
- Text file named `syncthing` (Kobo app‑stream metadata) no longer accepted as
  a valid binary.
- Curl is tried before wget for more reliable GitHub downloads.
- Architecture detection now uses a single shared helper
  (`st_utils.detectArch`).

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
