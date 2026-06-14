-- Regression coverage for st_update.downloadFile's LuaSocket transport.
--
-- KOReader's socketutil.file_sink closes the file handle itself when the
-- request terminates.  _downloadViaLua used to call f:close() again
-- unconditionally, which crashes under LuaJIT ("attempt to use a closed
-- file") on every device that falls through to the Lua transport (no curl,
-- weak BusyBox wget).  These tests stub file_sink to close the handle on the
-- terminal chunk — exactly as the real one does — so a re-introduced
-- double-close would surface as a raised error here.

local noop = function() end

package.loaded["ui/widget/confirmbox"]  = { new = function(_, t) return t end }
package.loaded["ui/widget/infomessage"] = { new = function(_, t) return t end }
package.loaded["device"]                = {}
package.loaded["ui/uimanager"]          = { show = noop, close = noop, scheduleIn = function() end }
package.loaded["ui/network/manager"]    = { runWhenOnline = function() end }
package.loaded["ffi/util"]              = { template = function(s) return s end }
package.loaded["logger"]                = setmetatable({}, { __index = function() return noop end })
package.loaded["syncthing_i18n"]        = { gettext = function(s) return s end }
package.loaded["json"]                  = { decode = function() return nil end }
package.loaded["st_guard"]              = {}
package.loaded["util"]                  = {}

package.loaded["st_utils"] = {
    plugin_path   = "/tmp/",
    cacert_path   = "/tmp/cacert.pem",
    curlAvailable = function() return false end,   -- force-skip curl
    cacertExists  = function() return false end,
    shellEscape   = function(s) return s end,
    execOk        = function(c) return c == 0 or c == true end,
}

-- socketutil whose file_sink closes the handle on the terminal nil chunk,
-- mirroring frontend/socketutil.lua in KOReader.
package.loaded["socketutil"] = {
    FILE_BLOCK_TIMEOUT = 1,
    FILE_TOTAL_TIMEOUT = 1,
    set_timeout   = function() end,
    reset_timeout = function() end,
    file_sink = function(f)
        return function(chunk)
            if not chunk then
                f:close()
                return 1
            end
            return f:write(chunk)
        end
    end,
}

package.loaded["socket"] = {
    skip = function(n, ...) return select(n + 1, ...) end,
}

-- Each test swaps in its own request behaviour.
local http_behaviour
package.loaded["socket.http"] = {
    request = function(t) return http_behaviour(t) end,
}

-- Force-fail the curl/wget shell paths so the Lua transport is exercised.
os.execute = function() return false end

local M = require("st_update")

describe("downloadFile (LuaSocket transport)", function()
    local path = "/tmp/st_update_dl_test.bin"
    before_each(function() os.remove(path) end)
    after_each(function() os.remove(path) end)

    it("does not double-close the handle on a successful download", function()
        -- file_sink will close f on the terminal chunk; downloadFile must not
        -- crash closing it again.
        http_behaviour = function(t)
            t.sink("HELLO")
            t.sink(nil)                       -- terminal -> file_sink closes f
            return 1, 200, {}, "HTTP/1.1 200 OK"
        end
        local ok = M.downloadFile("http://example.invalid/x", path)
        assert.is_true(ok)
        local f = io.open(path, "rb")
        assert.is_not_nil(f)
        local body = f:read("*a"); f:close()
        assert.are.equal("HELLO", body)
    end)

    it("returns false and removes the partial file when http.request raises", function()
        -- Lua error before the terminal chunk: the sink never closed f, so the
        -- defensive close must run without erroring, and the partial file goes.
        http_behaviour = function() error("simulated DNS failure") end
        local ok = M.downloadFile("http://example.invalid/x", path)
        assert.is_false(ok)
        assert.is_nil(io.open(path, "rb"))   -- partial file removed
    end)

    it("returns false on a non-200 response", function()
        http_behaviour = function(t)
            t.sink(nil)
            return 1, 404, {}, "HTTP/1.1 404 Not Found"
        end
        local ok = M.downloadFile("http://example.invalid/x", path)
        assert.is_false(ok)
    end)
end)
