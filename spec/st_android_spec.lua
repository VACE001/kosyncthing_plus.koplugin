-- st_android_spec.lua – tests for the Android remote-mode module.
--
-- st_android replaces daemon management with a remote REST client.  The HTTP
-- layer is exercised through an INJECTED request function (opts.request_fn /
-- self._android_request_fn), so these tests never open a real socket — they
-- verify the request SHAPE and the apiCall contract, not a live TLS handshake.
-- The lfs conflict scanner and the TTL cache are tested against real temp
-- directories.  Scheme ordering/persistence is driven through init() with a
-- stubbed G_reader_settings.

local Mock = require("spec.spec_helper")

-- syncthing_i18n is provided by the mock, but guard in case that changes.
package.loaded["syncthing_i18n"] = package.loaded["syncthing_i18n"]
    or { gettext = function(s) return s end,
         ngettext = function(s, p, n) return (n == 1) and s or p end }

-- st_android picks its JSON library with: rapidjson → cjson → fallback-nil.
-- Neither rapidjson nor cjson is available in the test sandbox, so we inject
-- a minimal but correct cjson stub BEFORE freshAndroid() loads the module.
-- The stub must:
--   • return a table for valid JSON objects  (test @ line 71)
--   • error() for invalid JSON              (test @ line 90, expects nil result)
do
    local ok_r = pcall(require, "rapidjson")
    if not ok_r then
        package.preload["cjson"] = function()
            return {
                decode = function(s)
                    -- Very small recursive-descent parser for the subset used
                    -- in the android spec: JSON objects and primitives only.
                    local pos = 1
                    local function skip()
                        while pos <= #s and s:sub(pos,pos):match("%s") do pos = pos+1 end
                    end
                    local parse  -- forward declaration
                    local function parse_string()
                        pos = pos + 1  -- skip opening "
                        local start = pos
                        while pos <= #s do
                            local c = s:sub(pos,pos)
                            if c == "\\" then pos = pos + 2
                            elseif c == "\"" then break
                            else pos = pos + 1 end
                        end
                        local v = s:sub(start, pos-1); pos = pos+1; return v
                    end
                    local function parse_object()
                        local t = {}; pos = pos+1; skip()
                        if s:sub(pos,pos) == "}" then pos=pos+1; return t end
                        while true do
                            skip()
                            if s:sub(pos,pos) ~= "\"" then error("bad key") end
                            local k = parse_string(); skip()
                            if s:sub(pos,pos) ~= ":" then error("expected :") end
                            pos = pos+1
                            t[k] = parse(); skip()
                            local c = s:sub(pos,pos)
                            if c == "}" then pos=pos+1; break
                            elseif c == "," then pos=pos+1
                            else error("expected , or }") end
                        end
                        return t
                    end
                    parse = function()
                        skip()
                        local c = s:sub(pos,pos)
                        if c == "{" then return parse_object()
                        elseif c == "\"" then return parse_string()
                        elseif c == "t" then
                            if s:sub(pos,pos+3)=="true"  then pos=pos+4; return true  end
                        elseif c == "f" then
                            if s:sub(pos,pos+4)=="false" then pos=pos+5; return false end
                        elseif c == "n" then
                            if s:sub(pos,pos+3)=="null"  then pos=pos+4; return nil   end
                        else
                            local n = s:match("^-?%d+%.?%d*", pos)
                            if n then pos=pos+#n; return tonumber(n) end
                        end
                        error("unexpected token: " .. tostring(c))
                    end
                    local ok, val = pcall(parse)
                    if not ok then error("JSON parse error: " .. tostring(val)) end
                    return val
                end,
                encode = function(v) return "{}" end,
            }
        end
    end
end

-- Load the real module (bypass any preload stub, like st_utils_spec does).
local function freshAndroid()
    package.loaded["st_android"] = nil
    local p = assert(package.searchpath("st_android", package.path),
        "st_android.lua not found on package.path")
    return assert(loadfile(p))()
end

local A = freshAndroid()
local apiCall = A._androidApiCall

