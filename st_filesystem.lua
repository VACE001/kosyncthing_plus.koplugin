-- st_filesystem.lua – Filesystem safety module
--
-- Provides safe, checked wrappers around all file and directory
-- operations that the plugin performs.  Every public function returns
--   (true)          on success
--   (false, errmsg) on failure
--
-- This module eliminates the class of bugs where code assumes that
-- os.remove / os.rename / io.open always succeed, which is especially
-- dangerous on e‑ink devices with slow, low‑space FAT/FUSE filesystems.

local util   = require("util")
local logger = require("logger")

local FS = {}

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

local function _normalise(p)
    if not p then return nil end
    p = p:gsub("/+$", ""):gsub("/+", "/")
    return p
end

local function _shell(p)
    if not p then return "" end
    return tostring(p):gsub("'", "'\\''")
end

-- Returns true if the filesystem at `path` needs an explicit sync flush
-- before rename to avoid torn writes (FAT, exFAT, FUSE-based mounts).
local function _needsSync(path)
    local fstype = util.getFilesystemType and util.getFilesystemType(path)
    if not fstype then return true end  -- can't tell, be safe
    fstype = fstype:lower()
    return fstype:match("fat") ~= nil
        or fstype:match("fuse") ~= nil
        or fstype:match("exfat") ~= nil
end

---------------------------------------------------------------------------
-- Basic checks
---------------------------------------------------------------------------

function FS.exists(path)
    if not path or path == "" then return false end
    return util.pathExists(path) == true
end

---------------------------------------------------------------------------
-- Path helpers
---------------------------------------------------------------------------

function FS.sanitiseName(name)
    if not name then return nil end
    local s = tostring(name)
    s = s:gsub("[/\\]+", "_")
    -- FAT/exFAT filesystems (Kindle /mnt/us, Kobo SD card) reject these chars.
    -- Syncthing folder labels can contain any Unicode, so we must sanitise
    -- before using a label as a directory or filename component.
    s = s:gsub('[:\\*?"<>|]', "_")
    s = s:gsub("%c", "_")           -- strip control chars (null, tab, newline…)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "." or s == ".." then
        return nil
    end
    return s
end

function FS.isUnder(base, target)
    if not base or not target then return false end
    base   = _normalise(base)
    target = _normalise(target)
    if not base or not target then return false end
    if target == base then return true end
    local prefix = base .. "/"
    return target:sub(1, #prefix) == prefix
end

---------------------------------------------------------------------------
-- File operations
---------------------------------------------------------------------------

function FS.remove(path)
    if not path or path == "" then
        logger.warn("[st_filesystem] remove: empty path")
        return false, "empty path"
    end
    if not FS.exists(path) then
        -- Idempotent: caller's goal is "file must not exist" — already achieved.
        -- Log at dbg level so it is traceable without polluting warn logs.
        logger.dbg("[st_filesystem] remove: already absent (idempotent) – " .. path)
        return true
    end
    local ok, err = os.remove(path)
    if not ok then
        logger.warn("[st_filesystem] remove failed: " .. tostring(err) .. " – " .. path)
        return false, tostring(err)
    end
    return true
end

function FS.rename(old, new)
    if not old or not new then
        logger.warn("[st_filesystem] rename: nil path")
        return false, "nil path"
    end
    if not FS.exists(old) then
        logger.warn("[st_filesystem] rename: source missing – " .. old)
        return false, "source does not exist: " .. old
    end
    local ok, err = os.rename(old, new)
    if not ok then
        logger.warn("[st_filesystem] rename failed: " .. tostring(err)
                     .. " from " .. old .. " to " .. new)
        return false, tostring(err)
    end
    return true
end

-- Atomically write content to path via a temp file.
function FS.write(path, content)
    if not path or path == "" then
        logger.warn("[st_filesystem] write: empty path")
        return false, "empty path"
    end
    if type(content) ~= "string" then
        logger.warn("[st_filesystem] write: content is not a string")
        return false, "content must be a string"
    end

    local tmp = path .. ".tmp"

    local f, err = io.open(tmp, "w")
    if not f then
        logger.warn("[st_filesystem] write: cannot open temp – " .. tostring(err))
        return false, "cannot open temp file: " .. tostring(err)
    end

    local ok, werr = f:write(content)
    if not ok then
        f:close()
        os.remove(tmp)
        logger.warn("[st_filesystem] write: write error – " .. tostring(werr))
        return false, "write error: " .. tostring(werr)
    end

    local closeOk, closeErr = f:close()
    if not closeOk then
        os.remove(tmp)
        logger.warn("[st_filesystem] write: close error – " .. tostring(closeErr))
        return false, "close error: " .. tostring(closeErr)
    end

    -- Flush to physical storage before rename — only on FAT/exFAT/FUSE where
    -- the kernel write-back cache is not coherent with rename ordering.
    -- Skipped on ext4/f2fs to avoid stalling the UI for hundreds of ms.
    if _needsSync(path) then
        os.execute("sync 2>/dev/null")
    end

    -- Atomically replace the target; clean up tmp on failure
    local renOk, renErr = FS.rename(tmp, path)
    if not renOk then
        os.remove(tmp)
        return false, renErr
    end
    return true
end

---------------------------------------------------------------------------
-- Directory operations
---------------------------------------------------------------------------

function FS.mkdir(path)
    if not path or path == "" then return false, "empty path" end
    if FS.exists(path) then return true end
    local ok, err = util.makePath(path)
    if not ok then
        logger.warn("[st_filesystem] mkdir failed: " .. tostring(err) .. " – " .. path)
        return false, tostring(err)
    end
    return true
end

function FS.purge(dir)
    if not dir or dir == "" then return false, "empty path" end
    if not FS.exists(dir) then return true end

    local ffiutil = require("ffi/util")
    local ok = pcall(ffiutil.purgeDir, dir)
    if ok and not FS.exists(dir) then return true end

    os.execute("rm -rf '" .. _shell(dir) .. "' 2>/dev/null")

    if FS.exists(dir) then
        logger.warn("[st_filesystem] purge: directory still exists after rm -rf – " .. dir)
        return false, "could not purge directory: " .. dir
    end
    return true
end

-- FS.purgeChildrenMatching(dir, glob, kind)
--
-- Removes all direct children of `dir` whose names match the POSIX shell
-- glob `glob` (passed verbatim to `find -name`).  This is a shell glob,
-- NOT a Lua pattern — use "index-*" not "^index%-" (BUG-34).
--
-- `kind` is "file", "directory", or "any" (default).
-- Returns true on success, false + error string on partial failure.
function FS.purgeChildrenMatching(dir, glob, kind)
    if not dir or dir == "" then return false, "empty path" end
    if not FS.exists(dir) then return true end

    kind = kind or "any"
    local type_arg = ""
    if kind == "directory" then
        type_arg = "-type d"
    elseif kind == "file" then
        type_arg = "-type f"
    end

    local cmd = string.format(
        "find '%s' -maxdepth 1 -name '%s' %s -exec rm -rf {} + 2>/dev/null",
        _shell(dir), _shell(glob), type_arg)
    os.execute(cmd)

    local check_cmd = string.format(
        "find '%s' -maxdepth 1 -name '%s' %s 2>/dev/null",
        _shell(dir), _shell(glob), type_arg)
    local f = io.popen(check_cmd)
    local leftover = f and f:read("*a") or ""
    if f then f:close() end

    if leftover ~= "" then
        logger.warn("[st_filesystem] purgeChildrenMatching: items remain in " .. dir)
        return false, "could not remove all matching items"
    end
    return true
end

return FS
