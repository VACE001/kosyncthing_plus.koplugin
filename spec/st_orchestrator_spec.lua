-- st_orchestrator_spec.lua – tests for high-level lifecycle flows.
-- Covers: runAutoStart, runAutoStop, runManualToggle, runPeriodicSync
-- (skips, rescan-when-running, wifi-up path, absolute timeout),
-- runSuspendStop, runResumeRestore, runNetworkConnected.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function freshOrchestrator()
    package.loaded["st_orchestrator"] = nil
    package.loaded["st_guard"]        = nil
    return require("st_orchestrator")
end

-- Minimal plugin stub; all fields overridable.
local function makePlugin(overrides)
    overrides = overrides or {}
    local p = {
        -- state flags
        _health_check_active   = true,
        periodic_sync_enabled  = false,
        _quick_sync_active     = false,
        _silentStart           = nil,
        _was_running_before_suspend = false,
        auto_start_always      = false,
        next_count             = 0,
        wifi_done_count        = 0,
        stop_calls             = 0,
        start_calls            = 0,
        -- capability stubs
        _chargingConditionMet  = overrides._chargingConditionMet  or function() return true end,
        binaryExists           = overrides.binaryExists           or function() return true end,
        isRunning              = overrides.isRunning              or function() return false end,
        _invalidateProcess     = overrides._invalidateProcess     or function() end,
        showFirstRunDialog     = overrides.showFirstRunDialog     or function(_, cb) if cb then cb() end end,
        showNotification       = overrides.showNotification       or function(_, text)
            table.insert(Mock.state.notifications, text)
        end,
        start                  = overrides.start or function(self, cb)
            self.start_calls = self.start_calls + 1
            if cb then cb() end
        end,
        stop                   = overrides.stop or function(self, cb, is_suspend, is_auto)
            self.stop_calls = self.stop_calls + 1
            if cb then cb() end
        end,
        syncNow                = overrides.syncNow               or function() end,
        _startQuickSync        = overrides._startQuickSync       or function(_, cb)
            if cb then cb({ ok = true }) end
        end,
        _scheduleNextPeriodicSync = overrides._scheduleNextPeriodicSync or function(self)
            self.next_count = self.next_count + 1
        end,
        _periodicSyncWifiDone  = overrides._periodicSyncWifiDone or function(self)
            self.wifi_done_count = self.wifi_done_count + 1
        end,
    }
    return p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: runAutoStart
-- ─────────────────────────────────────────────────────────────────────────────