-- ─────────────────────────────────────────────────────────────────────────────
-- helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function newPlugin(scheme)
    return {
        api_key        = "KEY123",
        syncthing_port = "8384",
        _api_scheme    = scheme or "https",
        getAPIKey      = function(self) return self.api_key end,
        _addApiError   = function(self, e)
            if self._suppress_api_errors then return end
            self._errs = self._errs or {}
            self._errs[#self._errs + 1] = e
        end,
    }
end

-- request_fn that returns a fixed code/body and records the request table.
local last_req
local function reqOK(code, body)
    return function(req)
        last_req = req
        if req.sink then req.sink(body); req.sink(nil) end
        return 1, code, {}, "HTTP/1.1 " .. tostring(code)
    end
end
local function reqFail(err)
    return function(req) last_req = req; return nil, err end
end
local function reqRaise()
    return function(req) last_req = req; error("boom") end
end

local function mktemp()
    local d = "/tmp/st_android_spec_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
    os.execute("rm -rf '" .. d .. "'; mkdir -p '" .. d .. "'")
    return d
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: apiCall contract (decoded table | true | nil)
-- ─────────────────────────────────────────────────────────────────────────────
describe("androidApiCall contract", function()
    it("200 + JSON object decodes to a table", function()
        local p = newPlugin()
        local r = apiCall(p, "config/folders", "GET", nil, { request_fn = reqOK(200, '{"a":1,"b":2}') })
        assert.is_truthy(type(r) == "table")
        assert.are.equal(1, r.a)
        assert.are.equal(2, r.b)
        assert.is_nil(p._errs)
    end)

    it("204 No Content returns true", function()
        local p = newPlugin()
        assert.is_true(apiCall(p, "db/scan", "POST", nil, { request_fn = reqOK(204, "") }))
    end)

    it("2xx with empty body returns true", function()
        local p = newPlugin()
        assert.is_true(apiCall(p, "system/pause", "POST", nil, { request_fn = reqOK(200, "") }))
    end)

    it("200 with non-JSON body returns nil and records an error", function()
        local p = newPlugin()
        assert.is_nil(apiCall(p, "x", "GET", nil, { request_fn = reqOK(200, "<<<not json>>>") }))
        assert.are.equal(1, #p._errs)
    end)

    it("non-2xx returns nil and records an error", function()
        local p = newPlugin()
        assert.is_nil(apiCall(p, "missing", "GET", nil, { request_fn = reqOK(404, "nope") }))
        assert.are.equal(1, #p._errs)
    end)

    it("transport failure returns nil and records an error", function()
        local p = newPlugin()
        assert.is_nil(apiCall(p, "x", "GET", nil, { request_fn = reqFail("connection refused") }))
        assert.are.equal(1, #p._errs)
    end)

    it("a raising request_fn is caught (pcall) and returns nil", function()
        local p = newPlugin()
        assert.is_nil(apiCall(p, "x", "GET", nil, { request_fn = reqRaise() }))
        assert.are.equal(1, #p._errs)
    end)

    it("_suppress_api_errors prevents recording", function()
        local p = newPlugin()
        p._suppress_api_errors = true
        assert.is_nil(apiCall(p, "x", "GET", nil, { request_fn = reqOK(500, "boom") }))
        assert.is_nil(p._errs)
    end)

    it("missing API key returns nil without calling the transport", function()
        local p = newPlugin()
        p.api_key = nil
        last_req = nil
        assert.is_nil(apiCall(p, "x", "GET", nil, { request_fn = reqOK(200, "{}") }))
        assert.is_nil(last_req)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: request shape (headers, URL, scheme, body)
-- ─────────────────────────────────────────────────────────────────────────────
describe("androidApiCall request shape", function()
    it("sends the X-API-Key header", function()
        local p = newPlugin()
        apiCall(p, "config", "GET", nil, { request_fn = reqOK(200, "{}") })
        assert.are.equal("KEY123", last_req.headers["X-API-Key"])
    end)

    it("builds scheme://127.0.0.1:port/rest/<path>", function()
        local p = newPlugin("https")
        apiCall(p, "config/folders", "GET", nil, { request_fn = reqOK(200, "{}") })
        assert.are.equal("https://127.0.0.1:8384/rest/config/folders", last_req.url)
    end)

    it("passes the HTTP method through", function()
        local p = newPlugin()
        apiCall(p, "db/scan", "POST", nil, { request_fn = reqOK(204, "") })
        assert.are.equal("POST", last_req.method)
    end)

    it("https requests carry permissive TLS options", function()
        local p = newPlugin("https")
        apiCall(p, "config", "GET", nil, { request_fn = reqOK(200, "{}") })
        assert.are.equal("none", last_req.verify)
        assert.are.equal("any", last_req.protocol)
    end)

    it("http requests carry no TLS options and an http URL", function()
        local p = newPlugin("http")
        apiCall(p, "config", "GET", nil, { request_fn = reqOK(200, "{}") })
        assert.is_nil(last_req.verify)
        assert.is_nil(last_req.protocol)
        assert.are.equal("http://127.0.0.1:8384/rest/config", last_req.url)
    end)

    it("a PUT body is drained exactly with Content-Length/Type set", function()
        local p = newPlugin("http")
        local drained = {}
        apiCall(p, "config/options", "PUT", '{"x":1}', { request_fn = function(req)
            last_req = req
            if req.source then
                local c = req.source()
                while c do drained[#drained + 1] = c; c = req.source() end
            end
            if req.sink then req.sink(""); req.sink(nil) end
            return 1, 200, {}, "HTTP/1.1 200"
        end })
        assert.are.equal('{"x":1}', table.concat(drained))
        assert.are.equal("7", last_req.headers["Content-Length"])
        assert.are.equal("application/json", last_req.headers["Content-Type"])
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: lfs conflict scanner
-- ─────────────────────────────────────────────────────────────────────────────
describe("findConflictsLfs scanner", function()
    it("finds conflict files and skips normal files and dot-dirs", function()
        local root = mktemp()
        os.execute("mkdir -p '" .. root .. "/f1/sub' '" .. root .. "/f1/.stfolder' '" .. root .. "/f1/.stversions'")
        os.execute("touch '" .. root .. "/f1/book.epub'")
        os.execute("touch '" .. root .. "/f1/book.sync-conflict-20260101-A.epub'")
        os.execute("touch '" .. root .. "/f1/sub/note.sync-conflict-20260202-X.sdr'")
        os.execute("touch '" .. root .. "/f1/.stfolder/ignored.sync-conflict-20260303-Z'")
        os.execute("touch '" .. root .. "/f1/.stversions/old.sync-conflict-20260404-Q'")
        local pl = { showNotification = function() end, getFolders = function() return { { path = root .. "/f1" } } end }
        local conflicts = A.findConflictsLfs(pl)
        assert.are.equal(2, #conflicts)
        local in_dot = false
        for _, c in ipairs(conflicts) do if c:find("%.st") then in_dot = true end end
        assert.is_false(in_dot)
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("returns empty when there are no folders", function()
        assert.are.equal(0, #A.findConflictsLfs({ showNotification = function() end, getFolders = function() return {} end }))
    end)

    it("does not crash on a missing folder path", function()
        local pl = { showNotification = function() end, getFolders = function() return { { path = "/tmp/st_android_does_not_exist_xyz" } } end }
        assert.are.equal(0, #A.findConflictsLfs(pl))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: conflict TTL cache + invalidation
-- ─────────────────────────────────────────────────────────────────────────────
describe("findConflicts TTL cache", function()
    it("does not re-walk within the TTL, and re-walks after invalidate", function()
        local root = mktemp()
        os.execute("touch '" .. root .. "/a.sync-conflict-20260101-A.epub'")
        local pl = { showNotification = function() end, getFolders = function() return { { path = root } } end }

        assert.are.equal(1, #A.findConflictsLfs(pl))      -- first walk
        os.execute("touch '" .. root .. "/b.sync-conflict-20260202-B.epub'")
        assert.are.equal(1, #A.findConflictsLfs(pl))      -- cached: still 1
        A.invalidateConflictsCache(pl)
        assert.are.equal(2, #A.findConflictsLfs(pl))      -- re-walk: now 2
        os.execute("rm -rf '" .. root .. "'")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: scheme ordering and persistence (via init)
-- ─────────────────────────────────────────────────────────────────────────────
describe("init scheme ordering / persistence", function()
    local store
    before_each(function()
        store = { syncthing_android_apikey = "K", syncthing_android_port = "8384" }
        _G.G_reader_settings = {
            readSetting = function(_, k) return store[k] end,
            saveSetting = function(_, k, v) store[k] = v end,
            delSetting  = function(_, k) store[k] = nil end,
        }
    end)

    -- request_fn that only succeeds for one scheme, counting tries per scheme.
    local function schemeOnly(ok_scheme, counter)
        return function(req)
            local sch = req.url:match("^(%a+):")
            counter[sch] = (counter[sch] or 0) + 1
            if sch == ok_scheme then
                if req.sink then req.sink("{}"); req.sink(nil) end
                return 1, 200, {}, "HTTP/1.1 200"
            end
            return nil, "refused"
        end
    end

    it("with no saved scheme, tries https before http and persists the winner", function()
        local cnt = {}
        store.syncthing_android_scheme = nil
        local p = {
            syncthing_port = "8384",
            getAPIKey = function(s) return s.api_key end,
            _addApiError = function() end,
            _android_request_fn = schemeOnly("http", cnt),
        }
        assert.is_true(A.init(p))
        assert.is_true((cnt.https or 0) >= 1)   -- https attempted first
        assert.is_true((cnt.http or 0) >= 1)    -- then http
        assert.are.equal("http", store.syncthing_android_scheme)  -- persisted
    end)

    it("with a saved scheme, tries it first and skips the other", function()
        local cnt = {}
        store.syncthing_android_scheme = "http"
        local p = {
            syncthing_port = "8384",
            getAPIKey = function(s) return s.api_key end,
            _addApiError = function() end,
            _android_request_fn = schemeOnly("http", cnt),
        }
        assert.is_true(A.init(p))
        assert.is_true((cnt.http or 0) >= 1)
        assert.are.equal(0, (cnt.https or 0))   -- saved scheme worked; https never tried
    end)

    it("returns false when no API key is saved (no blocking dialog)", function()
        store.syncthing_android_apikey = nil
        local p = { syncthing_port = "8384", getAPIKey = function(s) return s.api_key end, _addApiError = function() end }
        assert.is_false(A.init(p))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: IgnoreRegistry exclusions (companion / Syncery parity)
-- ─────────────────────────────────────────────────────────────────────────────
-- The Kindle/daemon scanner (st_sync) and the Android lfs scanner both post-
-- filter conflict hits through IgnoreRegistry:matchesConflictBasename, so a
-- companion's own conflict copies are not miscounted in the badge.  These tests
-- drive the Android scanner wiring via the `_android_excluded_fn` predicate
-- seam; the de-mangle/match logic itself is covered in st_api_public_spec.
describe("IgnoreRegistry exclusions (scanner wiring)", function()
    it("excludes conflict files the registry matcher rejects", function()
        local root = mktemp()
        os.execute("touch '" .. root .. "/book.sync-conflict-20260101-120000-ABCDEFG.epub'")
        os.execute("touch '" .. root .. "/state.sync-conflict-20260202-120000-ABCDEFG.lua'")
        local pl = {
            showNotification = function() end,
            getFolders = function() return { { path = root } } end,
            _android_excluded_fn = function(name) return name:match("%.lua$") ~= nil end,
        }
        local res = A.findConflictsLfs(pl)
        assert.are.equal(1, #res)
        assert.is_not_nil(res[1]:find("book.sync%-conflict"))
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("detects both '.' and '~' conflict separators", function()
        local root = mktemp()
        os.execute("touch '" .. root .. "/a.sync-conflict-20260101-120000-ABCDEFG.epub'")
        os.execute("touch '" .. root .. "/b~sync-conflict-20260202-120000-ABCDEFG.epub'")
        local pl = {
            showNotification = function() end,
            getFolders = function() return { { path = root } } end,
            _android_excluded_fn = function() return false end,
        }
        assert.are.equal(2, #A.findConflictsLfs(pl))
        os.execute("rm -rf '" .. root .. "'")
    end)

    it("counts all conflicts when nothing is excluded", function()
        local root = mktemp()
        os.execute("touch '" .. root .. "/a.sync-conflict-20260101-120000-ABCDEFG.epub'")
        os.execute("touch '" .. root .. "/b.sync-conflict-20260202-120000-ABCDEFG.sdr'")
        local pl = { showNotification = function() end, getFolders = function() return { { path = root } } end }
        assert.are.equal(2, #A.findConflictsLfs(pl))
        os.execute("rm -rf '" .. root .. "'")
    end)
end)
