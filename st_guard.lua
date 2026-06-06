-- st_guard.lua - Named resource lease manager.
--
-- KOReader runs this plugin on a single Lua thread, but lifecycle flows are
-- still callback-heavy. A named lease gives each flow one idempotent release
-- point for standby, Wi-Fi and wakelock resources.

local UIManager  = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device     = require("device")
local logger     = require("logger")

local Guard = {
    _leases = {},
}

local Lease = {}
Lease.__index = Lease

local function logWarn(message)
    if logger and logger.warn then
        logger.warn("[Syncthing] Guard: " .. tostring(message))
    end
end

local function safeCall(label, fn)
    if type(fn) ~= "function" then return false end
    local ok, err = pcall(fn)
    if not ok then
        logWarn(label .. " failed: " .. tostring(err))
        return false
    end
    return true
end

local function addRelease(lease, label, release_fn)
    table.insert(lease._release_stack, {
        label = label,
        fn = release_fn,
    })
end

local function acquireStandby(lease)
    if not UIManager or type(UIManager.preventStandby) ~= "function" then
        return
    end

    if safeCall("preventStandby", function()
        UIManager:preventStandby()
    end) then
        addRelease(lease, "allowStandby", function()
            if UIManager and type(UIManager.allowStandby) == "function" then
                UIManager:allowStandby()
            end
        end)
    end
end

local function acquireWakelock(lease)
    local powerd = Device and Device.powerd
    if not powerd or type(powerd.preventSuspend) ~= "function" then
        return
    end

    if safeCall("preventSuspend", function()
        powerd:preventSuspend()
    end) then
        addRelease(lease, "allowSuspend", function()
            if Device and Device.powerd
                    and type(Device.powerd.allowSuspend) == "function" then
                Device.powerd:allowSuspend()
            end
        end)
    end
end

local function normalizeWifiSpec(spec)
    if spec == true then
        return {
            enable = true,
            disable_on_release = nil,
        }
    end
    if type(spec) == "table" then
        return spec
    end
    return nil
end

local function acquireWifi(lease, spec)
    spec = normalizeWifiSpec(spec)
    if not spec or not NetworkMgr then return end

    local was_online = false
    if type(NetworkMgr.isOnline) == "function" then
        local ok, online = pcall(function() return NetworkMgr:isOnline() end)
        was_online = ok and online == true
    end

    if spec.enable == true and not was_online
            and type(NetworkMgr.enableWifi) == "function" then
        safeCall("enableWifi", function()
            NetworkMgr:enableWifi(spec.callback or function() end, false)
        end)
    end

    local function defaultRelease()
        if type(NetworkMgr.disableWifi) == "function" then
            NetworkMgr:disableWifi()
        end
    end

    local release_fn = spec.release or spec.release_fn
    local should_disable = spec.disable_on_release
    if should_disable == nil then
        should_disable = spec.enable == true and not was_online
    end

    addRelease(lease, "wifi", function()
        if release_fn then
            release_fn()
        elseif should_disable then
            defaultRelease()
        end
    end)
end

local function newLease(name)
    return setmetatable({
        name = name,
        released = false,
        _release_stack = {},
    }, Lease)
end

function Lease:release()
    if self.released then return true end
    self.released = true

    if Guard._leases[self.name] == self then
        Guard._leases[self.name] = nil
    end

    local ok_all = true
    for i = #self._release_stack, 1, -1 do
        local item = self._release_stack[i]
        local ok = safeCall(item.label, item.fn)
        ok_all = ok_all and ok
    end
    return ok_all
end

function Lease:protect(fn, ...)
    local args = { ... }
    local result = {
        xpcall(function()
            return fn(unpack(args))
        end, debug.traceback)
    }
    self:release()
    if not result[1] then
        error(result[2], 0)
    end
    table.remove(result, 1)
    return unpack(result)
end

function Guard:acquire(name, resources)
    if type(name) ~= "string" or name == "" then
        error("Guard:acquire requires a non-empty lease name", 2)
    end

    local prior = self._leases[name]
    if prior then
        prior:release()
    end

    resources = resources or {}
    local lease = newLease(name)
    self._leases[name] = lease

    if resources.standby then
        acquireStandby(lease)
    end
    if resources.wifi then
        acquireWifi(lease, resources.wifi)
    end
    if resources.wakelock then
        acquireWakelock(lease)
    end

    return lease
end

function Guard:release(name)
    local lease = self._leases[name]
    if not lease then return true end
    return lease:release()
end

function Guard:active(name)
    return self._leases[name]
end

function Guard:releaseAll()
    local leases = {}
    for _, lease in pairs(self._leases) do
        table.insert(leases, lease)
    end
    for _, lease in ipairs(leases) do
        lease:release()
    end
end

function Guard:protect(name, resources, fn, ...)
    local lease = self:acquire(name, resources)
    return lease:protect(fn, ...)
end

return Guard
