-- st_filesystem_spec.lua – comprehensive tests for the filesystem safety module.
-- Covers: exists, sanitiseName, isUnder, remove, rename, write, mkdir, purge,
-- and the existing purgeChildrenMatching regression (BUG-34).

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local tmpdir = "/tmp/st_fs_spec_" .. tostring(math.floor(os.clock() * 1e6))

-- Use a real util for the tmpdir tests that touch the filesystem.
local function realUtil()
    return {
        pathExists = function(path)
            local p = io.popen(string.format("test -e '%s' && echo yes", path))
            local r = p and p:read("*l") or nil
            if p then p:close() end
            return r == "yes"
        end,
        makePath          = function(p)
            os.execute("mkdir -p '" .. p .. "'")
            return true
        end,
        getFriendlySize   = function(b) return tostring(b) end,
        getFilesystemType = function() return "ext4" end,
        urlEncode         = function(s) return s end,
    }
end

-- Use a mock util controlled by Mock.state.path_exists.
local function mockUtil()
    return {
        pathExists        = function(p) return Mock.state.path_exists[p] == true end,
        makePath          = function(p) Mock.state.path_exists[p] = true; return true end,
        getFriendlySize   = function() return "0 B" end,
        getFilesystemType = function() return "ext4" end,
        urlEncode         = function(s) return s end,
    }
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function freshFS(util_fn)
    package.loaded["st_filesystem"] = nil
    package.preload["util"] = util_fn or function() return mockUtil() end
    package.loaded["util"] = nil
    return require("st_filesystem")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: FS.exists
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.exists", function()
    before_each(function()
        Mock.reset()
    end)

    it("returns false for nil path", function()
        local FS = freshFS()
        assert.is_false(FS.exists(nil))
    end)

    it("returns false for empty string", function()
        local FS = freshFS()
        assert.is_false(FS.exists(""))
    end)

    it("returns false when util.pathExists returns false", function()
        local FS = freshFS()
        assert.is_false(FS.exists("/some/path"))
    end)

    it("returns true when util.pathExists returns true", function()
        Mock.state.path_exists["/some/path"] = true
        local FS = freshFS()
        assert.is_true(FS.exists("/some/path"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: FS.sanitiseName
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.sanitiseName", function()
    before_each(function() Mock.reset() end)

    it("returns nil for nil input", function()
        local FS = freshFS()
        assert.is_nil(FS.sanitiseName(nil))
    end)

    it("returns nil when result would be empty after stripping", function()
        local FS = freshFS()
        assert.is_nil(FS.sanitiseName("   "))
    end)

    it("returns nil for '.' and '..'", function()
        local FS = freshFS()
        assert.is_nil(FS.sanitiseName("."))
        assert.is_nil(FS.sanitiseName(".."))
    end)

    it("replaces forward slashes with underscores", function()
        local FS = freshFS()
        assert.are.equal("a_b_c", FS.sanitiseName("a/b/c"))
    end)

    it("replaces FAT-illegal characters with underscores", function()
        local FS = freshFS()
        local result = FS.sanitiseName("file:name*<>|?")
        assert.is_falsy(result:find("[:<>|?*]"))
    end)

    it("strips leading and trailing whitespace", function()
        local FS = freshFS()
        assert.are.equal("hello world", FS.sanitiseName("  hello world  "))
    end)

    it("strips control characters", function()
        local FS = freshFS()
        local result = FS.sanitiseName("my\0name\t!")
        assert.is_falsy(result:find("%c"))
    end)

    it("passes through a clean simple name unchanged", function()
        local FS = freshFS()
        assert.are.equal("MyBooks2026", FS.sanitiseName("MyBooks2026"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: FS.isUnder
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.isUnder", function()
    before_each(function() Mock.reset() end)

    it("returns true when target equals base", function()
        local FS = freshFS()
        assert.is_true(FS.isUnder("/mnt/us", "/mnt/us"))
    end)

    it("returns true when target is a child of base", function()
        local FS = freshFS()
        assert.is_true(FS.isUnder("/mnt/us", "/mnt/us/documents/book.epub"))
    end)

    it("returns false for a sibling path", function()
        local FS = freshFS()
        assert.is_false(FS.isUnder("/mnt/us", "/mnt/sd"))
    end)

    it("returns false when target looks like a prefix but is a sibling (no slash boundary)", function()
        local FS = freshFS()
        -- /mnt/us2 must NOT be considered under /mnt/us
        assert.is_false(FS.isUnder("/mnt/us", "/mnt/us2/file"))
    end)

    it("returns false for nil inputs", function()
        local FS = freshFS()
        assert.is_false(FS.isUnder(nil, "/some/path"))
        assert.is_false(FS.isUnder("/some/path", nil))
    end)

    it("normalises trailing slashes before comparing", function()
        local FS = freshFS()
        assert.is_true(FS.isUnder("/mnt/us/", "/mnt/us/documents"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: FS.remove
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.remove", function()
    before_each(function()
        Mock.reset()
        os.execute("mkdir -p " .. tmpdir)
    end)

    after_each(function()
        os.execute("rm -rf '" .. tmpdir .. "'")
    end)

    it("returns true when file does not exist (idempotent)", function()
        local FS = freshFS()
        local ok = FS.remove("/does/not/exist/ever.txt")
        assert.is_true(ok)
    end)

    it("returns false+err for nil path", function()
        local FS = freshFS()
        local ok, err = FS.remove(nil)
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("removes an existing file on the real filesystem", function()
        local path = tmpdir .. "/to_remove.txt"
        os.execute("touch '" .. path .. "'")
        assert.is_true(fileExists(path))
        local FS = freshFS(function() return realUtil() end)
        local ok = FS.remove(path)
        assert.is_true(ok)
        assert.is_false(fileExists(path))
    end)

    it("returns false+err when os.remove fails", function()
        Mock.state.path_exists["/fake/file.txt"] = true
        local real_remove = os.remove
        os.remove = function(path) return nil, "permission denied" end
        local FS = freshFS()
        local ok, err = FS.remove("/fake/file.txt")
        os.remove = real_remove
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("permission denied"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: FS.rename
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.rename", function()
    before_each(function()
        Mock.reset()
        os.execute("mkdir -p " .. tmpdir)
    end)

    after_each(function()
        os.execute("rm -rf '" .. tmpdir .. "'")
    end)

    it("returns false when source does not exist", function()
        local FS = freshFS()
        local ok, err = FS.rename("/no/such/file.txt", "/dst.txt")
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("returns false+err for nil paths", function()
        local FS = freshFS()
        local ok, err = FS.rename(nil, "/dst.txt")
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("renames an existing file on the real filesystem", function()
        local src = tmpdir .. "/src.txt"
        local dst = tmpdir .. "/dst.txt"
        os.execute("echo hello > '" .. src .. "'")
        local FS = freshFS(function() return realUtil() end)
        local ok = FS.rename(src, dst)
        assert.is_true(ok)
        assert.is_false(fileExists(src))
        assert.is_true(fileExists(dst))
    end)

    it("returns false+err when os.rename fails", function()
        Mock.state.path_exists["/fake/src.txt"] = true
        local real_rename = os.rename
        os.rename = function() return nil, "cross-device link" end
        local FS = freshFS()
        local ok, err = FS.rename("/fake/src.txt", "/fake/dst.txt")
        os.rename = real_rename
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("cross-device", 1, true))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: FS.write
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.write", function()
    before_each(function()
        Mock.reset()
        os.execute("mkdir -p " .. tmpdir)
    end)

    after_each(function()
        os.execute("rm -rf '" .. tmpdir .. "'")
    end)

    it("returns false for empty path", function()
        local FS = freshFS(function() return realUtil() end)
        local ok, err = FS.write("", "content")
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("returns false when content is not a string", function()
        local FS = freshFS(function() return realUtil() end)
        local ok, err = FS.write(tmpdir .. "/out.txt", 42)
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("atomically writes content via temp file and renames into place", function()
        local path = tmpdir .. "/atomic.txt"
        local FS = freshFS(function() return realUtil() end)
        local ok = FS.write(path, "hello world")
        assert.is_true(ok)
        assert.is_true(fileExists(path))
        assert.is_false(fileExists(path .. ".tmp"))
        local f = io.open(path, "r")
        local content = f:read("*a"); f:close()
        assert.are.equal("hello world", content)
    end)

    it("cleans up temp file when io.open for writing fails", function()
        local path = tmpdir .. "/unwritable.txt"
        -- Make the directory read-only so open for write fails.
        -- We simulate this by intercepting io.open for the .tmp path.
        local real_open = io.open
        io.open = function(p, mode)
            if p == path .. ".tmp" and mode == "w" then
                return nil, "permission denied"
            end
            return real_open(p, mode)
        end
        local FS = freshFS(function() return realUtil() end)
        local ok, err = FS.write(path, "data")
        io.open = real_open
        assert.is_false(ok)
        assert.is_truthy(err)
        assert.is_false(fileExists(path .. ".tmp"))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: FS.mkdir
-- ─────────────────────────────────────────────────────────────────────────────

describe("FS.mkdir", function()
    before_each(function() Mock.reset() end)

    it("returns false+err for empty path", function()
        local FS = freshFS()
        local ok, err = FS.mkdir("")
        assert.is_false(ok)
        assert.is_string(err)
    end)

    it("returns true immediately when directory already exists", function()
        Mock.state.path_exists["/existing/dir"] = true
        local FS = freshFS()
        local ok = FS.mkdir("/existing/dir")
        assert.is_true(ok)
    end)

    it("calls util.makePath for a new directory and returns true", function()
        local made = {}
        package.preload["util"] = function()
            return {
                pathExists = function(p) return Mock.state.path_exists[p] == true end,
                makePath   = function(p) made[p] = true; return true end,
                getFriendlySize = function() return "0" end,
                getFilesystemType = function() return "ext4" end,
                urlEncode = function(s) return s end,
            }
        end
        package.loaded["util"] = nil
        package.loaded["st_filesystem"] = nil
        local FS = require("st_filesystem")
        local ok = FS.mkdir("/new/dir")
        assert.is_true(ok)
        assert.is_true(made["/new/dir"])
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 8: purgeChildrenMatching – BUG-34 regression (original spec)
-- ─────────────────────────────────────────────────────────────────────────────

local tmpdir2 = "/tmp/st_fs_spec2_" .. tostring(math.floor(os.clock() * 1e6))

describe("FS.purgeChildrenMatching (BUG-34)", function()
    before_each(function()
        Mock.reset()
        package.preload["util"] = function() return realUtil() end
        package.loaded["st_filesystem"] = nil
        package.loaded["util"] = nil
        os.execute("rm -rf '" .. tmpdir2 .. "'")
        os.execute("mkdir -p '" .. tmpdir2 .. "'")
        os.execute("touch '" .. tmpdir2 .. "/index-v0.14.0.db'")
        os.execute("touch '" .. tmpdir2 .. "/index-v0.15.0.db'")
        os.execute("touch '" .. tmpdir2 .. "/config.xml'")
    end)

    after_each(function()
        os.execute("rm -rf '" .. tmpdir2 .. "'")
    end)

    it("shell glob 'index-*' removes index files and leaves config.xml", function()
        local FS = require("st_filesystem")
        local ok = FS.purgeChildrenMatching(tmpdir2, "index-*", "any")
        assert.is_true(ok)
        assert.is_false(fileExists(tmpdir2 .. "/index-v0.14.0.db"))
        assert.is_false(fileExists(tmpdir2 .. "/index-v0.15.0.db"))
        assert.is_true(fileExists(tmpdir2 .. "/config.xml"))
    end)

    it("returns true when dir does not exist", function()
        local FS = require("st_filesystem")
        assert.is_true(FS.purgeChildrenMatching("/tmp/nonexistent_xyz_spec", "index-*"))
    end)

    it("regression: Lua pattern '^index%-' matches nothing under find -name", function()
        local p = io.popen(string.format(
            "find '%s' -maxdepth 1 -name '%s' 2>/dev/null", tmpdir2, "^index%-"))
        local result = p:read("*a"); p:close()
        assert.are.equal("", result)
    end)
end)
