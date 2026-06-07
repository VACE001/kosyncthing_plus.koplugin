-- st_orchestrator.lua - High-level lifecycle flows for Syncthing.
--
-- This module is intentionally above st_process/st_sync.  Those modules know
-- how to start, stop, scan, and wait; this one decides why the flow is
-- happening and therefore owns the policy:
--   * manual vs background notifications
--   * who owns Wi-Fi cleanup
--   * whether Syncthing should remain running
--   * when the caller callback is allowed to fire

local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local InfoMessage = require("ui/widget/infomessage")
local logger      = require("logger")
local time 		  = require("ui/time")
local T           = require("ffi/util").template
local _           = require("syncthing_i18n").gettext
local Guard       = require("st_guard")

local function safeCallback(callback, ...)
    if type(callback) ~= "function" then return end
    local ok, err = pcall(callback, ...)
    if not ok then
        logger.warn("[Syncthing] orchestrator callback failed: " .. tostring(err))
    end
end

-- Syncthing works on LAN-only networks without internet access.
-- isConnected() (has IP/association) is the right gate; isOnline() (has
-- internet route) is too strict and breaks LAN-only setups.
-- We fall back to isOnline() for platforms where isConnected is unreliable.
local function hasNetwork()
    local connected = type(NetworkMgr.isConnected) == "function"
        and NetworkMgr:isConnected()
    return connected or NetworkMgr:isOnline()
end

local function startSilent(self, callback)
    self._silentStart = true
    self:start(callback)
end

local function runManualStart(self, callback)
    if not self:binaryExists() then
        self:showFirstRunDialog(callback)
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:start(callback)
    end)
end

local function runManualStop(self, callback)
    self:stop(callback, false, false)
end

local function runManualToggle(self, callback)
    if not self:binaryExists() then
        self:showFirstRunDialog(callback)
        return
    end
    if self:isRunning() then
        runManualStop(self, callback)
    else
        runManualStart(self, callback)
    end
end

local function runAutoStart(self, reason, callback)
    if self:isRunning() then
        safeCallback(callback, reason)
        return
    end
    if not self:_chargingConditionMet() or not self:binaryExists() then
        safeCallback(callback, reason)
        return
    end
    if G_reader_settings:isTrue("syncthing_user_paused") then
        safeCallback(callback, reason)
        return
    end

    local function do_start()
        startSilent(self, callback)
    end

if hasNetwork() then
        do_start()
    else
        -- Try to bring Wi-Fi up; if it fails, just leave.
        NetworkMgr:enableWifi(function()
            if hasNetwork() then
                do_start()
            else
                safeCallback(callback, reason)
            end
        end, false)
    end
end

local function runAutoStop(self, reason, callback)
    if not self:isRunning() then
        safeCallback(callback, reason)
        return
    end
    self:stop(callback, reason == "suspend", true)
end


