local Mock = require("spec.spec_helper")

local function newPlugin(overrides)
    Mock.reset()
    local sync = require("st_sync")
    local plugin = {
        running = false,
        stopped = false,
        _sync_flow_counter = 0,
        _quick_sync_active = false,
        _notifiers = nil,
        binaryExists = function() return true end,
        isRunning = function(self) return self.running end,
        start = function(self, cb)
            self.running = true
            if cb then cb() end
        end,
        stop = function(self, cb)
            self.stopped = true
            self.running = false
            if cb then cb() end
        end,
        showNotification = function(_, text)
            table.insert(Mock.state.notifications, text)
        end,
        getDeviceStats = function() return {} end,
        _cacheInvalidate = function() end,
        _invalidateConflictCache = function() end,
        _invalidateFolders = function() end,
    }
    for name, fn in pairs(sync) do
        plugin[name] = fn
    end
    for name, value in pairs(overrides or {}) do
        plugin[name] = value
    end
    return plugin
end

describe("st_sync Quick Sync", function()
    it("fails when db/scan returns an error for all folders", function()
        local result
        local plugin = newPlugin({
            getConfig = function()
                return {
                    folders = {
                        { id = "books", path = "/books" },
                        { id = "notes", path = "/notes" },
                    },
                }
            end,
            scanFolder = function()
                return { ok = false, error = "scan failed" }
            end,
        })
        Mock.state.free_space.default = 1024 * 1024 * 1024

        plugin:_startQuickSync(function(r) result = r end)
        Mock.runTimers()

        assert.is_false(result.ok)
        assert.are.equal("no_folders", result.reason)
        assert.is_true(plugin.stopped)
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
    end)

    it("aborts before scanning when a folder filesystem has less than 100 MB free", function()
        local result
        local scan_calls = 0
        local plugin = newPlugin({
            getConfig = function()
                return { folders = { { id = "books", path = "/books" } } }
            end,
            scanFolder = function()
                scan_calls = scan_calls + 1
                return { ok = true }
            end,
        })
        Mock.state.free_space["/books"] = 99 * 1024 * 1024

        plugin:_startQuickSync(function(r) result = r end)
        Mock.runTimers()

        assert.is_false(result.ok)
        assert.are.equal("low_disk_space", result.reason)
        assert.are.equal(0, scan_calls)
        assert.is_true(plugin.stopped)
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
    end)

    it("detects folder errors while waiting for idle", function()
        local result
        local plugin = newPlugin({
            getConfig = function()
                return { folders = { { id = "books", path = "/books" } } }
            end,
            scanFolder = function()
                return { ok = true }
            end,
            getFolderStatus = function()
                return {
                    state = "error",
                    errors = 1,
                    needTotalItems = 0,
                    needBytes = 0,
                }
            end,
        })
        Mock.state.free_space["/books"] = 1024 * 1024 * 1024

        plugin:_startQuickSync(function(r) result = r end)
        Mock.runTimers(20)

        assert.is_false(result.ok)
        assert.are.equal("folder_errors", result.reason)
        assert.is_true(plugin.stopped)
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
    end)
end)
