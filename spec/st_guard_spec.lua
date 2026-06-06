-- st_guard_spec.lua – comprehensive tests for the named resource lease manager.
-- Covers: acquire, release, releaseAll, protect (both Lease and Guard forms),
-- standby/wakelock/wifi resource lifecycle, idempotent re-acquire, error paths.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function freshGuard()
    -- Reset so module-level _leases table is clean.
    package.loaded["st_guard"] = nil
    return require("st_guard")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: acquire / release basics
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard:acquire + release", function()
    before_each(function()
        Mock.reset()
    end)

    it("returns a Lease with released=false and the correct name", function()
        local G = freshGuard()
        local lease = G:acquire("test_lease", {})
        assert.is_false(lease.released)
        assert.are.equal("test_lease", lease.name)
    end)

    it("Guard:active returns the live lease and nil after release", function()
        local G = freshGuard()
        local lease = G:acquire("active_test", {})
        assert.are.equal(lease, G:active("active_test"))
        lease:release()
        assert.is_nil(G:active("active_test"))
    end)

    it("Guard:release(name) releases by name", function()
        local G = freshGuard()
        G:acquire("named_release", {})
        G:release("named_release")
        assert.is_nil(G:active("named_release"))
    end)

    it("Guard:release(name) returns true for unknown lease (no-op)", function()
        local G = freshGuard()
        assert.is_true(G:release("no_such_lease"))
    end)

    it("Lease:release is idempotent — calling twice does not double-decrement standby", function()
        local G = freshGuard()
        local lease = G:acquire("idem", { standby = true })
        assert.are.equal(1, Mock.state.standby)
        lease:release()
        lease:release()   -- second call must be a no-op
        assert.are.equal(0, Mock.state.standby)
    end)

    it("errors when name is empty string", function()
        local G = freshGuard()
        assert.has_error(function() G:acquire("", {}) end)
    end)

    it("errors when name is not a string", function()
        local G = freshGuard()
        assert.has_error(function() G:acquire(42, {}) end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: standby resource
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard standby resource", function()
    before_each(function()
        Mock.reset()
    end)

    it("preventStandby called on acquire, allowStandby called on release", function()
        local G = freshGuard()
        assert.are.equal(0, Mock.state.standby)
        local lease = G:acquire("standby_test", { standby = true })
        assert.are.equal(1, Mock.state.standby)
        lease:release()
        assert.are.equal(0, Mock.state.standby)
    end)

    it("two leases each hold their own standby token", function()
        local G = freshGuard()
        local a = G:acquire("s_a", { standby = true })
        local b = G:acquire("s_b", { standby = true })
        assert.are.equal(2, Mock.state.standby)
        a:release()
        assert.are.equal(1, Mock.state.standby)
        b:release()
        assert.are.equal(0, Mock.state.standby)
    end)

    it("no standby resource: counter stays at zero", function()
        local G = freshGuard()
        local lease = G:acquire("no_standby", {})
        lease:release()
        assert.are.equal(0, Mock.state.standby)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: wakelock resource
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard wakelock resource", function()
    before_each(function()
        Mock.reset()
    end)

    it("preventSuspend on acquire, allowSuspend on release", function()
        local G = freshGuard()
        assert.are.equal(0, Mock.state.wakelock)
        local lease = G:acquire("wl_test", { wakelock = true })
        assert.are.equal(1, Mock.state.wakelock)
        lease:release()
        assert.are.equal(0, Mock.state.wakelock)
    end)

    it("standby + wakelock together both balanced on release", function()
        local G = freshGuard()
        local lease = G:acquire("sw_both", { standby = true, wakelock = true })
        assert.are.equal(1, Mock.state.standby)
        assert.are.equal(1, Mock.state.wakelock)
        lease:release()
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: Wi-Fi resource
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard wifi resource", function()
    before_each(function()
        Mock.reset()
    end)

    it("wifi=true enables wifi when offline on acquire", function()
        Mock.state.wifi_online = false
        local G = freshGuard()
        G:acquire("wifi_enable_test", { wifi = true })
        assert.are.equal(1, Mock.state.wifi_enable_calls)
    end)

    it("wifi=true skips enableWifi when already online", function()
        Mock.state.wifi_online = true
        local G = freshGuard()
        G:acquire("wifi_already_online", { wifi = true })
        assert.are.equal(0, Mock.state.wifi_enable_calls)
    end)

    it("wifi with disable_on_release=true calls disableWifi on release", function()
        Mock.state.wifi_online = false
        local G = freshGuard()
        local lease = G:acquire("wifi_disable_test", {
            wifi = { disable_on_release = true },
        })
        lease:release()
        assert.are.equal(1, Mock.state.wifi_disable_calls)
    end)

    it("custom release function called instead of default disableWifi", function()
        local custom_called = false
        local G = freshGuard()
        local lease = G:acquire("wifi_custom_release", {
            wifi = {
                release = function() custom_called = true end,
            },
        })
        lease:release()
        assert.is_true(custom_called)
        assert.are.equal(0, Mock.state.wifi_disable_calls)
    end)

    it("wifi=true + was online: disable_on_release defaults to false", function()
        Mock.state.wifi_online = true
        local G = freshGuard()
        local lease = G:acquire("wifi_no_disable", { wifi = true })
        lease:release()
        -- was already online, so enabling it ourselves would be wrong; no disable
        assert.are.equal(0, Mock.state.wifi_disable_calls)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: re-acquire replaces prior lease
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard re-acquire", function()
    before_each(function()
        Mock.reset()
    end)

    it("second acquire with same name releases the first and marks it released", function()
        local G = freshGuard()
        local first  = G:acquire("replace_test", { standby = true })
        local second = G:acquire("replace_test", { standby = true })
        assert.is_true(first.released)
        assert.is_false(second.released)
        -- first released its standby, second holds one: net = 1
        assert.are.equal(1, Mock.state.standby)
        second:release()
        assert.are.equal(0, Mock.state.standby)
    end)

    it("Guard:active returns the replacement, not the displaced lease", function()
        local G = freshGuard()
        local first  = G:acquire("active_replace", {})
        local second = G:acquire("active_replace", {})
        assert.are.equal(second, G:active("active_replace"))
        assert.are_not.equal(first, G:active("active_replace"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: releaseAll
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard:releaseAll", function()
    before_each(function()
        Mock.reset()
    end)

    it("releases all active leases and balances standby", function()
        local G = freshGuard()
        G:acquire("ra_a", { standby = true })
        G:acquire("ra_b", { standby = true })
        G:acquire("ra_c", { wakelock = true })
        assert.are.equal(2, Mock.state.standby)
        assert.are.equal(1, Mock.state.wakelock)
        G:releaseAll()
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
        assert.is_nil(G:active("ra_a"))
        assert.is_nil(G:active("ra_b"))
        assert.is_nil(G:active("ra_c"))
    end)

    it("releaseAll on empty registry is a safe no-op", function()
        local G = freshGuard()
        assert.has_no.errors(function() G:releaseAll() end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: Guard:protect and Lease:protect
-- ─────────────────────────────────────────────────────────────────────────────

describe("Guard:protect + Lease:protect", function()
    before_each(function()
        Mock.reset()
    end)

    it("Guard:protect runs fn and releases resources on success", function()
        local G = freshGuard()
        local ran = false
        G:protect("protect_ok", { standby = true }, function()
            ran = true
            assert.are.equal(1, Mock.state.standby)
        end)
        assert.is_true(ran)
        assert.are.equal(0, Mock.state.standby)
        assert.is_nil(G:active("protect_ok"))
    end)

    it("Guard:protect releases resources even when fn raises (re-raises error)", function()
        local G = freshGuard()
        local ok = pcall(function()
            G:protect("protect_err", { standby = true, wakelock = true }, function()
                error("boom inside protect")
            end)
        end)
        assert.is_false(ok)
        assert.are.equal(0, Mock.state.standby)
        assert.are.equal(0, Mock.state.wakelock)
        assert.is_nil(G:active("protect_err"))
    end)

    it("Lease:protect forwards return values on success", function()
        local G = freshGuard()
        local lease = G:acquire("ret_test", {})
        local a, b = lease:protect(function() return 42, "hello" end)
        assert.are.equal(42, a)
        assert.are.equal("hello", b)
    end)

    it("Lease:protect re-raises the original error message", function()
        local G = freshGuard()
        local lease = G:acquire("reraise_test", {})
        local ok, err = pcall(function()
            lease:protect(function() error("sentinel_error") end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("sentinel_error"))
    end)
end)
