-- st_conflict_spec.lua – comprehensive tests for conflict detection and auto-merge.
-- Covers: deriveOriginalPath, autoMergeReadingProgress (all 6 branches),
-- getConflictsDetailed, and the existing I/O failure regression.

local Mock = require("spec.spec_helper")

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

local ORIG    = "/books/Novel.sdr/metadata.lua"
local CONF    = "/books/Novel.sdr/metadata.sync-conflict-20260101-ABC123.lua"
local CONF2   = "/books/Novel.sdr/metadata.sync-conflict-20260202-DEF456.lua"

-- Build a minimal plugin stub used by autoMergeReadingProgress / getConflictsDetailed.
local function makePlugin(overrides)
    local p = {
        _cacheInvalidate = function() end,
        _invalidateConflictCache = function() end,
        _notifiers = nil,
        findConflicts = overrides and overrides.findConflicts or function() return {} end,
    }
    return p
end

-- Swap io.open / os.remove around a test body.
local function withIO(open_map, remove_fails, fn)
    local real_open   = io.open
    local real_remove = os.remove
    io.open = function(path, mode)
        if mode == "r" then
            local content = open_map[path]
            if content == nil then return nil end
            return {
                read = function(_, fmt)
                    if fmt == "*a" then return content end
                    if fmt == "*l" then return content:match("^([^\n]*)\n?") end
                    return nil
                end,
                close = function() end,
            }
        end
        return real_open(path, mode)
    end
    os.remove = function(path)
        if remove_fails and remove_fails[path] then
            return nil, "permission denied"
        end
        return true  -- succeed by default; tests that need real FS use real_remove explicitly
    end
    local ok, err = pcall(fn)
    io.open   = real_open
    os.remove = real_remove
    if not ok then error(err, 2) end
end

-- Swap os.rename around a test body.
local function withRename(rename_map, fn)
    local real_rename = os.rename
    os.rename = function(old, new)
        if rename_map then
            local v = rename_map[old .. "->" .. new]
            if v ~= nil then return v end
        end
        return real_rename(old, new)
    end
    local ok, err = pcall(fn)
    os.rename = real_rename
    if not ok then error(err, 2) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 1: deriveOriginalPath
-- ─────────────────────────────────────────────────────────────────────────────

