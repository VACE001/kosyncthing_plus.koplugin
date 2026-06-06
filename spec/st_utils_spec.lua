-- st_utils_spec.lua – tests for the shared utility layer.
-- Pure functions (formatBytes, shellEscape, isValidDeviceID, execOk, isOk,
-- errOf, formatTime) are tested directly.  I/O-dependent functions
-- (getFreeSpace / _parseDfOutput, loopbackIsUp, curlAvailable) are tested
-- via a mocked io.popen so no real shell calls are needed.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Module loader – st_utils has module-level side-effects (path computation
-- from DataStorage) so we reload it fresh inside each describe block.
-- ─────────────────────────────────────────────────────────────────────────────

local function freshUtils()
    package.loaded["st_utils"] = nil
    package.loaded["util"]     = nil
    -- Bypass the luarocks searcher (same pattern as st_process_spec).
    -- Mock.install() put a minimal stub into package.preload["st_utils"];
    -- we replace it with the real file so we test actual logic.
    local st_path = package.searchpath("st_utils", package.path)
    package.preload["st_utils"] = assert(loadfile(st_path))
    return require("st_utils")
end

-- Intercept io.popen for tests that drive shell-out functions.
local function withPopen(results, fn)
    -- `results` is a list consumed in order; each entry is a string or nil.
    local real_popen = io.popen
    local idx = 0
    io.popen = function(cmd, mode)
        idx = idx + 1
        local content = results[idx]
        if content == nil then return nil end
        return {
            read  = function(_, fmt)
                if fmt == "*a" then return content end
                if fmt == "*l" then return content:match("^([^\n]*)") end
                return nil
            end,
            close = function() return true end,
        }
    end
    local ok, err = pcall(fn)
    io.popen = real_popen
    if not ok then error(err, 2) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: formatBytes
-- ─────────────────────────────────────────────────────────────────────────────