local function runQuickSync(self, on_ui_refresh, callback)
    if not self:binaryExists() then
        self:showFirstRunDialog(callback)
        return
    end

    if self._quick_sync_active then
        UIManager:show(InfoMessage:new{
            text    = _("Quick Sync is already in progress."),
            timeout = 4,
        })
        safeCallback(callback, { ok = false, reason = "already_active" })
        return
    end

    if self:isRunning() then
        -- Syncthing is already running; just request a rescan and return.
        -- Set the guard flag for the duration of the (synchronous) syncNow call
        -- so that a concurrent runPeriodicSync fast-path skips its own scan.
        self._quick_sync_active = true
        self:syncNow(on_ui_refresh)
        self._quick_sync_active = false
        safeCallback(callback, { ok = true, reason = "rescan" })
        return
    end

    self._quick_sync_active = true
    local finished = false
    -- Both timers hold a FUNCTION REFERENCE, not the return value of
    -- scheduleIn.  KOReader's UIManager:scheduleIn returns nothing, and
    -- UIManager:unschedule matches entries by `action == fn`.  Storing the
    -- return value made unschedule a silent no-op, so cancelled timers
    -- stayed live in the UI loop until they fired.  Holding the closure
    -- itself makes unschedule work.
    local wifi_retry_fn = nil
    local wifi_was_off_before = not hasNetwork()
    local wifi_lease = nil

    local function acquireWifiLease()
        if not wifi_lease then
            wifi_lease = Guard:acquire("quick_sync_wifi", {
                wifi = { disable_on_release = true },
            })
        end
    end

    local function finish(result)
        if finished then return end
        finished = true
        self._quick_sync_active = false
        if wifi_retry_fn then
            UIManager:unschedule(wifi_retry_fn)
            wifi_retry_fn = nil
        end
        if wifi_lease then
            wifi_lease:release()
            wifi_lease = nil
        end
        safeCallback(callback, result)
    end

    -- Absolute fallback timeout (130 s) — same race as runPeriodicSync.
    -- NetworkMgr:enableWifi() silently drops its callback when
    -- pending_connectivity_check is already true.  If that race hits,
    -- scheduleWifiRetry() never reschedules and finish() is never called.
    --
    -- Wrapper pattern (identical to runPeriodicSync): save the original finish
    -- as _finish_orig, then redefine finish to cancel the timer before calling
    -- through.  Every existing exit path calls the same finish it always did
    -- and now implicitly cancels the timer.
    --
    -- IMPORTANT: the timer closure must reference _finish_orig (declared before
    -- it), not finish (declared before it too, but reassigned after).  Calling
    -- `finish` from inside the timer would call the wrapper, which would try to
    -- unschedule an already-fired timer — harmless but redundant.  Calling
    -- `_finish_orig` directly is the correct, symmetric approach.
    local _finish_orig = finish
    local abs_timeout_fn
    abs_timeout_fn = function()
        if abs_timeout_fn then
            abs_timeout_fn = nil
            logger.warn("[Syncthing] Quick Sync: absolute 130 s safety timeout fired")
            _finish_orig({ ok = false, reason = "wifi_timeout" })
        end
    end
    UIManager:scheduleIn(130, abs_timeout_fn)
    finish = function(result)
        if abs_timeout_fn then
            UIManager:unschedule(abs_timeout_fn)
            abs_timeout_fn = nil
        end
        _finish_orig(result)
    end

    local function start_sync()
        self._silentStart = true
        self:_startQuickSync(finish, on_ui_refresh, { silent = false })
    end

    if not wifi_was_off_before then
        -- Wi-Fi is already on
        start_sync()
        return
    end

    -- Wi-Fi is off, bring it up with exponential backoff (up to 2 min).
    -- Initial delay is 7 s: most adapters come up in 3-6 s, so 7 s avoids
    -- a pointless first retry while still being responsive for a manual tap.
    -- Periodic Sync starts at 30 s because it runs silently in the background
    -- and a missed cycle is far less disruptive than a missed manual action.
    local retry_delay = 7
    local retry_start_time = nil

    local function scheduleWifiRetry()
        if finished then return end
        if not retry_start_time then
            retry_start_time = time.to_s(time.now())
        end
        local elapsed = time.to_s(time.now()) - retry_start_time
        if elapsed + retry_delay > 120 then
            logger.warn("[Syncthing] Quick Sync aborted: Wi‑Fi did not come up within 2 min")
            self:showNotification(_("Quick Sync skipped — network unavailable."), 5)
            finish({ ok = false, reason = "wifi_timeout" })
            return
        end
        logger.info("[Syncthing] Quick Sync: Wi‑Fi retry in " .. retry_delay .. "s")
        -- Store the closure itself so finish() can unschedule it.  Each retry
        -- overwrites wifi_retry_fn with the new closure; the previous one has
        -- already fired by the time we get here, so nothing leaks.
        wifi_retry_fn = function()
            if finished then return end
            acquireWifiLease() -- we asked the OS to bring Wi-Fi up
            local ok_enable, err_enable = pcall(function()
                NetworkMgr:enableWifi(function()
                if finished then return end
                if not hasNetwork() then
                    retry_delay = math.min(retry_delay * 2, 60)
                    scheduleWifiRetry()
                    return
                end
                wifi_retry_fn = nil
                start_sync()
                end, false)
            end)
            if not ok_enable then
                logger.warn("[Syncthing] Quick Sync: enableWifi failed: " .. tostring(err_enable))
                finish({ ok = false, reason = "wifi_error" })
            end
        end
        UIManager:scheduleIn(retry_delay, wifi_retry_fn)
    end

    scheduleWifiRetry()
