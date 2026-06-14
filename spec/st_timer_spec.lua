local Mock = require("spec.spec_helper")

local function installTimerMethods(plugin)
    local UIManager = require("ui/uimanager")

    function plugin:_startPeriodicSyncTimer()
        if not self.periodic_sync_enabled then return end
        self:_scheduleNextPeriodicSync()
    end

    function plugin:_scheduleNextPeriodicSync()
        if not self.periodic_sync_enabled then return end
        local interval_seconds = self.periodic_sync_interval_min * 60
        if self._periodic_sync_timer then
            UIManager:unschedule(self._periodic_sync_timer)
            self._periodic_sync_timer = nil
        end
        self._next_periodic_sync_at = os.time() + interval_seconds
        self._periodic_sync_timer = function()
            self._periodic_sync_timer = nil
            if self.periodic_sync_enabled then
                self:_onPeriodicSyncTick()
            end
        end
        UIManager:scheduleIn(interval_seconds, self._periodic_sync_timer)
    end

    function plugin:_stopPeriodicSyncTimer()
        if self._periodic_sync_timer then
            UIManager:unschedule(self._periodic_sync_timer)
            self._periodic_sync_timer = nil
        end
    end
end

describe("periodic sync timer lifecycle", function()
    before_each(function()
        Mock.reset()
    end)

    it("enabling then disabling periodic sync cancels the scheduled timer", function()
        package.preload["st_api_public"] = nil
        package.loaded["st_api_public"] = nil
        local public_api = require("st_api_public")

        local plugin = {
            periodic_sync_enabled = false,
            periodic_sync_interval_min = 30,
            _onPeriodicSyncTick = function() end,
        }
        installTimerMethods(plugin)
        public_api.buildPublicAPI(plugin)

        assert.is_true(_G.KOSyncthingPlusAPI.control.setPeriodicSyncEnabled(true))
        local timer = plugin._periodic_sync_timer
        assert.is_function(timer)

        assert.is_true(_G.KOSyncthingPlusAPI.control.setPeriodicSyncEnabled(false))
        assert.is_nil(plugin._periodic_sync_timer)

        local found = false
        for _, scheduled in ipairs(Mock.state.timers) do
            if scheduled.fn == timer then
                found = true
                assert.is_true(scheduled.cancelled)
            end
        end
        assert.is_true(found)
    end)
end)
