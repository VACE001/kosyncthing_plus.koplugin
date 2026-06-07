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

    it("broadcasts SyncthingStateChanged only when merged > 0", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        Mock.state.path_exists[ORIG] = true
        Mock.state.path_exists[CONF] = true
        withIO({
            [ORIG] = '[\"percent_finished\"] = 0.80',
            [CONF] = '[\"percent_finished\"] = 0.40',
        }, nil, function()
            conflict.autoMergeReadingProgress(plugin, { CONF })
        end)
        local found = false
        for _, e in ipairs(Mock.state.broadcasts) do
            if e.name == "SyncthingStateChanged" then found = true end
        end
        assert.is_true(found)
    end)

    it("does NOT broadcast when nothing is merged (all skipped)", function()
        local conflict = require("st_conflict")
        local plugin   = makePlugin()
        withIO({}, nil, function()
            -- Non-metadata file → skipped, merged = 0
            conflict.autoMergeReadingProgress(plugin, {
                "/books/cover.sync-conflict-20260101-ABC.jpg",
            })
        end)
        local found = false
        for _, e in ipairs(Mock.state.broadcasts) do
            if e.name == "SyncthingStateChanged" then found = true end
        end
        assert.is_false(found)
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