end

local function runPeriodicSync(self)
    if not self._health_check_active then return end
    if not self.periodic_sync_enabled then return end

    if self._quick_sync_active then
        self:_scheduleNextPeriodicSync()
        return
    end

    local finished = false
    -- Function-reference timer (see runQuickSync for the rationale): storing
    -- the scheduleIn return value made unschedule a no-op.
    local wifi_retry_fn = nil
    local wifi_lease = nil

    local function acquirePeriodicWifiLease()
        if not wifi_lease then
            wifi_lease = Guard:acquire("periodic_sync_wifi", {
                wifi = {
                    release = function()
                        self:_periodicSyncWifiDone()
                    end,
                },
            })
        end
    end

    local function finish(disable_wifi_after)
        if finished then return end
        finished = true
        self._quick_sync_active = false
        if wifi_retry_fn then
            UIManager:unschedule(wifi_retry_fn)
            wifi_retry_fn = nil
        end
        if disable_wifi_after and wifi_lease then
            wifi_lease:release()
            wifi_lease = nil
        elseif disable_wifi_after then
            self:_periodicSyncWifiDone()
        end
        self:_scheduleNextPeriodicSync()
    end

    -- Absolute fallback timer — same race as runQuickSync (see 130 s timer there).
    -- NetworkMgr:enableWifi() silently drops its callback when
    -- pending_connectivity_check is already true.  If that race hits during the
    -- WiFi retry loop, scheduleWifiRetry() is never rescheduled, finish() is never
    -- called, _quick_sync_active stays true for the session, and
    -- _scheduleNextPeriodicSync() never fires — periodic sync is dead with no error.
    --
    -- Wrapper pattern: save the original finish, redefine finish to cancel the
    -- timer first, then call through.  Every existing exit path calls the same
    -- finish() it always did and now implicitly cancels the timer too.
    -- The timer itself calls the pre-wrap _finish_orig to avoid any circularity.
    --
    -- 490 s = 480 s wifi window + 10 s margin.
    local _finish_orig = finish
    local abs_timeout_fn
    abs_timeout_fn = function()
        if abs_timeout_fn then
            abs_timeout_fn = nil
            logger.warn("[Syncthing] Periodic sync: absolute 490 s safety timeout fired")
            _finish_orig(true)   -- true = disable_wifi_after, same as normal wifi-timeout path
        end
    end
    UIManager:scheduleIn(490, abs_timeout_fn)
    finish = function(disable_wifi_after)
        if abs_timeout_fn then
            UIManager:unschedule(abs_timeout_fn)
            abs_timeout_fn = nil
        end
        _finish_orig(disable_wifi_after)
    end

    if not self:_chargingConditionMet() then
        finish(false)
        return
    end

    if not self:binaryExists() then
        self:showNotification(_("Periodic sync skipped: Syncthing is not installed."), 5)
        finish(false)
        return
    end

    if self:isRunning() then
        -- Syncthing is already running; just rescan.  Skip if a manual Quick
        -- Sync is active (_quick_sync_active is true) to avoid duplicate scans.
        if not self._quick_sync_active then
            pcall(function() self:syncNow(nil, true) end)
        end
        finish(false)
        return
    end

    self._quick_sync_active = true
    local sync_started = false

    local function start_periodic_quick_sync(disable_wifi_after)
        if finished or sync_started then return end
        sync_started = true
        self._silentStart = true
        self:_startQuickSync(function()
            finish(disable_wifi_after)
        end, nil, { silent = true })
    end

    if hasNetwork() then
        start_periodic_quick_sync(false)
        return
    end

    -- Exponential backoff for Wi‑Fi
    local retry_delay = 30
    local retry_start_time = nil

    local function scheduleWifiRetry()
        if finished or sync_started then return end
        if not retry_start_time then
            retry_start_time = time.to_s(time.now())
        end
        local elapsed = time.to_s(time.now()) - retry_start_time
        if elapsed + retry_delay > 480 then
            logger.warn("[Syncthing] Periodic sync aborted: Wi‑Fi timeout after " .. string.format("%.0f", elapsed) .. "s")
            self:showNotification(_("Periodic sync skipped — network unavailable."), 5)
            finish(true)
            return
        end
        logger.info("[Syncthing] Periodic sync: Wi‑Fi retry in " .. retry_delay .. "s")
        wifi_retry_fn = function()
            if finished or sync_started then return end
            acquirePeriodicWifiLease()
            local ok_enable, err_enable = pcall(function()
                NetworkMgr:enableWifi(function()
                if finished or sync_started then return end
                if not hasNetwork() then
                    retry_delay = math.min(retry_delay * 2, 240)
                    scheduleWifiRetry()
                    return
                end
                wifi_retry_fn = nil
                start_periodic_quick_sync(true)
                end, false)
            end)
            if not ok_enable then
                logger.warn("[Syncthing] Periodic sync: enableWifi failed: " .. tostring(err_enable))
                finish(true)
            end
        end
        UIManager:scheduleIn(retry_delay, wifi_retry_fn)
    end

    scheduleWifiRetry()
