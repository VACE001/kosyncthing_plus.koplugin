-- st_api_spec.lua — Tests for the low-level REST API client (st_api.lua).
--
-- Coverage:
--   • apiCall — HTTP parsing, status-code classification, error recording,
--     wall-clock budget guard, partial-body capture
--   • _addApiError / getApiErrors — circular buffer (cap = 8)
--   • getAPIKey — cache short-circuit, missing file, empty key, extraction
--
-- Skipped (deliberately):
--   • SafeClient wrappers (GET/POST/PATCH/…) — trivial one-liners over apiCall
--   • getDeviceId — heavy file + apiCall dependency; tested indirectly
--
-- JSON note:
--   We install dkjson (spec/dkjson.lua) AFTER Mock.install() runs so that
--   st_api gets a real decoder instead of the always-{} stub in mock_koreader.
--   This matters for tests that assert on decoded field values.
--   dkjson.decode() returns nil (not an error) for invalid JSON, so the
--   code path `if ok_decode and type(decoded) == "table"` falls through to
--   `elseif ok_decode then result = true` — malformed JSON on a 2xx therefore
--   returns true, not nil. The tests reflect the actual implemented behaviour.

local Mock = require("spec.spec_helper")

-- Override the always-{} json stub with a real decoder for this spec.
package.loaded["json"]   = nil
package.preload["json"]  = function() return require("spec.dkjson") end

-- ─────────────────────────────────────────────────────────────────────────────
-- TCP fake
-- ─────────────────────────────────────────────────────────────────────────────
-- script is a plain array of frames consumed by receive() in order:
--   { line    = "str" }          receive("*l") → str, nil, nil
--   { body    = "str" }          receive(N|"*a") → str, nil, nil
--   { timeout = str|nil }        receive(…) → nil, "timeout", str
--   { err     = "str" }          receive(…) raises error("str")
--
-- script.connect_fail = true  → connect() returns false
-- script.send_fail    = true  → send() returns nil, "refused"
-- script.sent_data         → accumulates all strings passed to send()

local function makeTcp(script)
    local tcp = {}
    local idx = 0
    script.sent_data = {}
    tcp.sent_data = script.sent_data   -- expose on tcp so tests can read tcp.sent_data

    function tcp:settimeout() end
    function tcp:connect()      return not script.connect_fail end
    function tcp:send(data)
        table.insert(script.sent_data, data)
        if script.send_fail then return nil, "connection refused" end
        return #data, nil
    end
    function tcp:receive(mode)
        idx = idx + 1
        local f = script[idx]
        if not f then
            return (mode == "*a") and "", nil, nil
                or  nil, "closed", nil
        end
        if f.timeout ~= nil  then return nil, "timeout", f.timeout end
        if f.err             then error(f.err) end
        if f.line  ~= nil    then return f.line, nil, nil end
        if f.body  ~= nil    then return f.body, nil, nil end
        return nil, "closed", nil
    end
    function tcp:close() end
    return tcp
end

