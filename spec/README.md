# Test Harness

The specs use a lightweight Busted-style harness with mock KOReader modules.

## Layout

- `spec_helper.lua` sets `package.path` and installs mocks.
- `mock_koreader.lua` provides `UIManager`, `NetworkMgr`, `Device`,
  `G_reader_settings`, widgets, `util`, and small helpers for scheduled timers.
- `st_sync_spec.lua` covers Quick Sync scan failure, disk-space abort, and
  folder-error detection during idle waiting.
- `st_conflict_spec.lua` covers conflict auto-merge behavior when file removal
  fails.
- `st_orchestrator_spec.lua` covers periodic sync Wi-Fi lease cleanup.
- `st_timer_spec.lua` covers periodic timer cancellation through the public API.
- `st_guard_spec.lua` covers lease idempotency and exception release.

## Running

Install Busted in a Lua 5.1 or LuaJIT environment that can load the plugin:

```sh
busted spec
```

The mocks intentionally keep KOReader behavior narrow. Add only the API surface
needed by a spec so accidental dependencies remain visible.
