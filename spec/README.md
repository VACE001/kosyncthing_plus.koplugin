# Test Suite

427 tests across 13 spec files. No KOReader installation required — all
platform modules are stubbed by the mock layer.

## Running

The suite ships a self-contained runner (`run_tests.lua`) that works under
plain Lua 5.1, Lua 5.3, or LuaJIT without any extra dependencies:

```sh
# Run one file
lua5.1 spec/run_tests.lua spec/st_health_spec.lua

# Run everything from the plugin root
for f in spec/*_spec.lua; do lua5.1 spec/run_tests.lua "$f"; done
```

[Busted](https://lunarmodules.github.io/busted/) also works for all files
except `st_process_spec` (see below):

```sh
luarocks install busted
busted spec/st_health_spec.lua   # single file
busted spec                      # all files (skips st_process_spec)
```

## Spec files

| File | What it covers | Tests |
|------|---------------|-------|
| `st_sync_spec.lua` | Quick Sync: scan failure, disk-space abort, folder-error detection during idle wait | 3 |
| `st_conflict_spec.lua` | Conflict auto-merge: file removal failure, path construction, `.sync-conflict` pattern matching | 20 |
| `st_health_spec.lua` | `getFolderHealth`: paused/error/syncing/idle state derivation, need-bytes accounting, per-folder error aggregation | 41 |
| `st_orchestrator_spec.lua` | Lifecycle orchestration: autostart/stop, manual toggle, periodic sync scheduling, suspend/resume, Wi-Fi lease cleanup, reconcile, **opt-in auto-merge after sync** (`runSyncCompleted`) | 44 |
| `st_timer_spec.lua` | Periodic timer cancellation through the public API | 1 |
| `st_guard_spec.lua` | Named lease idempotency, standby/wakelock balance, exception-path release | 25 |
| `st_utils_spec.lua` | Path helpers, `isTransientFolderError`, `formatTime`, `getFriendlySize`, settings key catalogue, loopback detection, **`detectArch`** (LuaJIT path, `uname -m` fallback, unknown/failure cases) | 65 |
| `st_android_spec.lua` | `androidApiCall` contract: status codes, JSON decode, error recording, TLS flag propagation | 25 |
| `st_datadir_spec.lua` | Data-directory selection, legacy-path migration, FAT/FUSE detection | 11 |
| `st_filesystem_spec.lua` | Safe-delete guard, dangerous-path rejection, conflict-file scanning, archive extraction | 36 |
| `st_api_spec.lua` | `SafeClient` HTTP layer: GET/PUT/PATCH routing, error capture, cache invalidation | 33 |
| `st_legacy_spec.lua` | Legacy-mode gate (`needsPatch`), `downloadBinary` URL/arch construction, archive validation (`fileSize`, `isGzip`, `isELF`), atomic staging install, `patchSyncthingObject` read-modify-write shim | 69 |
| `st_process_spec.lua` | Binary lifecycle: `start`, `stop`, `kindlePortGuard`, Kindle UDP port guards, `binaryExists` (ELF check), `isRunning`, `safeHomeDir`, `applyNetworkSettings`, `stopPlugin` | 54 |
| **Total** | | **427** |

### Note on `st_process_spec` and Busted

`st_process_spec` passes cleanly under `run_tests.lua` but hangs under
Busted (Lua 5.1). The cause is a Busted-specific sandboxing interaction with
`io.popen` — Busted's environment isolation prevents the spec's `stubIO()`
mock from intercepting `io.popen` calls made by `st_process.lua` before the
first `before_each` fires. The plain runner in `run_tests.lua` does not use
`setfenv` isolation and does not have this problem.

## Infrastructure

| File | Role |
|------|------|
| `spec_helper.lua` | Sets `package.path` and calls `Mock.install()` |
| `mock_koreader.lua` | Stubs `UIManager`, `NetworkMgr`, `Device`, `G_reader_settings`, all widgets, `util`, `ffi/util`, timer scheduling, and `dkjson`/`json` |
| `dkjson.lua` | Bundled pure-Lua JSON library used by specs that need real JSON decoding |
| `run_tests.lua` | Minimal Busted-compatible runner; works under plain Lua 5.1/5.3/LuaJIT without luarocks |

### Design rules

- Each spec file is **self-contained**: it installs only the mock surface it
  actually needs. Accidental dependencies on unrelated globals remain visible
  as immediate errors rather than silent passes.
- `spec_helper.lua` / `mock_koreader.lua` provide the shared baseline.
  Specs that need narrower or conflicting behaviour override individual
  `package.loaded` entries before calling `require()`.
- `detectArch` tests control `package.loaded["jit"]` directly (not `_G.jit`)
  because `detectArch` uses `pcall(require, "jit")` which reads the module
  cache, not the global — this matters when running under `texlua`/LuaTeX
  where the real `jit` module is already cached at startup.
- `st_legacy_spec` and `st_process_spec` stub new `st_utils` helpers
  (`fileSize`, `isGzip`, `isELF`, `kindleOpenPortUDP`, `kindleClosePortUDP`)
  as controllable fakes. Defaults represent the happy path so existing tests
  are unaffected; tests that exercise a specific failure path override via
  `FAKE.*` fields (e.g. `FAKE.is_gzip = false`).
- No network access, no filesystem writes, no real processes are started.