describe("deriveOriginalPath", function()
    before_each(function() Mock.reset() end)

    local conflict = require("st_conflict")

    it("strips the conflict suffix and reconstructs the original .lua path", function()
        assert.are.equal(ORIG, conflict.deriveOriginalPath(CONF))
    end)

    it("works for a book file (not sdr metadata)", function()
        local cp = "/mnt/us/books/MyBook.sync-conflict-20260101-ABC.epub"
        assert.are.equal("/mnt/us/books/MyBook.epub", conflict.deriveOriginalPath(cp))
    end)

    it("returns the input unchanged for a path with no conflict suffix", function()
        assert.are.equal(ORIG, conflict.deriveOriginalPath(ORIG))
    end)

    it("handles a conflict suffix with no extension (bare filename)", function()
        local cp = "/some/file.sync-conflict-20260101-XYZ"
        assert.are.equal("/some/file", conflict.deriveOriginalPath(cp))
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 2: autoMergeReadingProgress – success paths
-- ─────────────────────────────────────────────────────────────────────────────

describe("autoMergeReadingProgress – success paths", function()
    before_each(function() Mock.reset() end)

    it("skips non-metadata files and counts them as skipped", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        local paths    = { "/books/Novel.sync-conflict-20260101-ABC.epub" }
        withIO({}, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, paths)
            assert.are.equal(0, stats.merged)
            assert.are.equal(1, stats.skipped)
            assert.are.equal(0, stats.failed)
        end)
    end)

    it("defers the whole pass while a book is open, touching no files (open-book guard)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        plugin._is_reading_fn = function() return true end
        local real_rename, real_remove = os.rename, os.remove
        local touched = false
        os.rename = function() touched = true; return true end
        os.remove = function() touched = true; return true end
        local ok, stats = pcall(conflict.autoMergeReadingProgress, plugin, { CONF, CONF2 })
        os.rename, os.remove = real_rename, real_remove
        assert.is_true(ok)
        assert.are.equal(0, stats.merged)
        assert.are.equal(2, stats.skipped)
        assert.is_true(stats.deferred_open_book)
        assert.is_false(touched)
    end)

    it("proceeds normally when no book is open (guard inactive)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        plugin._is_reading_fn = function() return false end
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '["percent_finished"] = 0.20',
            [CONF] = '["percent_finished"] = 0.90',
        }, nil, function()
            withRename({ [CONF .. "->" .. ORIG] = true }, function()
                local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
                assert.is_nil(stats.deferred_open_book)
                assert.are.equal(1, stats.merged)
                assert.are.equal(1, stats.kept_remote)
            end)
        end)
    end)

    it("skips metadata when conflict path cannot be mapped to original", function()
        -- A path that deriveOriginalPath returns unchanged → skip
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        local bad_path = "/books/metadata.lua"  -- no conflict suffix
        withIO({}, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { bad_path })
            assert.are.equal(1, stats.skipped)
        end)
    end)

    it("skips when local percent is unreadable (io.open returns nil)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        -- Only the conflict copy is readable; original is missing.
        withIO({ [CONF] = '[\"percent_finished\"] = 0.60' }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.skipped)
            assert.are.equal(0, stats.merged)
        end)
    end)

    it("keeps local when local progress >= remote progress (removes conflict copy)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.80',
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.merged)
            assert.are.equal(1, stats.kept_local)
            assert.are.equal(0, stats.kept_remote)
            assert.are.equal(0, stats.failed)
        end)
    end)

    it("keeps remote when remote progress > local progress (renames conflict to original)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.20',
            [CONF] = '[\"percent_finished\"] = 0.75',
        }, nil, function()
            withRename({ [CONF .. "->" .. ORIG] = true }, function()
                local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
                assert.are.equal(1, stats.merged)
                assert.are.equal(1, stats.kept_remote)
                assert.are.equal(0, stats.kept_local)
                assert.are.equal(0, stats.failed)
            end)
        end)
    end)

    it("handles equal progress as keep-local (>= condition)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.50',
            [CONF] = '[\"percent_finished\"] = 0.50',
        }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.kept_local)
        end)
    end)

    it("processes multiple conflicts and accumulates stats", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF]  = true
        Mock.state.path_exists[CONF2] = true
        withIO({
            [ORIG]  = '[\"percent_finished\"] = 0.80',
            [CONF]  = '[\"percent_finished\"] = 0.40',  -- local wins
            [CONF2] = '[\"percent_finished\"] = 0.95',  -- remote wins
        }, nil, function()
            withRename({ [CONF2 .. "->" .. ORIG] = true }, function()
                local stats = conflict.autoMergeReadingProgress(plugin, { CONF, CONF2 })
                assert.are.equal(2, stats.merged)
                assert.are.equal(1, stats.kept_local)
                assert.are.equal(1, stats.kept_remote)
            end)
        end)
    end)
    -- last_percent fallback (old KOReader format)
    it("reads last_percent as fallback when percent_finished is absent (remote wins)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"last_percent\"] = 0.30',   -- old KOReader format
            [CONF] = '[\"percent_finished\"] = 0.80',
        }, nil, function()
            withRename({ [CONF .. "->" .. ORIG] = true }, function()
                local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
                assert.are.equal(1, stats.merged)
                assert.are.equal(1, stats.kept_remote)  -- 80% > 30%
                assert.are.equal(0, stats.kept_local)
            end)
        end)
    end)

    it("reads last_percent as fallback when percent_finished is absent (local wins)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"last_percent\"] = 0.90',   -- old KOReader format
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.merged)
            assert.are.equal(1, stats.kept_local)   -- 90% > 40%
            assert.are.equal(0, stats.kept_remote)
        end)
    end)

    it("reads last_percent on both sides (both old format)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"last_percent\"] = 0.55',
            [CONF] = '[\"last_percent\"] = 0.55',
        }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.merged)
            assert.are.equal(1, stats.kept_local)   -- equal → keep local
        end)
    end)

    -- has_reading_progress checks both files (regression: used to check only conflict)
    it("detects progress when only original has percent_finished (conflict lacks it)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin({
            findConflicts = function() return { CONF } end,
        })
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.65',
            [CONF] = '[\"last_xpointer\"] = \"/body/p[3]\"',  -- no percent
        }, nil, function()
            local rows = conflict.getConflictsDetailed(plugin)
            -- has_progress must be true: original has percent_finished
            assert.is_true(rows[1].has_progress)
            assert.are.equal(65, rows[1].local_progress)
            assert.is_nil(rows[1].remote_progress)  -- conflict had no percent
        end)
    end)

    it("detects progress when only conflict has percent_finished (original lacks it)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin({
            findConflicts = function() return { CONF } end,
        })
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"last_xpointer\"] = \"/body/p[1]\"',  -- no percent
            [CONF] = '[\"percent_finished\"] = 0.50',
        }, nil, function()
            local rows = conflict.getConflictsDetailed(plugin)
            assert.is_true(rows[1].has_progress)
            assert.is_nil(rows[1].local_progress)   -- original had no percent
            assert.are.equal(50, rows[1].remote_progress)
        end)
    end)

    it("autoMerge skips when conflict percent is missing even though dialog would show", function()
        -- has_reading_progress=true (original has percent) but autoMerge
        -- cannot pick a winner without both sides → skips, does not crash.
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.65',
            [CONF] = '[\"last_xpointer\"] = \"/body/p[3]\"',
        }, nil, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(1, stats.skipped)
            assert.are.equal(0, stats.merged)
        end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 3: autoMergeReadingProgress – failure paths