end

local function runSuspendStop(self)
    -- Clear the notification queue so they don't pop up after waking up
    if self._drain_timer then
        UIManager:unschedule(self._drain_timer)
        self._drain_timer = nil
    end
    self._notification_queue  = nil
    self._notification_active = false
    if self:isRunning() then
        G_reader_settings:saveSetting("syncthing_was_running", true)
        self._was_running_before_suspend = true
        runAutoStop(self, "suspend")
    else
        G_reader_settings:saveSetting("syncthing_was_running", false)
        self._was_running_before_suspend = false
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Startup reconciler — keep the plugin's belief about the daemon in sync
-- with reality at the moments where drift is most likely (init / resume /
-- menu open). It re-derives the running state from a FRESH probe (not the
-- ≤5 s is_running cache) and clears a stale start-failure flag if the
-- daemon is in fact up. It performs NO lifecycle action: starting/stopping
-- stays with runAutoStart/runAutoStop and the suspend/resume/network
-- handlers, so the reconciler can never fight them.
-- ─────────────────────────────────────────────────────────────────────
local function reconcile(self, trigger)
    self:_invalidateProcess()          -- drop the cached is_running value
    local running = self:isRunning()   -- fresh /proc probe
    if running and G_reader_settings:isTrue("syncthing_start_failed") then
        -- Daemon is actually up, so the failure flag (and the Legacy
        -- escape-hatch hint it drives in the menu) is stale — clear it.
        G_reader_settings:delSetting("syncthing_start_failed")
    end
    logger.info(string.format("[Syncthing] reconcile(%s): running=%s",
        tostring(trigger), tostring(running)))
    return running
end