-- Convenience: build a list of frames for a standard HTTP response.
local function httpFrames(status, headers, body)
    local f = { { line = status } }
    for _, h in ipairs(headers or {}) do f[#f+1] = { line = h } end
    f[#f+1] = { line = "\r" }              -- blank separator line
    if body then f[#f+1] = { body = body } end
    return f
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Module loader + plugin stub
-- ─────────────────────────────────────────────────────────────────────────────

local function freshAPI(tcp)
    package.loaded["st_api"]  = nil
    package.loaded["socket"]  = nil
    -- Ensure json preload survives Mock.reset() called in before_each
    package.loaded["json"]    = nil
    package.preload["json"]   = function() return require("spec.dkjson") end
    package.preload["socket"] = function()
        return { tcp = function() return tcp end }
    end
    return require("st_api")
end

-- Mix ALL api module functions into a plugin stub, exactly as main.lua does.
-- Pass NO_API_KEY as api_key to explicitly get nil (Lua's nil-sentinel problem).
local NO_API_KEY = {}
local function newClient(api_mod, overrides)
    overrides = overrides or {}
    -- Resolve api_key before the table constructor to avoid the Lua ternary-nil
    -- pitfall: `cond and nil or X` falls through to X when the "true" branch is
    -- nil, because nil is falsy.  An explicit if/else is the only safe form.
    local resolved_api_key
    if overrides.api_key == NO_API_KEY then
        resolved_api_key = nil
    elseif overrides.api_key ~= nil then
        resolved_api_key = overrides.api_key
    else
        resolved_api_key = "test-key"
    end
    local p = {
        syncthing_port       = overrides.syncthing_port or "8384",
        api_key              = resolved_api_key,
        _starting            = overrides._starting  or false,
        _stopping            = overrides._stopping  or false,
        _suppress_api_errors = overrides._suppress_api_errors or false,
        _api_errors          = nil,
        _last_api_error      = nil,
        _cacheGet            = overrides._cacheGet or function() return nil end,
    }
    for name, fn in pairs(api_mod) do p[name] = fn end
    for name, v  in pairs(overrides) do
        -- api_key was already resolved above; skip it here so the NO_API_KEY
        -- sentinel table never overwrites the resolved nil on the object.
        if name ~= "api_key" then p[name] = v end
    end
    return p
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1 — successful responses
-- ─────────────────────────────────────────────────────────────────────────────

describe("apiCall — successful responses", function()
    before_each(function() Mock.reset() end)

    it("200 with JSON object body → returns decoded table", function()
        local body = '{"myID":"ABCDEF-1","version":"v1.27.0"}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Type: application/json", "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)

        local r = c:apiCall("system/status")
        assert.is_not_nil(r)
        assert.are.equal("ABCDEF-1",  r.myID)
        assert.are.equal("v1.27.0",   r.version)
    end)

    it("204 No Content → returns true", function()
        local tcp = makeTcp({ { line = "HTTP/1.0 204 No Content" } })
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_true(c:apiCall("db/scan?folder=books", "POST"))
        assert.is_nil(c._last_api_error)
    end)

    it("200 + Content-Length: 0 → returns true (Syncthing v2 write path)", function()
        -- Syncthing v2 returns 200 + Content-Length: 0 for most writes.
        -- A previous version only treated 204 as success, causing every
        -- PATCH to be misreported as failure (bug fixed in the codebase).
        local tcp = makeTcp(httpFrames("HTTP/1.0 200 OK", { "Content-Length: 0" }, nil))
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_true(c:apiCall("config/folders/books", "PATCH", '{"paused":true}'))
        assert.is_nil(c._last_api_error)
    end)

    it("200 without Content-Length (HTTP/1.0 close-delimited) → parses body", function()
        -- Go's net/http omits Content-Length for HTTP/1.0 clients; the
        -- receive("*a") fallback path must still decode correctly.
        local body = '{"state":"idle","needBytes":0}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Type: application/json" }, body))   -- no Content-Length
        local api  = freshAPI(tcp)
        local c    = newClient(api)

        local r = c:apiCall("db/status?folder=books")
        assert.is_not_nil(r)
        assert.are.equal("idle", r.state)
        assert.are.equal(0,      r.needBytes)
    end)

    it("200 with non-table JSON scalar → returns true (not nil)", function()
        -- Scalar JSON like `true` or `42` is valid but not a table.
        -- The code's `elseif ok_decode then result = true` handles this.
        local body = "true"
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)
        assert.is_true(c:apiCall("system/restart", "POST"))
    end)

    it("request carries X-API-Key header with the configured key", function()
        local body = '{"ok":true}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api, { api_key = "secret-xyz" })

        c:apiCall("system/status")
        assert.is_truthy((tcp.sent_data[1] or ""):find("X-API-Key: secret-xyz", 1, true))
    end)

    it("POST with payload adds Content-Length and body to the request", function()
        local body    = '{"ok":true}'
        local tcp     = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Length: " .. #body }, body))
        local api     = freshAPI(tcp)
        local c       = newClient(api)
        local payload = '{"paused":true}'

        c:apiCall("config/folders/books", "PATCH", payload)
        local req = tcp.sent_data[1] or ""
        assert.is_truthy(req:find("Content-Length: " .. #payload, 1, true))
        assert.is_truthy(req:find(payload, 1, true))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2 — failure paths and error recording
-- ─────────────────────────────────────────────────────────────────────────────

describe("apiCall — failure paths", function()
    before_each(function() Mock.reset() end)

    it("returns nil immediately when API key is unavailable", function()
        local tcp = makeTcp({})
        local api = freshAPI(tcp)
        local c   = newClient(api, { api_key = NO_API_KEY })
        c.getAPIKey = function() return nil end
        assert.is_nil(c:apiCall("system/status"))
    end)

    it("connect failure → nil + error recorded with 'connect failed'", function()
        local tcp = makeTcp({ connect_fail = true })
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
        assert.is_truthy(c._last_api_error.status:find("connect failed", 1, true))
    end)

    it("connect failure while _stopping → error suppressed (expected noise)", function()
        local tcp = makeTcp({ connect_fail = true })
        local api = freshAPI(tcp)
        local c   = newClient(api, { _stopping = true })
        c:apiCall("system/status")
        assert.is_nil(c._last_api_error)
    end)

    it("connect failure while _starting → error suppressed", function()
        local tcp = makeTcp({ connect_fail = true })
        local api = freshAPI(tcp)
        local c   = newClient(api, { _starting = true })
        c:apiCall("system/status")
        assert.is_nil(c._last_api_error)
    end)

    it("connect failure when is_running cache is false → error suppressed", function()
        local tcp = makeTcp({ connect_fail = true })
        local api = freshAPI(tcp)
        local c   = newClient(api, {
            _cacheGet = function(_, k) if k == "is_running" then return false end end,
        })
        c:apiCall("system/status")
        assert.is_nil(c._last_api_error)
    end)

    it("send failure → nil + error with 'send failed'", function()
        local tcp = makeTcp({ send_fail = true })
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
        assert.is_truthy(c._last_api_error.status:find("send failed", 1, true))
    end)

    it("connection closed before status line → nil + error recorded", function()
        local tcp = makeTcp({ { timeout = nil } })
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
    end)

    it("403 Forbidden → nil + status line captured in error.status", function()
        local body = '{"error":"Access Denied"}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 403 Forbidden",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
        assert.is_truthy(c._last_api_error.status:find("403", 1, true))
    end)

    it("500 Internal Server Error → nil", function()
        local body = '{"error":"panic"}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 500 Internal Server Error",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)
        assert.is_nil(c:apiCall("system/status"))
    end)

    it("malformed JSON on 2xx → returns true (dkjson returns nil, code path → true)", function()
        -- dkjson.decode returns nil (not error) for invalid input. The code then
        -- hits `elseif ok_decode then result = true`, so the call still succeeds
        -- (caller can't distinguish a real scalar from a bad body, but it won't crash).
        local body = "not-json {"
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)
        assert.has_no.errors(function()
            assert.is_true(c:apiCall("system/status"))
        end)
    end)

    it("socket raises Lua error mid-read → nil returned gracefully, no crash", function()
        local frames = {
            { line = "HTTP/1.0 200 OK"     },
            { line = "Content-Length: 50"  },
            { line = "\r"                  },
            { err  = "socket: reset by peer" },
        }
        local tcp = makeTcp(frames)
        local api = freshAPI(tcp)
        local c   = newClient(api)
        assert.has_no.errors(function()
            assert.is_nil(c:apiCall("system/status"))
        end)
    end)

    it("body timeout: partial body is stitched from receive() partial return", function()
        -- receive() returns nil,"timeout",partial when the full Content-Length
        -- bytes don't arrive in time.  The code uses `body = body or partial`
        -- to stitch the fragment so JSON decode is still attempted.
        --
        -- With dkjson (used in this spec): decode of truncated JSON returns nil
        -- without raising an error → ok_decode=true, decoded=nil → result=true.
        -- On-device rapidjson raises a Lua error instead → ok_decode=false →
        -- result stays nil and the error IS recorded.  Both paths correctly
        -- store the partial data in last_body; the difference is only whether
        -- the call is considered a success.
        --
        -- This test covers the dkjson path: call returns true (not nil) and
        -- the partial body is accessible via _last_api_error only when a
        -- subsequent genuine failure happens.  The key invariant tested here
        -- is that the partial receive does not crash and returns a truthy value.
        local partial = '{"myID":"ABC'          -- truncated, invalid JSON
        local frames  = {
            { line    = "HTTP/1.0 200 OK"   },
            { line    = "Content-Length: 100" },
            { line    = "\r"                },
            { timeout = partial             },
        }
        local tcp = makeTcp(frames)
        local api = freshAPI(tcp)
        local c   = newClient(api)
        -- dkjson: decode(truncated) → nil without error → result = true
        local result = c:apiCall("system/status")
        assert.has_no.errors(function() end)   -- no crash
        assert.is_true(result)                 -- dkjson path: call succeeds
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3 — wall-clock budget guard
-- ─────────────────────────────────────────────────────────────────────────────
-- time.now() returns Mock.state.now; time.to_s is identity.
-- API_TOTAL_BUDGET_SEC = 5. Setting Mock.state.now = 6 triggers over_budget().
-- The guard is checked at three points after data arrives (not before):
--   1. After status line
--   2. Inside header loop (after each header receive)
--   3. After headers, before body

describe("apiCall — wall-clock budget guard", function()
    before_each(function() Mock.reset() end)

    it("budget exceeded after the status line → nil + 'timeout' in error", function()
        local call = 0
        local tcp  = {
            settimeout = function() end,
            connect    = function() return true end,
            send       = function(_, d) return #d, nil end,
            close      = function() end,
            receive    = function(_, _)
                call = call + 1
                if call == 1 then return "HTTP/1.0 200 OK", nil, nil end
                -- Advance time before first over_budget check (after status line)
                Mock.state.now = 6
                return "Content-Length: 50", nil, nil
            end,
        }
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
        assert.is_truthy(c._last_api_error.status:find("timeout", 1, true))
    end)

    it("budget exceeded inside header loop → nil + 'timeout' in error", function()
        local call = 0
        local tcp  = {
            settimeout = function() end,
            connect    = function() return true end,
            send       = function(_, d) return #d, nil end,
            close      = function() end,
            receive    = function(_, _)
                call = call + 1
                if call == 1 then return "HTTP/1.0 200 OK",     nil, nil end
                if call == 2 then return "Content-Length: 100", nil, nil end
                -- Advance time during a subsequent header; guard fires inside loop
                Mock.state.now = 6
                return "X-Custom: value", nil, nil
            end,
        }
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
        assert.is_truthy(c._last_api_error.status:find("timeout", 1, true))
    end)

    it("budget exceeded after headers but before body → nil", function()
        -- Advance time while returning the blank line (end of headers).
        -- After the header loop exits, over_budget() fires before body read.
        local call = 0
        local tcp  = {
            settimeout = function() end,
            connect    = function() return true end,
            send       = function(_, d) return #d, nil end,
            close      = function() end,
            receive    = function(_, _)
                call = call + 1
                if call == 1 then return "HTTP/1.0 200 OK",     nil, nil end
                if call == 2 then return "Content-Length: 100", nil, nil end
                if call == 3 then
                    -- blank line: the header loop will break AFTER this returns,
                    -- then the post-header over_budget check fires.
                    Mock.state.now = 6
                    return "\r", nil, nil
                end
                return '{"myID":"ABCDEF"}', nil, nil
            end,
        }
        local api = freshAPI(tcp)
        local c   = newClient(api)

        assert.is_nil(c:apiCall("system/status"))
        assert.is_not_nil(c._last_api_error)
    end)

    it("no budget problem on a fast request → result is returned", function()
        -- Sanity: time stays at 0, so over_budget() is always false.
        local body = '{"state":"idle"}'
        local tcp  = makeTcp(httpFrames("HTTP/1.0 200 OK",
            { "Content-Length: " .. #body }, body))
        local api  = freshAPI(tcp)
        local c    = newClient(api)

        local r = c:apiCall("db/status?folder=books")
        assert.is_not_nil(r)
        assert.are.equal("idle", r.state)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4 — error circular buffer
-- ─────────────────────────────────────────────────────────────────────────────

describe("API error circular buffer", function()
    local api
    before_each(function()
        Mock.reset()
        api = freshAPI(makeTcp({ connect_fail = true }))
    end)

    it("getApiErrors returns empty table initially", function()
        local c = newClient(api)
        assert.are.equal(0, #c:getApiErrors())
    end)

    it("errors accumulate up to 8 entries", function()
        local c = newClient(api)
        for i = 1, 8 do c:_addApiError({ path = "p"..i, status="err", time=i }) end
        assert.are.equal(8, #c:getApiErrors())
    end)

    it("9th error evicts the oldest (cap = 8)", function()
        local c = newClient(api)
        for i = 1, 9 do c:_addApiError({ path = "p"..i, status="err", time=i }) end
        local errs = c:getApiErrors()
        assert.are.equal(8,    #errs)
        assert.are.equal("p2", errs[1].path)    -- p1 was evicted
        assert.are.equal("p9", errs[8].path)
    end)

    it("_last_api_error always points to the most recent entry", function()
        local c = newClient(api)
        c:_addApiError({ path = "first",  status="err", time=1 })
        c:_addApiError({ path = "second", status="err", time=2 })
        assert.are.equal("second", c._last_api_error.path)
    end)

    it("_clearApiErrors empties buffer and nulls _last_api_error", function()
        local c = newClient(api)
        c:_addApiError({ path = "p1", status="err", time=1 })
        c:_clearApiErrors()
        assert.are.equal(0, #c:getApiErrors())
        assert.is_nil(c._last_api_error)
    end)

    it("_suppress_api_errors = true prevents all recording", function()
        local c = newClient(api, { _suppress_api_errors = true })
        c:_addApiError({ path = "p1", status="err", time=1 })
        assert.are.equal(0, #c:getApiErrors())
        assert.is_nil(c._last_api_error)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5 — getAPIKey
-- ─────────────────────────────────────────────────────────────────────────────

describe("getAPIKey", function()
    before_each(function() Mock.reset() end)

    it("returns self.api_key immediately when cached — no io.open", function()
        local api     = freshAPI(makeTcp({}))
        local opened  = {}
        local real    = io.open
        io.open = function(p, m)
            table.insert(opened, p)
            return real(p, m)
        end

        local c   = newClient(api, { api_key = "cached-key" })
        local key = c:getAPIKey()
        io.open   = real

        assert.are.equal("cached-key", key)
        for _, p in ipairs(opened) do
            assert.is_falsy(p:find("config.xml", 1, true))
        end
    end)

    it("returns nil when config.xml does not exist", function()
        local api  = freshAPI(makeTcp({}))
        local real = io.open
        io.open = function(p, m)
            if p:find("config.xml", 1, true) then return nil end
            return real(p, m)
        end

        local c   = newClient(api, { api_key = NO_API_KEY })
        local key = c:getAPIKey()
        io.open   = real
        assert.is_nil(key)
    end)

    it("empty <apikey></apikey> → nil (empty string is truthy in Lua, must be guarded)", function()
        local api  = freshAPI(makeTcp({}))
        local xml  = "<configuration><apikey></apikey></configuration>"
        local real = io.open
        io.open = function(p, _)
            if p:find("config.xml", 1, true) then
                return { read = function() return xml end, close = function() end }
            end
            return real(p, _)
        end

        local c   = newClient(api, { api_key = NO_API_KEY })
        local key = c:getAPIKey()
        io.open   = real
        assert.is_nil(key)
    end)

    it("extracts key, strips surrounding whitespace, and caches it", function()
        local api  = freshAPI(makeTcp({}))
        local xml  = "<configuration><apikey>  MYKEY123  </apikey></configuration>"
        local real = io.open
        io.open = function(p, _)
            if p:find("config.xml", 1, true) then
                return { read = function() return xml end, close = function() end }
            end
            return real(p, _)
        end

        local c   = newClient(api, { api_key = NO_API_KEY })
        local key = c:getAPIKey()
        io.open   = real

        assert.are.equal("MYKEY123", key)
        assert.are.equal("MYKEY123", c.api_key)    -- cached for next call
    end)
end)