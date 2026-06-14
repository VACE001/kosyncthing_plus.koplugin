-- run_tests.lua — a tiny, dependency-free Busted-compatible runner.
--
-- The spec suite was written for the `busted` framework. When busted (and
-- luarocks) are not installed, this runner provides just enough of the
-- describe/it/before_each/after_each API and the luassert matchers the specs
-- actually use, so the suite can run under plain lua5.3 / luajit.
--
-- Usage:
--   lua5.3 spec/run_tests.lua spec/st_utils_spec.lua      (one file)
--   for f in spec/*_spec.lua; do lua5.3 spec/run_tests.lua "$f"; done
--
-- It is NOT a full busted replacement — it implements only what these specs
-- need. If you have busted installed, `busted spec` still works unchanged.

local target = arg[1]
if not target then io.stderr:write("usage: run_tests.lua <spec_file>\n"); os.exit(2) end

-- make `require("spec.xxx")` and the plugin modules resolvable
package.path = "./?.lua;" .. package.path

-- Lua 5.1 shim: package.searchpath was added in Lua 5.2.
-- LuaJIT (used on-device by KOReader) has it; plain lua5.1 does not.
--
-- IMPORTANT: capture io.open NOW, before spec stubs replace it.
-- Some specs call stubIO() which swaps io.open with a test double that only
-- recognises paths in their io_open_map.  If the polyfill used the global
-- io.open at call-time it would return nil for every real source file,
-- causing loadfile(nil) → require returns true → "attempt to index boolean".
if not package.searchpath then
    local _real_io_open = io.open          -- captured once, immutable from here
    package.searchpath = function(name, path, sep, rep)
        sep = sep or "."
        rep = rep or "/"
        -- replace module-name separator (usually ".") with path separator
        name = name:gsub("%" .. sep, rep)
        local msg = {}
        for p in path:gmatch("[^;]+") do
            local fname = p:gsub("%?", name)
            local f = _real_io_open(fname, "r")
            if f then f:close(); return fname end
            msg[#msg + 1] = "\n\tno file '" .. fname .. "'"
        end
        return nil, table.concat(msg)
    end
end

-- ── busted-style structure: collect a tree, then run it ──────────────────
local root = { name = "", before = {}, after = {}, teardown = nil, children = {} }
local current = root
local function push_block(name)
    local b = { name = name, before = {}, after = {}, teardown = nil, children = {} }
    table.insert(current.children, b)
    local parent = current; current = b
    return parent
end
function describe(name, fn) local parent = push_block(name); fn(); current = parent end
function it(name, fn) table.insert(current.children, { test = true, name = name, fn = fn }) end
function before_each(fn) table.insert(current.before, fn) end
function after_each(fn) table.insert(current.after, fn) end
function setup(fn) table.insert(current.before, fn) end          -- not used, kept for safety
function teardown(fn) current.teardown = fn end
function pending() end                                            -- not used

-- ── luassert-style matchers (only the ones the specs use) ────────────────
local function fail(msg) error(msg, 2) end
local assert_t = {}
setmetatable(assert_t, { __call = function(_, v, msg)
    if v == nil or v == false then fail(msg or "assertion failed") end
    return v
end })
local function tos(v) return type(v) == "string" and ('"'..v..'"') or tostring(v) end
assert_t.are      = {
    equal = function(a, b) if a ~= b then fail("are.equal: "..tos(a).." ~= "..tos(b)) end end,
    same  = function(a, b) if a ~= b then fail("are.same: "..tos(a).." ~= "..tos(b)) end end,
}
assert_t.are_not  = { equal = function(a, b) if a == b then fail("are_not.equal: both "..tos(a)) end end }
assert_t.is_true     = function(v) if v ~= true  then fail("is_true: got "..tos(v)) end end
assert_t.is_false    = function(v) if v ~= false then fail("is_false: got "..tos(v)) end end
assert_t.is_truthy   = function(v) if not v      then fail("is_truthy: got "..tos(v)) end end
assert_t.is_falsy    = function(v) if v          then fail("is_falsy: got "..tos(v)) end end
assert_t.is_nil      = function(v) if v ~= nil   then fail("is_nil: got "..tos(v)) end end
assert_t.is_not_nil  = function(v) if v == nil   then fail("is_not_nil: got nil") end end
assert_t.is_string   = function(v) if type(v) ~= "string"   then fail("is_string: got "..type(v)) end end
assert_t.is_function = function(v) if type(v) ~= "function" then fail("is_function: got "..type(v)) end end
assert_t.has_no = { errors = function(fn)
    local ok, err = pcall(fn)
    if not ok then fail("has_no.errors: "..tostring(err)) end
end }
function assert_t.has_error(fn, expected)
    local ok, err = pcall(fn)
    if ok then fail("has_error: no error was raised") end
    if expected ~= nil and type(expected) == "string" then
        if not tostring(err):find(expected, 1, true) then
            fail("has_error: expected '"..expected.."' in '"..tostring(err).."'")
        end
    end
end
_G.assert = assert_t

-- ── load the spec file (registers the tree) ──────────────────────────────
local chunk, lerr = loadfile(target)
if not chunk then io.stderr:write("LOAD ERROR ("..target.."): "..tostring(lerr).."\n"); os.exit(1) end
local ok, rerr = pcall(chunk)
if not ok then
    print(("%-26s  LOAD-FAIL  %s"):format(target:match("([^/]+)$"), tostring(rerr)))
    os.exit(1)
end

-- ── run the tree ─────────────────────────────────────────────────────────
local pass, fail_n, fails = 0, 0, {}
local function run_block(block, befores, afters, path)
    local befores2 = {}
    for _, f in ipairs(befores)       do befores2[#befores2+1] = f end
    for _, f in ipairs(block.before)  do befores2[#befores2+1] = f end
    local afters2 = {}
    for _, f in ipairs(block.after)   do afters2[#afters2+1] = f end
    for _, f in ipairs(afters)        do afters2[#afters2+1] = f end
    local here = (path == "" and block.name) or (path .. " › " .. block.name)
    for _, child in ipairs(block.children) do
        if child.test then
            local fullname = here .. " :: " .. child.name
            local okh, eh
            for _, b in ipairs(befores2) do
                okh, eh = pcall(b); if not okh then break end
            end
            if okh ~= false then
                local okt, et = pcall(child.fn)
                if okt then pass = pass + 1
                else fail_n = fail_n + 1; fails[#fails+1] = fullname .. "  —  " .. tostring(et) end
            else
                fail_n = fail_n + 1; fails[#fails+1] = fullname .. "  — (before_each) " .. tostring(eh)
            end
            for _, a in ipairs(afters2) do pcall(a) end
        else
            run_block(child, befores2, afters2, here)
        end
    end
    if block.teardown then pcall(block.teardown) end
end
run_block(root, {}, {}, "")

local short = target:match("([^/]+)$")
print(("%-28s  %3d passed, %3d failed"):format(short, pass, fail_n))
if fail_n > 0 then
    for _, f in ipairs(fails) do print("      ✗ " .. f) end
    os.exit(1)
end
os.exit(0)