local function runResumeRestore(self)
    reconcile(self, "resume")
    if hasNetwork() and self:_chargingConditionMet() then
        if self._was_running_before_suspend and not self:isRunning() then
            runAutoStart(self, "resume_restore")
        elseif self.periodic_sync_enabled and not self:isRunning() then
            runPeriodicSync(self)
        end
        -- Clear the flag only when we had a chance to act on it (Wi-Fi was up).
        -- If Wi-Fi is offline at resume time we leave the flag set so that
        -- runNetworkConnected() can still restore Syncthing when connectivity
        -- returns.  Without this, the flag was cleared unconditionally and the
        -- "was running before suspend" intent was lost for the rest of the
        -- session whenever the device resumed without a network connection.
        self._was_running_before_suspend = false
    end
    -- When offline at resume we intentionally DO NOT clear the flag here.
    -- runNetworkConnected() calls runAutoStart when auto_start_always is set;
    -- for the "was running" case it is runResumeRestore's job, but only once
    -- Wi-Fi is actually available.  The flag is also cleared by runSuspendStop
    -- on the next suspend, so it cannot accumulate across cycles.
end

local function runNetworkConnected(self)
    -- Restore Syncthing if it was running before a suspend that completed
    -- while Wi-Fi was offline.
    if self._was_running_before_suspend and not self:isRunning()
            and self:_chargingConditionMet() then
        self._was_running_before_suspend = false
        runAutoStart(self, "resume_restore_wifi_late")
        return
    end
    if self.auto_start_always then
        runAutoStart(self, "network_connected")
    end
end

local function runNetworkDisconnected(self)
    runAutoStop(self, "network")
end

local function runCharging(self)
    if self.auto_start_always then
        runAutoStart(self, "charging")
    end
end

local function runCloseStop(self)
    if self:isRunning() then
        G_reader_settings:saveSetting("syncthing_was_running", false)
        runAutoStop(self, "close")
    end
end

local function runSyncCompleted(self, _event)
    if not G_reader_settings:isTrue("syncthing_auto_merge_conflicts") then
        return
    end
    if type(self.findConflicts) ~= "function"
            or type(self.autoMergeReadingProgress) ~= "function" then
        return
    end

    local ok_conflicts, conflicts = pcall(self.findConflicts, self)
    if not ok_conflicts then
        logger.warn("[Syncthing] auto-merge conflict scan failed: " .. tostring(conflicts))
        return
    end
    if type(conflicts) ~= "table" or #conflicts == 0 then return end

    local ok_merge, stats = pcall(self.autoMergeReadingProgress, self, conflicts)
    if not ok_merge then
        logger.warn("[Syncthing] auto-merge failed: " .. tostring(stats))
        self:showNotification(_("Auto-merge reading progress failed."), 5)
        return
    end
    if type(stats) ~= "table" then return end

    local merged = tonumber(stats.merged) or 0
    local failed = tonumber(stats.failed) or 0
    if failed > 0 then
        self:showNotification(T(_("Auto-merge reading progress: %1 merged, %2 failed."), merged, failed), 5)
    elseif merged > 0 then
        self:showNotification(T(_("Auto-merged reading progress: %1 conflict(s)."), merged), 5)
    end
end

return {
    runManualStart       = runManualStart,
    runManualStop        = runManualStop,
    runManualToggle      = runManualToggle,
    runAutoStart         = runAutoStart,
    runAutoStop          = runAutoStop,
    runQuickSync         = runQuickSync,
    runPeriodicSync      = runPeriodicSync,
    runSuspendStop       = runSuspendStop,
    runResumeRestore     = runResumeRestore,
    runNetworkConnected  = runNetworkConnected,
    runNetworkDisconnected = runNetworkDisconnected,
    runCharging          = runCharging,
    runCloseStop         = runCloseStop,
    runSyncCompleted     = runSyncCompleted,
    reconcile            = reconcile,

    -- Compatibility entry points used by menus, dispatcher, and public API.
    quickSync            = runQuickSync,
    onToggleSyncthingServer = runManualToggle,
    _onPeriodicSyncTick  = runPeriodicSync,
    onSuspend            = runSuspendStop,
    onResume             = runResumeRestore,
    onNetworkConnected   = runNetworkConnected,
    onNetworkDisconnected = runNetworkDisconnected,
    onCharging           = runCharging,
    onSyncthingSyncCompleted = runSyncCompleted,
}