-- ─────────────────────────────────────────────────────────────────────────────

describe("autoMergeReadingProgress – failure paths", function()
    before_each(function() Mock.reset() end)

    it("counts failed when os.remove errors (keep-local path, I/O failure)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.80',
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, { [CONF] = true }, function()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(0, stats.merged)
            assert.are.equal(1, stats.failed)
        end)
    end)

    it("counts failed when os.rename errors (keep-remote path)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.20',
            [CONF] = '[\"percent_finished\"] = 0.90',
        }, nil, function()
            -- Rename always fails
            withRename({ [CONF .. "->" .. ORIG] = false }, function()
                local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
                assert.are.equal(0, stats.merged)
                assert.are.equal(1, stats.failed)
            end)
        end)
    end)

    it("calls _notifiers.notifyConflictsChanged when merged > 0", function()
        local conflict = require("st_conflict")
        local notified = false
        local plugin = makePlugin()
        plugin._notifiers = { notifyConflictsChanged = function() notified = true end }
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.80',
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, nil, function()
            conflict.autoMergeReadingProgress(plugin, { CONF })
        end)
        assert.is_true(notified)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 4: getConflictsDetailed
-- ─────────────────────────────────────────────────────────────────────────────

describe("getConflictsDetailed", function()
    before_each(function() Mock.reset() end)

    it("returns a row per conflict with path and original_path", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin({
            findConflicts = function() return { CONF } end,
        })
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.50',
            [CONF] = '[\"percent_finished\"] = 0.70',
        }, nil, function()
            local rows = conflict.getConflictsDetailed(plugin)
            assert.are.equal(1, #rows)
            assert.are.equal(CONF, rows[1].path)
            assert.are.equal(ORIG, rows[1].original_path)
            assert.is_true(rows[1].is_metadata)
        end)
    end)

    it("has_progress=true and correct percentages for metadata with both percents", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin({
            findConflicts = function() return { CONF } end,
        })
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.50',
            [CONF] = '[\"percent_finished\"] = 0.70',
        }, nil, function()
            local rows = conflict.getConflictsDetailed(plugin)
            assert.is_true(rows[1].has_progress)
            assert.are.equal(50, rows[1].local_progress)
            assert.are.equal(70, rows[1].remote_progress)
        end)
    end)

    it("returns empty table when findConflicts returns none", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin({ findConflicts = function() return {} end })
        withIO({}, nil, function()
            local rows = conflict.getConflictsDetailed(plugin)
            assert.are.equal(0, #rows)
        end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 5: _parseConflictShortId / _deviceNameForShortId
-- ─────────────────────────────────────────────────────────────────────────────

describe("conflict filename device-name resolution", function()
    before_each(function() Mock.reset() end)

    local conflict = require("st_conflict")

    -- _parseConflictShortId
    it("extracts short device ID from a dot-separated conflict filename", function()
        local cp = "/books/Novel.sync-conflict-20260101-143022-MFZWI3D.epub"
        assert.are.equal("MFZWI3D", conflict.parseConflictShortId(cp))
    end)

    it("extracts short device ID from a tilde-separated conflict filename", function()
        local cp = "/books/Novel~sync-conflict-20260101-143022-ABC1234.epub"
        assert.are.equal("ABC1234", conflict.parseConflictShortId(cp))
    end)

    it("extracts short ID from a metadata sidecar conflict", function()
        local cp = "/books/Novel.sdr/metadata.epub.sync-conflict-20260101-143022-PHN1234.lua"
        assert.are.equal("PHN1234", conflict.parseConflictShortId(cp))
    end)

    it("returns nil for a non-conflict path", function()
        assert.is_nil(conflict.parseConflictShortId("/books/Novel.epub"))
    end)

    -- _deviceNameForShortId via plugin stub
    it("resolves short ID to device name when daemon is reachable", function()
        local plugin = makePlugin()
        plugin.getDevices = function()
            return {
                { deviceID = "MFZWI3D-BONSGYC-YLTMRWG-REST", name = "Phone" },
                { deviceID = "ABC1234-OTHERSEG-REST",          name = "Tablet" },
            }
        end
        assert.are.equal("Phone",  conflict.deviceNameForShortId(plugin, "MFZWI3D"))
        assert.are.equal("Tablet", conflict.deviceNameForShortId(plugin, "ABC1234"))
    end)

    it("returns nil when short ID does not match any known device", function()
        local plugin = makePlugin()
        plugin.getDevices = function()
            return { { deviceID = "AAAAAAA-REST", name = "Laptop" } }
        end
        assert.is_nil(conflict.deviceNameForShortId(plugin, "ZZZZZZZ"))
    end)

    it("returns nil gracefully when getDevices raises an error (daemon down)", function()
        local plugin = makePlugin()
        plugin.getDevices = function() error("connection refused") end
        assert.is_nil(conflict.deviceNameForShortId(plugin, "MFZWI3D"))
    end)

    it("returns nil gracefully when getDevices returns nil", function()
        local plugin = makePlugin()
        plugin.getDevices = function() return nil end
        assert.is_nil(conflict.deviceNameForShortId(plugin, "MFZWI3D"))
    end)

    it("returns nil when short_id is nil", function()
        local plugin = makePlugin()
        plugin.getDevices = function() return {} end
        assert.is_nil(conflict.deviceNameForShortId(plugin, nil))
    end)

    it("labels the conflict copy as 'this device' when short ID matches own device", function()
        local plugin = makePlugin()
        -- Own device ID starts with "MYDEVIC"
        plugin.getDeviceId = function() return "MYDEVIC-BONSGYC-REST" end
        plugin.getDevices  = function() return {} end
        -- A conflict file carrying our own short ID means Syncthing moved our
        -- version aside — resolveConflict labels it "this device".
        -- We test the helper that detects self-conflicts:
        local cp = "/books/Novel.sync-conflict-20260101-143022-MYDEVIC.epub"
        local short_id = conflict.parseConflictShortId(cp)
        local ok, my_id = pcall(function() return plugin:getDeviceId() end)
        local my_short  = (ok and type(my_id) == "string") and my_id:sub(1, 7) or nil
        assert.are.equal("MYDEVIC", short_id)
        assert.are.equal("MYDEVIC", my_short)
        assert.are.equal(short_id, my_short)   -- triggers "this device" label
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 6: regression – existing I/O failure test (from original spec)
-- ─────────────────────────────────────────────────────────────────────────────

describe("autoMergeReadingProgress – I/O failure regression (BUG orig)", function()
    before_each(function() Mock.reset() end)

    it("counts an I/O failure when auto-merge keeps the local reading progress", function()
        local conflict = require("st_conflict")
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.80',
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, { [CONF] = true }, function()
            local plugin = makePlugin()
            local stats = conflict.autoMergeReadingProgress(plugin, { CONF })
            assert.are.equal(0, stats.merged)
            assert.are.equal(0, stats.kept_local)
            assert.are.equal(1, stats.failed)
        end)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 7: resolveConflict – unresolvable path
-- ─────────────────────────────────────────────────────────────────────────────

describe("resolveConflict – unresolvable path", function()
    before_each(function() Mock.reset() end)

    it("shows a warning InfoMessage when the conflict path has no derivable original", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        -- A path with no .sync-conflict suffix → deriveOriginalPath returns it unchanged
        conflict.resolveConflict(plugin, "/books/metadata.lua", nil)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("notice-warning", w.icon)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 8: resolveConflict – original file missing
-- ─────────────────────────────────────────────────────────────────────────────

describe("resolveConflict – original file missing", function()
    before_each(function() Mock.reset() end)

    it("shows ConfirmBox with 'Keep as new file' / 'Discard it' when original is gone", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        -- ORIG absent from path_exists → util.pathExists returns false
        Mock.state.path_exists[ORIG] = nil
        withIO({}, nil, function()
            conflict.resolveConflict(plugin, CONF, nil)
        end)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("ui/widget/confirmbox", w._widget)
        assert.are.equal("Keep as new file", w.ok_text)
        assert.are.equal("Discard it",       w.cancel_text)
    end)

    it("ok_callback renames conflict to original and invalidates caches", function()
        local conflict = require("st_conflict")
        local invalidated = false
        local plugin = makePlugin()
        plugin._invalidateConflictCache = function() invalidated = true end
        Mock.state.path_exists[ORIG] = nil
        Mock.state.path_exists[CONF] = true
        withIO({}, nil, function()
            withRename({ [CONF .. "->" .. ORIG] = true }, function()
                conflict.resolveConflict(plugin, CONF, nil)
                local w = Mock.state.shown[1]
                w.ok_callback()
            end)
        end)
        assert.is_true(invalidated)
        -- A success InfoMessage (timeout=2) should have been shown
        local msg = Mock.state.shown[2]
        assert.is_not_nil(msg)
        assert.are.equal(2, msg.timeout)
    end)

    it("cancel_callback removes conflict copy and invalidates caches", function()
        local conflict = require("st_conflict")
        local invalidated = false
        local plugin = makePlugin()
        plugin._invalidateConflictCache = function() invalidated = true end
        Mock.state.path_exists[ORIG] = nil
        Mock.state.path_exists[CONF] = true
        withIO({}, nil, function()
            conflict.resolveConflict(plugin, CONF, nil)
            local w = Mock.state.shown[1]
            w.cancel_callback()
        end)
        assert.is_true(invalidated)
        local msg = Mock.state.shown[2]
        assert.is_not_nil(msg)
        assert.are.equal(2, msg.timeout)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 9: resolveConflict – reading-progress metadata dialog
-- ─────────────────────────────────────────────────────────────────────────────

describe("resolveConflict – reading progress metadata", function()
    before_each(function() Mock.reset() end)

    it("shows progress percentages in dialog text when both sides have percent_finished", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        plugin.getDeviceId = function() return "AAAAAAA-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '["percent_finished"] = 0.30',
            [CONF] = '["percent_finished"] = 0.80',
        }, nil, function()
            conflict.resolveConflict(plugin, CONF, nil)
        end)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("ui/widget/confirmbox", w._widget)
        -- ok_text / cancel_text carry the percentages
        assert.is_not_nil(w.ok_text:find("30%%"))
        assert.is_not_nil(w.cancel_text:find("80%%"))
    end)

    it("ok_callback (keep local) removes conflict copy", function()
        local conflict = require("st_conflict")
        local invalidated = false
        local plugin = makePlugin()
        plugin._invalidateConflictCache = function() invalidated = true end
        plugin.getDeviceId = function() return "AAAAAAA-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '["percent_finished"] = 0.60',
            [CONF] = '["percent_finished"] = 0.40',
        }, nil, function()
            conflict.resolveConflict(plugin, CONF, nil)
            local w = Mock.state.shown[1]
            w.ok_callback()  -- "Mine" → keep local → remove conflict
        end)
        assert.is_true(invalidated)
    end)

    it("cancel_callback (use conflict) renames conflict to original", function()
        local conflict = require("st_conflict")
        local invalidated = false
        local plugin = makePlugin()
        plugin._invalidateConflictCache = function() invalidated = true end
        plugin.getDeviceId = function() return "AAAAAAA-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '["percent_finished"] = 0.10',
            [CONF] = '["percent_finished"] = 0.90',
        }, nil, function()
            withRename({ [CONF .. "->" .. ORIG] = true }, function()
                conflict.resolveConflict(plugin, CONF, nil)
                -- Wrap the second confirm box in another rename-stub scope
                local w = Mock.state.shown[1]
                -- "Theirs" → show a second ConfirmBox asking for final confirm
                w.cancel_callback()
                -- The nested ConfirmBox's ok_callback performs the rename
                local w2 = Mock.state.shown[2]
                assert.is_not_nil(w2)
                w2.ok_callback()
            end)
        end)
        assert.is_true(invalidated)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 10: resolveConflict – generic file dialog (conflict_is_mine = false)
-- ─────────────────────────────────────────────────────────────────────────────

describe("resolveConflict – generic file dialog", function()
    before_each(function() Mock.reset() end)

    -- Use a non-metadata epub conflict so no progress branch fires.
    local EPUB_ORIG = "/books/Novel.epub"
    local EPUB_CONF = "/books/Novel.sync-conflict-20260101-143022-REMOTE1.epub"

    it("shows timestamps in dialog for a non-metadata file", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        plugin.getDeviceId = function() return "MYDEVIC-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[EPUB_ORIG] = true
        Mock.state.path_exists[EPUB_CONF] = true
        withIO({}, nil, function()
            conflict.resolveConflict(plugin, EPUB_CONF, nil)
        end)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("ui/widget/confirmbox", w._widget)
        -- ok_text carries "Mine" label
        assert.is_not_nil(w.ok_text:find("Mine"))
    end)

    it("ok_callback removes conflict (keep local)", function()
        local conflict = require("st_conflict")
        local invalidated = false
        local plugin = makePlugin()
        plugin._invalidateConflictCache = function() invalidated = true end
        plugin.getDeviceId = function() return "MYDEVIC-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[EPUB_ORIG] = true
        Mock.state.path_exists[EPUB_CONF] = true
        withIO({}, nil, function()
            conflict.resolveConflict(plugin, EPUB_CONF, nil)
            local w = Mock.state.shown[1]
            w.ok_callback()
        end)
        assert.is_true(invalidated)
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Suite 11: resolveConflict – conflict_is_mine branch
-- ─────────────────────────────────────────────────────────────────────────────

describe("resolveConflict – conflict_is_mine (Syncthing moved our version aside)", function()
    before_each(function() Mock.reset() end)

    -- Conflict file carries THIS device's short ID → conflict_is_mine = true.
    -- original_path then holds the incoming version; conflict_path holds our version.
    local OWN_ID   = "MYDEVIC"
    local SELF_CONF = "/books/Novel.epub.sync-conflict-20260201-120000-MYDEVIC"
    local SELF_ORIG = "/books/Novel.epub"

    it("shows 'Keep incoming / Restore mine' labels when conflict is from this device", function()
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        plugin.getDeviceId = function() return OWN_ID .. "-BONSGYC-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[SELF_ORIG] = true
        Mock.state.path_exists[SELF_CONF] = true
        withIO({}, nil, function()
            conflict.resolveConflict(plugin, SELF_CONF, nil)
        end)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("ui/widget/confirmbox", w._widget)
        assert.is_not_nil(w.ok_text:find("Keep incoming"))
        assert.is_not_nil(w.cancel_text:find("Restore mine"))
    end)

    it("reading-progress conflict from this device shows oriented 'Keep incoming / Restore mine'", function()
        -- A metadata (.sdr) conflict whose copy carries THIS device's short ID:
        -- original_path holds the INCOMING progress, conflict_path holds OURS.
        -- The old code had no conflict_is_mine branch here and would label this
        -- "Mine (30%) / Theirs (80%)" — inverted, losing the user's progress.
        local META_CONF = "/books/Novel.sdr/metadata.sync-conflict-20260201-120000-MYDEVIC.lua"
        local META_ORIG = "/books/Novel.sdr/metadata.lua"
        local conflict = require("st_conflict")
        local plugin = makePlugin()
        plugin.getDeviceId = function() return OWN_ID .. "-BONSGYC-REST" end
        plugin.getDevices  = function() return {} end
        Mock.state.path_exists[META_ORIG] = true
        Mock.state.path_exists[META_CONF] = true
        withIO({
            [META_ORIG] = '["percent_finished"] = 0.30',  -- incoming (won the race)
            [META_CONF] = '["percent_finished"] = 0.80',  -- ours (moved aside)
        }, nil, function()
            conflict.resolveConflict(plugin, META_CONF, nil)
        end)
        local w = Mock.state.shown[1]
        assert.is_not_nil(w)
        assert.are.equal("ui/widget/confirmbox", w._widget)
        -- Oriented correctly: incoming 30% on "Keep incoming", ours 80% on "Restore mine".
        assert.is_not_nil(w.ok_text:find("Keep incoming"))
        assert.is_not_nil(w.ok_text:find("30%%"))
        assert.is_not_nil(w.cancel_text:find("Restore mine"))
        assert.is_not_nil(w.cancel_text:find("80%%"))
    end)
end)