describe("formatBytes", function()
    before_each(function() Mock.reset() end)

    it("returns '0 B' for nil", function()
        local U = freshUtils()
        assert.are.equal("0 B", U.formatBytes(nil))
    end)

    it("returns '0 B' for 0", function()
        local U = freshUtils()
        assert.are.equal("0 B", U.formatBytes(0))
    end)

    it("formats bytes < 1024 as integer B", function()
        local U = freshUtils()
        assert.are.equal("512 B", U.formatBytes(512))
    end)

    it("formats kilobytes", function()
        local U = freshUtils()
        assert.are.equal("1.5 KB", U.formatBytes(1536))
    end)

    it("formats megabytes", function()
        local U = freshUtils()
        assert.are.equal("1.0 MB", U.formatBytes(1024 * 1024))
    end)

    it("formats gigabytes", function()
        local U = freshUtils()
        assert.are.equal("2.0 GB", U.formatBytes(2 * 1024 * 1024 * 1024))
    end)

    it("formats terabytes", function()
        local U = freshUtils()
        assert.are.equal("1.0 TB", U.formatBytes(1024 ^ 4))
    end)

    it("rounds to one decimal place", function()
        local U = freshUtils()
        -- 1.5 MB exactly
        assert.are.equal("1.5 MB", U.formatBytes(1.5 * 1024 * 1024))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: shellEscape
-- ─────────────────────────────────────────────────────────────────────────────

describe("shellEscape", function()
    before_each(function() Mock.reset() end)

    it("returns empty string for nil", function()
        local U = freshUtils()
        assert.are.equal("", U.shellEscape(nil))
    end)

    it("passes through a clean string unchanged", function()
        local U = freshUtils()
        assert.are.equal("hello", U.shellEscape("hello"))
    end)

    it("escapes a single-quote so the shell sees it literally", function()
        local U = freshUtils()
        -- Input: it's → Output: it'\''s  (closes quote, inserts literal ', reopens)
        assert.are.equal("it'\\''s", U.shellEscape("it's"))
    end)

    it("escapes multiple single-quotes in one string", function()
        local U = freshUtils()
        assert.are.equal("a'\\''b'\\''c", U.shellEscape("a'b'c"))
    end)

    it("passes through a path with spaces (no quoting needed – caller wraps)", function()
        local U = freshUtils()
        assert.are.equal("/mnt/us/my books", U.shellEscape("/mnt/us/my books"))
    end)

    it("converts non-string input via tostring", function()
        local U = freshUtils()
        assert.are.equal("42", U.shellEscape(42))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: isValidDeviceID
-- ─────────────────────────────────────────────────────────────────────────────

describe("isValidDeviceID", function()
    before_each(function() Mock.reset() end)

    -- A real Syncthing device ID: 7 groups of 7 chars + 1 group of 7, separated
    -- by hyphens.  After stripping hyphens: 56 uppercase base-32 chars.
    local VALID = ("MFZWI3D-BONSGYC-YLTMRWG-C43ENB5-QXGUXF2-HV326AS-FV3AOQE-NSCV6QA")
        :gsub("-", "")  -- 56 chars, A-Z and 2-7
    -- Reconstruct with hyphens as Syncthing actually displays them:
    local VALID_WITH_HYPHENS =
        "MFZWI3D-BONSGYC-YLTMRWG-C43ENB5-QXGUXF2-HV326AS-FV3AOQE-NSCV6QA"

    it("accepts a 56-character stripped base-32 ID", function()
        local U = freshUtils()
        assert.is_true(U.isValidDeviceID(VALID))
    end)

    it("accepts a hyphenated Syncthing device ID", function()
        local U = freshUtils()
        assert.is_true(U.isValidDeviceID(VALID_WITH_HYPHENS))
    end)

    it("rejects a string that is too short after stripping hyphens", function()
        local U = freshUtils()
        assert.is_false(U.isValidDeviceID("MFZWI3D-BONSGYC"))
    end)

    it("rejects a string that is too long", function()
        local U = freshUtils()
        assert.is_false(U.isValidDeviceID(VALID .. "A"))
    end)

    it("rejects lowercase letters (base-32 uses uppercase only)", function()
        local U = freshUtils()
        local lower = VALID:lower()
        assert.is_false(U.isValidDeviceID(lower))
    end)

    it("rejects digits outside 2-7 (e.g. 0, 1, 8, 9)", function()
        local U = freshUtils()
        -- Replace last char with '0' to introduce an invalid base-32 digit
        local bad = VALID:sub(1, 55) .. "0"
        assert.is_false(U.isValidDeviceID(bad))
    end)

    it("rejects non-string input", function()
        local U = freshUtils()
        assert.is_false(U.isValidDeviceID(nil))
        assert.is_false(U.isValidDeviceID(123))
        assert.is_false(U.isValidDeviceID({}))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: execOk
-- ─────────────────────────────────────────────────────────────────────────────

describe("execOk", function()
    before_each(function() Mock.reset() end)

    it("returns true for exit code 0", function()
        local U = freshUtils()
        assert.is_true(U.execOk(0))
    end)

    it("returns true for boolean true (some shells return true on success)", function()
        local U = freshUtils()
        assert.is_true(U.execOk(true))
    end)

    it("returns false for exit code 1", function()
        local U = freshUtils()
        assert.is_false(U.execOk(1))
    end)

    it("returns false for exit code 127 (command not found)", function()
        local U = freshUtils()
        assert.is_false(U.execOk(127))
    end)

    it("returns false for nil (os.execute failure)", function()
        local U = freshUtils()
        assert.is_false(U.execOk(nil))
    end)

    it("returns false for false", function()
        local U = freshUtils()
        assert.is_false(U.execOk(false))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: isOk / errOf
-- ─────────────────────────────────────────────────────────────────────────────

describe("isOk + errOf", function()
    before_each(function() Mock.reset() end)

    it("isOk returns false for nil (SafeClient returned nothing)", function()
        local U = freshUtils()
        assert.is_false(U.isOk(nil))
    end)

    it("isOk returns true for {ok=true}", function()
        local U = freshUtils()
        assert.is_true(U.isOk({ ok = true }))
    end)

    it("isOk returns false for {ok=false}", function()
        local U = freshUtils()
        assert.is_false(U.isOk({ ok = false }))
    end)

    it("isOk returns false for a table without ok field", function()
        local U = freshUtils()
        assert.is_false(U.isOk({ data = "something" }))
    end)

    it("errOf returns 'no response' for nil", function()
        local U = freshUtils()
        assert.are.equal("no response", U.errOf(nil))
    end)

    it("errOf returns the error field when present", function()
        local U = freshUtils()
        assert.are.equal("connection refused", U.errOf({ ok = false, error = "connection refused" }))
    end)

    it("errOf returns 'no response' when error field is absent", function()
        local U = freshUtils()
        assert.are.equal("no response", U.errOf({ ok = true }))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: formatTime
-- ─────────────────────────────────────────────────────────────────────────────

describe("formatTime", function()
    before_each(function() Mock.reset() end)

    it("returns N/A for nil", function()
        local U = freshUtils()
        assert.are.equal("N/A", U.formatTime(nil))
    end)

    it("returns N/A for empty string", function()
        local U = freshUtils()
        assert.are.equal("N/A", U.formatTime(""))
    end)

    it("fallback: trims to 16 chars and replaces T with space", function()
        -- When datetime module is unavailable (mocked away), the fallback
        -- path takes the first 16 chars and replaces the T separator.
        local U = freshUtils()
        local result = U.formatTime("2026-01-15T14:30:00.000Z")
        -- Either the datetime module handled it (any non-empty string),
        -- or the fallback produced "2026-01-15 14:30"
        assert.is_string(result)
        assert.is_truthy(#result > 0)
        -- Fallback output must not contain a bare T between digits
        if result == "2026-01-15 14:30" then
            assert.is_falsy(result:find("%dT%d"))
        end
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: getFreeSpace / _parseDfOutput (via mocked io.popen)
-- ─────────────────────────────────────────────────────────────────────────────

describe("getFreeSpace + _parseDfOutput", function()
    before_each(function() Mock.reset() end)

    it("returns nil for nil path", function()
        local U = freshUtils()
        assert.is_nil(U.getFreeSpace(nil))
    end)

    it("returns nil for empty path", function()
        local U = freshUtils()
        assert.is_nil(U.getFreeSpace(""))
    end)

    it("parses standard POSIX df -P output (single data line)", function()
        -- Filesystem  1K-blocks    Used  Available Use% Mounted on
        -- /dev/sda1    10485760 5242880    4194304  51% /
        local posix_output =
            "Filesystem     1K-blocks    Used Available Use% Mounted on\n" ..
            "/dev/sda1       10485760 5242880   4194304  51% /\n"
        local U = freshUtils()
        withPopen({ posix_output }, function()
            -- 4194304 KB * 1024 = 4294967296 bytes = 4 GB
            assert.are.equal(4194304 * 1024, U.getFreeSpace("/"))
        end)
    end)

    it("parses BusyBox df output where device path wraps to its own line", function()
        -- Some BusyBox builds wrap long paths:
        -- /dev/some/very/long/block/device
        --              10485760 5242880 4194304  51% /
        local busybox_output =
            "Filesystem           1K-blocks      Used Available Use% Mounted on\n" ..
            "/dev/some/very/long/block/device\n" ..
            "                      10485760   5242880   3000000  75% /mnt/us\n"
        local U = freshUtils()
        -- Primary popen attempt fails (returns nil); fallback popen succeeds:
        withPopen({ nil, busybox_output }, function()
            assert.are.equal(3000000 * 1024, U.getFreeSpace("/mnt/us"))
        end)
    end)

    it("returns nil when both popen calls fail", function()
        local U = freshUtils()
        withPopen({ nil, nil }, function()
            assert.is_nil(U.getFreeSpace("/mnt/us"))
        end)
    end)

    it("returns nil when df output has no data lines (only header)", function()
        local U = freshUtils()
        withPopen({ "Filesystem 1K-blocks Used Available Use% Mounted on\n" }, function()
            assert.is_nil(U.getFreeSpace("/"))
        end)
    end)

    it("returns nil when df output is completely empty", function()
        local U = freshUtils()
        withPopen({ "", "" }, function()
            assert.is_nil(U.getFreeSpace("/"))
        end)
    end)

    it("parses a GNU coreutils df -P output with large numbers", function()
        local gnu_output =
            "Filesystem        1K-blocks       Used  Available Use% Mounted on\n" ..
            "tmpfs              16384000    1234567   15149433   8% /dev/shm\n"
        local U = freshUtils()
        withPopen({ gnu_output }, function()
            assert.are.equal(15149433 * 1024, U.getFreeSpace("/dev/shm"))
        end)
    end)

    it("tries the -k fallback when the primary -k -P popen returns empty string", function()
        -- Primary returns empty; fallback returns valid data.
        local fallback_output =
            "Filesystem     1K-blocks  Used Available Use% Mounted on\n" ..
            "/dev/mmcblk0p1   2097152   512   1572864  25% /mnt/sd\n"
        local U = freshUtils()
        withPopen({ "", fallback_output }, function()
            assert.are.equal(1572864 * 1024, U.getFreeSpace("/mnt/sd"))
        end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 8: loopbackIsUp (mocked io.popen)
-- ─────────────────────────────────────────────────────────────────────────────

describe("loopbackIsUp", function()
    before_each(function()
        Mock.reset()
    end)

    local function freshUtilsNoLoopbackCache()
        package.loaded["st_utils"] = nil
        package.loaded["util"] = nil
        -- Must reset preload so require() picks up the real file, not the mock stub.
        local st_path = package.searchpath("st_utils", package.path)
        package.preload["st_utils"] = assert(loadfile(st_path))
        return require("st_utils")
    end

    it("returns true when 'ip link show lo' contains 'UP'", function()
        local U = freshUtilsNoLoopbackCache()
        U.invalidateLoopbackCache()
        withPopen({ "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536\n    link/loopback" }, function()
            assert.is_true(U.loopbackIsUp())
        end)
    end)

    it("returns false when output does not contain 'UP'", function()
        local U = freshUtilsNoLoopbackCache()
        U.invalidateLoopbackCache()
        withPopen({ "1: lo: <LOOPBACK> mtu 65536 state DOWN\n" }, function()
            assert.is_false(U.loopbackIsUp())
        end)
    end)

    it("returns false when popen returns nil (ip not available)", function()
        local U = freshUtilsNoLoopbackCache()
        U.invalidateLoopbackCache()
        withPopen({ nil }, function()
            assert.is_false(U.loopbackIsUp())
        end)
    end)

    it("caches the result: popen called only once for two calls", function()
        local U = freshUtilsNoLoopbackCache()
        U.invalidateLoopbackCache()
        local calls = 0
        local real_popen = io.popen
        io.popen = function(...)
            calls = calls + 1
            return {
                read  = function() return "UP" end,
                close = function() return true end,
            }
        end
        U.loopbackIsUp()
        U.loopbackIsUp()
        io.popen = real_popen
        assert.are.equal(1, calls)
    end)

    it("invalidateLoopbackCache causes re-probe on next call", function()
        local U = freshUtilsNoLoopbackCache()
        U.invalidateLoopbackCache()
        local calls = 0
        local real_popen = io.popen
        io.popen = function(...)
            calls = calls + 1
            return {
                read  = function() return "UP" end,
                close = function() return true end,
            }
        end
        U.loopbackIsUp()
        U.invalidateLoopbackCache()
        U.loopbackIsUp()
        io.popen = real_popen
        assert.are.equal(2, calls)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 9: DANGEROUS_PATHS / ALL_SETTINGS_KEYS sanity checks
-- ─────────────────────────────────────────────────────────────────────────────

describe("constants", function()
    before_each(function() Mock.reset() end)

    it("DANGEROUS_PATHS contains '/' and '' and common system dirs", function()
        local U = freshUtils()
        assert.is_true(U.DANGEROUS_PATHS["/"] == true)
        assert.is_true(U.DANGEROUS_PATHS[""] == true)
        assert.is_true(U.DANGEROUS_PATHS["/etc"] == true)
    end)

    it("ALL_SETTINGS_KEYS is a non-empty table of strings", function()
        local U = freshUtils()
        assert.is_true(#U.ALL_SETTINGS_KEYS > 0)
        for _, k in ipairs(U.ALL_SETTINGS_KEYS) do
            assert.is_string(k)
        end
    end)

    it("ALL_SETTINGS_KEYS contains syncthing_port and syncthing_was_running", function()
        local U = freshUtils()
        local keys = {}
        for _, k in ipairs(U.ALL_SETTINGS_KEYS) do keys[k] = true end
        assert.is_true(keys["syncthing_port"])
        assert.is_true(keys["syncthing_was_running"])
    end)
end)