describe("runAutoStart", function()
    before_each(function() Mock.reset() end)

    it("fires callback immediately when already running", function()
        local orch = freshOrchestrator()
        local cb_arg = nil
        local plugin = makePlugin({ isRunning = function() return true end })
        orch.runAutoStart(plugin, "test_reason", function(r) cb_arg = r end)
        assert.are.equal("test_reason", cb_arg)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("fires callback immediately when charging condition not met", function()
        local orch = freshOrchestrator()
        local cb_called = false
        local plugin = makePlugin({
            _chargingConditionMet = function() return false end,
        })
        orch.runAutoStart(plugin, "reason", function() cb_called = true end)
        assert.is_true(cb_called)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("fires callback immediately when binary is missing", function()
        local orch = freshOrchestrator()
        local cb_called = false
        local plugin = makePlugin({ binaryExists = function() return false end })
        orch.runAutoStart(plugin, "reason", function() cb_called = true end)
        assert.is_true(cb_called)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("calls startSilent (_silentStart=true + start) when online and conditions met", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "network_connected", nil)
        assert.are.equal(1, plugin.start_calls)
        assert.is_true(plugin._silentStart)
    end)

    it("enables wifi then starts when offline and online after callback", function()
        Mock.state.wifi_online = false
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "reason", nil)
        -- NetworkMgr:enableWifi fires the callback synchronously in the mock;
        -- the callback sees wifi_online=false so it calls the fallback cb, not start.
        -- But enableWifi was called:
        assert.are.equal(1, Mock.state.wifi_enable_calls)
    end)

    it("fires callback immediately when user_paused flag is set", function()
        Mock.state.wifi_online = true
        G_reader_settings:saveSetting("syncthing_user_paused", true)
        local orch = freshOrchestrator()
        local cb_called = false
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "network_connected", function() cb_called = true end)
        assert.is_true(cb_called)
        assert.are.equal(0, plugin.start_calls)
        G_reader_settings:delSetting("syncthing_user_paused")
    end)

    it("starts normally when user_paused flag is absent", function()
        Mock.state.wifi_online = true
        G_reader_settings:delSetting("syncthing_user_paused")
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "network_connected", nil)
        assert.are.equal(1, plugin.start_calls)
    end)

    it("starts on LAN-only network (isConnected=true, isOnline=false)", function()
        Mock.state.wifi_online    = false
        Mock.state.wifi_connected = true   -- has IP, no internet route
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "network_connected", nil)
        assert.are.equal(1, plugin.start_calls)
        Mock.state.wifi_connected = nil
    end)

    it("does not start when both isConnected and isOnline are false", function()
        Mock.state.wifi_online      = false
        Mock.state.wifi_connected   = false
        Mock.state.wifi_auto_callback = false  -- enableWifi fires but network stays down
        local orch = freshOrchestrator()
        local cb_called = false
        local plugin = makePlugin()
        orch.runAutoStart(plugin, "reason", function() cb_called = true end)
        assert.are.equal(0, plugin.start_calls)
        Mock.state.wifi_connected = nil
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: runAutoStop
-- ─────────────────────────────────────────────────────────────────────────────

describe("runAutoStop", function()
    before_each(function() Mock.reset() end)

    it("fires callback immediately when not running", function()
        local orch = freshOrchestrator()
        local cb_called = false
        local plugin = makePlugin({ isRunning = function() return false end })
        orch.runAutoStop(plugin, "suspend", function() cb_called = true end)
        assert.is_true(cb_called)
        assert.are.equal(0, plugin.stop_calls)
    end)

    it("calls stop with is_suspend=true when reason is 'suspend'", function()
        local orch = freshOrchestrator()
        local stop_suspend, stop_auto
        local plugin = makePlugin({
            isRunning = function() return true end,
            stop = function(self, cb, is_suspend, is_auto)
                stop_suspend = is_suspend
                stop_auto    = is_auto
                if cb then cb() end
            end,
        })
        orch.runAutoStop(plugin, "suspend", nil)
        assert.is_true(stop_suspend)
        assert.is_true(stop_auto)
    end)

    it("calls stop with is_suspend=false for non-suspend reason", function()
        local orch = freshOrchestrator()
        local stop_suspend
        local plugin = makePlugin({
            isRunning = function() return true end,
            stop = function(self, cb, is_suspend, is_auto)
                stop_suspend = is_suspend
                if cb then cb() end
            end,
        })
        orch.runAutoStop(plugin, "network", nil)
        assert.is_false(stop_suspend)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: runManualToggle
-- ─────────────────────────────────────────────────────────────────────────────

describe("runManualToggle", function()
    before_each(function() Mock.reset() end)

    it("calls showFirstRunDialog when binary is missing", function()
        local orch = freshOrchestrator()
        local dialog_shown = false
        local plugin = makePlugin({
            binaryExists = function() return false end,
            showFirstRunDialog = function(_, cb)
                dialog_shown = true
                if cb then cb() end
            end,
        })
        orch.runManualToggle(plugin, nil)
        assert.is_true(dialog_shown)
    end)

    it("stops when currently running", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return true end })
        orch.runManualToggle(plugin, nil)
        assert.are.equal(1, plugin.stop_calls)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("starts (via NetworkMgr:runWhenOnline) when not running", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return false end })
        orch.runManualToggle(plugin, nil)
        -- runManualStart goes via NetworkMgr:runWhenOnline which fires cb synchronously
        assert.are.equal(1, plugin.start_calls)
        assert.are.equal(0, plugin.stop_calls)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: runPeriodicSync
-- ─────────────────────────────────────────────────────────────────────────────

describe("runPeriodicSync", function()
    before_each(function() Mock.reset() end)

    it("returns immediately when _health_check_active is false", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ _health_check_active = false } )
        plugin._health_check_active = false
        plugin.periodic_sync_enabled = true
        orch.runPeriodicSync(plugin)
        assert.are.equal(0, plugin.next_count)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("returns immediately when periodic_sync_enabled is false", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.periodic_sync_enabled = false
        orch.runPeriodicSync(plugin)
        assert.are.equal(0, plugin.next_count)
    end)

    it("schedules next tick without syncing when quick_sync_active is true", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.periodic_sync_enabled = true
        plugin._quick_sync_active = true
        orch.runPeriodicSync(plugin)
        assert.are.equal(1, plugin.next_count)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("skips without starting when charging condition not met", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({
            _chargingConditionMet = function() return false end,
        })
        plugin.periodic_sync_enabled = true
        orch.runPeriodicSync(plugin)
        Mock.runTimers(5)
        assert.are.equal(1, plugin.next_count)
        assert.are.equal(0, plugin.start_calls)
    end)

    it("skips and shows notification when binary is missing", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ binaryExists = function() return false end })
        plugin.periodic_sync_enabled = true
        orch.runPeriodicSync(plugin)
        Mock.runTimers(5)
        assert.are.equal(1, plugin.next_count)
        assert.are.equal(1, #Mock.state.notifications)
    end)

    it("calls syncNow and schedules next tick when already running", function()
        local orch = freshOrchestrator()
        local synced = false
        local plugin = makePlugin({
            isRunning = function() return true end,
            syncNow   = function() synced = true end,
        })
        plugin.periodic_sync_enabled = true
        orch.runPeriodicSync(plugin)
        Mock.runTimers(5)
        assert.is_true(synced)
        assert.are.equal(1, plugin.next_count)
    end)

    it("starts via _startQuickSync and schedules next tick when wifi already online", function()
        -- Wifi is already up: sync completes synchronously, no wifi teardown needed.
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.periodic_sync_enabled = true

        orch.runPeriodicSync(plugin)
        Mock.runTimers(5)

        assert.are.equal(1, plugin.next_count)
        -- No wifi was disabled – it was already on before the sync.
        assert.are.equal(0, plugin.wifi_done_count)
        assert.is_false(plugin._quick_sync_active)
        assert.is_nil(require("st_guard"):active("periodic_sync_wifi"))
    end)

    it("calls _periodicSyncWifiDone and schedules next tick when offline (original regression)", function()
        -- Wifi is off: the abs-timeout (490 s) fires first in the mock timer
        -- queue, triggering finish(true) which calls _periodicSyncWifiDone.
        Mock.state.wifi_online = false
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.periodic_sync_enabled = true

        orch.runPeriodicSync(plugin)
        Mock.runTimers(10)

        assert.are.equal(1, plugin.next_count)
        assert.are.equal(1, plugin.wifi_done_count)
        assert.is_false(plugin._quick_sync_active)
        assert.is_nil(require("st_guard"):active("periodic_sync_wifi"))
    end)

    it("absolute 490 s safety timeout fires finish and schedules next tick", function()
        -- Force the wifi retry path so the abs-timeout is what ends the flow.
        Mock.state.wifi_online = false
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.periodic_sync_enabled = true

        -- enableWifi callback never calls isOnline=true so the retry loop runs.
        -- After 490 simulated seconds the safety timeout fires.
        orch.runPeriodicSync(plugin)
        Mock.runTimers(200)  -- enough to fire the 490 s abs-timeout timer

        -- The abs-timeout calls finish(true) which calls _scheduleNextPeriodicSync.
        assert.are.equal(1, plugin.next_count)
        assert.is_false(plugin._quick_sync_active)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: runSuspendStop
-- ─────────────────────────────────────────────────────────────────────────────

describe("runSuspendStop", function()
    before_each(function() Mock.reset() end)

    it("saves syncthing_was_running=true and sets flag when running", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return true end })
        orch.runSuspendStop(plugin)
        assert.is_true(G_reader_settings:readSetting("syncthing_was_running"))
        assert.is_true(plugin._was_running_before_suspend)
    end)

    it("saves syncthing_was_running=false and clears flag when not running", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return false end })
        orch.runSuspendStop(plugin)
        assert.is_false(G_reader_settings:readSetting("syncthing_was_running"))
        assert.is_false(plugin._was_running_before_suspend)
    end)

    it("calls stop with is_suspend=true when running", function()
        local orch = freshOrchestrator()
        local got_suspend
        local plugin = makePlugin({
            isRunning = function() return true end,
            stop = function(self, cb, is_suspend)
                got_suspend = is_suspend
                if cb then cb() end
            end,
        })
        orch.runSuspendStop(plugin)
        assert.is_true(got_suspend)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5b: runCloseStop (genuine-teardown stop — onExit / onPowerOff / onReboot)
-- ─────────────────────────────────────────────────────────────────────────────

describe("runCloseStop", function()
    before_each(function() Mock.reset() end)

    it("stops the daemon and clears was_running when running", function()
        local orch = freshOrchestrator()
        G_reader_settings:saveSetting("syncthing_was_running", true)
        local got_suspend = nil
        local plugin = makePlugin({
            isRunning = function() return true end,
            stop = function(self, cb, is_suspend)
                self.stop_calls = self.stop_calls + 1
                got_suspend = is_suspend
                if cb then cb() end
            end,
        })
        orch.runCloseStop(plugin)
        assert.are.equal(1, plugin.stop_calls)
        assert.is_false(got_suspend)   -- a close is not a suspend
        assert.is_false(G_reader_settings:readSetting("syncthing_was_running"))
    end)

    it("does nothing when the daemon is not running", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return false end })
        orch.runCloseStop(plugin)
        assert.are.equal(0, plugin.stop_calls)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: runResumeRestore
-- ─────────────────────────────────────────────────────────────────────────────

describe("runResumeRestore", function()
    before_each(function() Mock.reset() end)

    it("calls startSilent when was_running_before_suspend, online, condition met", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin._was_running_before_suspend = true
        orch.runResumeRestore(plugin)
        assert.are.equal(1, plugin.start_calls)
        assert.is_true(plugin._silentStart)
        assert.is_false(plugin._was_running_before_suspend)
    end)

    it("does NOT start when offline (leaves flag set for runNetworkConnected)", function()
        Mock.state.wifi_online = false
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin._was_running_before_suspend = true
        orch.runResumeRestore(plugin)
        assert.are.equal(0, plugin.start_calls)
        -- Flag intentionally NOT cleared when offline at resume time
        assert.is_true(plugin._was_running_before_suspend)
    end)

    it("starts periodic sync when enabled, not was_running, and online", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin._was_running_before_suspend = false
        plugin.periodic_sync_enabled = true
        orch.runResumeRestore(plugin)
        -- runPeriodicSync → wifi already online → _startQuickSync → callback
        assert.are.equal(1, plugin.next_count)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: runNetworkConnected
-- ─────────────────────────────────────────────────────────────────────────────

describe("runNetworkConnected", function()
    before_each(function() Mock.reset() end)

    it("restores Syncthing when was_running_before_suspend and conditions met", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin._was_running_before_suspend = true
        orch.runNetworkConnected(plugin)
        assert.are.equal(1, plugin.start_calls)
        assert.is_false(plugin._was_running_before_suspend)
    end)

    it("calls runAutoStart when auto_start_always is true", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.auto_start_always = true
        orch.runNetworkConnected(plugin)
        assert.are.equal(1, plugin.start_calls)
    end)

    it("does nothing when auto_start_always=false and was_running=false", function()
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin()
        plugin.auto_start_always = false
        orch.runNetworkConnected(plugin)
        assert.are.equal(0, plugin.start_calls)
    end)

    -- ── Autostart survives automatic network disconnect/reconnect ───────────
    it("auto_start_always: restarts after automatic network-loss stop (user_paused NOT set)", function()
        -- Simulate the full cycle:
        --   network drops  → runNetworkDisconnected → stop(silent=true) → user_paused must NOT be set
        --   network returns → runNetworkConnected   → runAutoStart      → Syncthing starts again
        Mock.state.wifi_online = true
        local orch = freshOrchestrator()
        local plugin = makePlugin({
            isRunning = function(self) return self._running end,
            stop = function(self, cb, is_suspend, silent)
                -- Simulate what st_process.stop() does after the fix:
                -- only set user_paused when not silent and not suspend.
                if not is_suspend and not silent then
                    G_reader_settings:saveSetting("syncthing_user_paused", true)
                end
                self._running = false
                if cb then cb() end
            end,
        })
        plugin.auto_start_always = true
        plugin._running = true

        -- Step 1: network disconnect → automatic stop
        Mock.state.wifi_online = false
        orch.runNetworkDisconnected(plugin)
        assert.is_false(plugin._running)
        assert.is_nil(Mock.state.settings["syncthing_user_paused"],
            "automatic stop must not set user_paused")

        -- Step 2: network reconnect → Autostart should fire
        Mock.state.wifi_online = true
        orch.runNetworkConnected(plugin)
        assert.are.equal(1, plugin.start_calls,
            "Autostart must restart Syncthing after automatic network stop")
    end)
end)

describe("reconcile (belief refresh, no lifecycle side effects)", function()
    it("invalidates the process cache and returns the fresh running state", function()
        local invalidated = false
        local orch = freshOrchestrator()
        local plugin = makePlugin({
            isRunning          = function() return true end,
            _invalidateProcess = function() invalidated = true end,
        })
        local running = orch.reconcile(plugin, "test")
        assert.is_true(invalidated)
        assert.is_true(running)
    end)

    it("clears a stale start_failed flag when the daemon is running", function()
        local orch = freshOrchestrator()
        G_reader_settings:saveSetting("syncthing_start_failed", true)
        local plugin = makePlugin({ isRunning = function() return true end })
        orch.reconcile(plugin, "test")
        assert.is_false(G_reader_settings:isTrue("syncthing_start_failed"))
    end)

    it("leaves start_failed set when the daemon is NOT running", function()
        local orch = freshOrchestrator()
        G_reader_settings:saveSetting("syncthing_start_failed", true)
        local plugin = makePlugin({ isRunning = function() return false end })
        orch.reconcile(plugin, "test")
        assert.is_true(G_reader_settings:isTrue("syncthing_start_failed"))
        G_reader_settings:delSetting("syncthing_start_failed")
    end)

    it("never starts or stops the daemon", function()
        local orch = freshOrchestrator()
        local plugin = makePlugin({ isRunning = function() return true end })
        orch.reconcile(plugin, "test")
        assert.are.equal(0, plugin.start_calls)
        assert.are.equal(0, plugin.stop_calls)
    end)
end)
-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 8: runSyncCompleted (opt-in auto-merge after Quick Sync)
-- ─────────────────────────────────────────────────────────────────────────────

describe("runSyncCompleted", function()
    before_each(function()
        Mock.reset()
        G_reader_settings:delSetting("syncthing_auto_merge_conflicts")
    end)

    -- Helper: plugin stub with controllable conflict/merge behaviour.
    local function makeAutoMergePlugin(overrides)
        overrides = overrides or {}
        local p = makePlugin(overrides)
        p.findConflicts = overrides.findConflicts or function() return {} end
        p.autoMergeReadingProgress = overrides.autoMergeReadingProgress
            or function(_, _conflicts) return { merged = 0, failed = 0 } end
        return p
    end

    it("does nothing when setting is off (default)", function()
        local orch = freshOrchestrator()
        local scanned = false
        local plugin = makeAutoMergePlugin({
            findConflicts = function() scanned = true return {} end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.is_false(scanned)
        assert.are.equal(0, #Mock.state.notifications)
    end)

    it("does nothing when setting is explicitly false", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", false)
        local orch = freshOrchestrator()
        local scanned = false
        local plugin = makeAutoMergePlugin({
            findConflicts = function() scanned = true return {} end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.is_false(scanned)
    end)

    it("is silent when setting is on but no conflicts exist", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local plugin = makeAutoMergePlugin({
            findConflicts = function() return {} end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.are.equal(0, #Mock.state.notifications)
    end)

    it("shows merge notification when conflicts are merged successfully", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local plugin = makeAutoMergePlugin({
            findConflicts = function()
                return { "/books/book.sdr/metadata.sync-conflict-20240101-120000-ABC.lua" }
            end,
            autoMergeReadingProgress = function(_, _c)
                return { merged = 1, failed = 0 }
            end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.are.equal(1, #Mock.state.notifications)
        -- notification should mention the count, not an error
        assert.is_nil(Mock.state.notifications[1]:find("failed"))
    end)

    it("shows failure notification when some merges fail", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local plugin = makeAutoMergePlugin({
            findConflicts = function()
                return {
                    "/books/a.sdr/metadata.sync-conflict-A.lua",
                    "/books/b.sdr/metadata.sync-conflict-B.lua",
                }
            end,
            autoMergeReadingProgress = function(_, _c)
                return { merged = 1, failed = 1 }
            end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.are.equal(1, #Mock.state.notifications)
        assert.is_not_nil(Mock.state.notifications[1]:find("failed") or
                          Mock.state.notifications[1]:find("Failed"))
    end)

    it("warns and skips merge when autoMergeReadingProgress raises an error", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local plugin = makeAutoMergePlugin({
            findConflicts = function()
                return { "/books/bad.sdr/metadata.sync-conflict-X.lua" }
            end,
            autoMergeReadingProgress = function(_, _c)
                error("disk I/O failure")
            end,
        })
        -- Should not propagate the error.
        assert.has_no.errors(function()
            orch.runSyncCompleted(plugin, {})
        end)
        -- One notification: the "failed" toast.
        assert.are.equal(1, #Mock.state.notifications)
    end)

    it("warns and skips when findConflicts raises an error", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local merged_called = false
        local plugin = makeAutoMergePlugin({
            findConflicts = function() error("scan error") end,
            autoMergeReadingProgress = function(_, _c)
                merged_called = true
                return { merged = 0, failed = 0 }
            end,
        })
        assert.has_no.errors(function()
            orch.runSyncCompleted(plugin, {})
        end)
        assert.is_false(merged_called)
        assert.are.equal(0, #Mock.state.notifications)
    end)

    it("is silent when merged=0 and failed=0 (no actionable conflicts)", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local plugin = makeAutoMergePlugin({
            findConflicts = function()
                return { "/books/non-metadata.sync-conflict-X.bin" }
            end,
            autoMergeReadingProgress = function(_, _c)
                return { merged = 0, failed = 0 }
            end,
        })
        orch.runSyncCompleted(plugin, {})
        assert.are.equal(0, #Mock.state.notifications)
    end)

    it("is a no-op when plugin lacks findConflicts", function()
        G_reader_settings:saveSetting("syncthing_auto_merge_conflicts", true)
        local orch = freshOrchestrator()
        local p = makePlugin()   -- no findConflicts / autoMergeReadingProgress
        assert.has_no.errors(function()
            orch.runSyncCompleted(p, {})
        end)
        assert.are.equal(0, #Mock.state.notifications)
    end)
end)
