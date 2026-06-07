-- st_conflict.lua – Conflict detection and resolution
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local util        = require("util")
local _           = require("syncthing_i18n").gettext
local T           = require("ffi/util").template

local ok_lfs, lfs = pcall(require, "lfs")
local FS = require("st_filesystem")

-- Format a Unix timestamp to a short human-readable date+time string.
local function formatMtime(t)
    if not t then return _("unknown") end
    return os.date("%Y-%m-%d %H:%M", t)
end

-- Read the modification time of a file.  Returns nil if lfs is not
-- available or the file does not exist.
local function fileMtime(path)
    if not ok_lfs then return nil end
    local attr = lfs.attributes(path)
    return attr and attr.modification or nil
end

local function deriveOriginalPath(conflict_path)
    return conflict_path:gsub("%.sync%-conflict%-[%d%-]+%-[%dA-Z]+(%.?[^/]*)$", "%1")
end

-- Extract the short device ID embedded in a conflict filename.
-- Syncthing names conflict files as:
--   <stem>.sync-conflict-YYYYMMDD-HHMMSS-<SHORTID>.<ext>
-- where SHORTID is the first 7 characters of the full Syncthing device ID
-- (the part before the first dash, e.g. "MFZWI3D" from
-- "MFZWI3D-BONSGYC-YLTMRWG-...").  The separator before "sync-conflict"
-- can be either "." or "~" depending on the Syncthing version / OS.
-- Returns nil when the pattern is not found.
local function _parseConflictShortId(conflict_path)
    local fname = conflict_path:match("([^/]+)$") or conflict_path
    return fname:match("[.~]sync%-conflict%-%d+%-%d+%-([A-Z0-9]+)")
end

-- Try to resolve a Syncthing short device ID to a human-readable device
-- name.  Calls self:getDevices() which requires the daemon to be running;
-- returns nil silently on any failure so callers can fall back gracefully.
local function _deviceNameForShortId(self, short_id)
    if not short_id or short_id == "" then return nil end
    local ok, devices = pcall(function() return self:getDevices() end)
    if not ok or type(devices) ~= "table" then return nil end
    for _, dev in ipairs(devices) do
        local did = type(dev) == "table" and dev.deviceID
        if type(did) == "string" and did:sub(1, #short_id) == short_id then
            local n = dev.name
            return (type(n) == "string" and n ~= "") and n or nil
        end
    end
    return nil
end

-- KOReader stores percent_finished as a float in [0, 1].
-- Pattern: ["percent_finished"] = 0.47
-- Older KOReader versions (pre-2022) wrote "last_percent" instead;
-- we fall back to it so conflicts from mixed-version setups show a
-- number rather than "unknown".
-- Returns the value as a number, or nil if absent / unreadable.
local function _readPercent(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    local v = content:match('"percent_finished"[^=]*=%s*([%d%.]+)')
           or content:match('"last_percent"[^=]*=%s*([%d%.]+)')
    return v and tonumber(v) or nil
end

local function resolveConflict(self, conflict_path, touchmenu_instance)
    local original_path = deriveOriginalPath(conflict_path)
    local FS = require("st_filesystem")

    if original_path == conflict_path then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_(
                "Could not determine the original file path from:\n%1\n\n" ..
                "This conflict file will need to be resolved manually."),
                conflict_path)
        })
        return
    end

    local original_exists = util.pathExists(original_path)
    -- Detect KOReader metadata sidecar files
    local is_main_metadata = conflict_path:match("%.sdr/metadata%.[^/]+%.lua$") ~= nil
    local has_reading_progress = false
    if is_main_metadata then
        -- Check both files: if either side has a percent field the dialog
        -- is meaningful. Checking only the conflict copy missed the case
        -- where the original was written by an older KOReader build that
        -- used "last_percent" instead of "percent_finished".
        local function _fileHasPercent(path)
            local f = io.open(path, "r")
            if not f then return false end
            local c = f:read("*a")
            f:close()
            return c ~= nil
                and (c:match('"percent_finished"') ~= nil
                  or c:match('"last_percent"')     ~= nil)
        end
        has_reading_progress = _fileHasPercent(conflict_path)
                            or _fileHasPercent(original_path)
    end

    local function displayName(p)
        local book = p:match("/([^/]+)%.sdr/")
        if book then return book end
        local fname = p:match("([^/]+)$") or p
        return fname:gsub("%.sync%-conflict%-[%d%-]+%-[%dA-Z]+", "")
    end

    local name = displayName(conflict_path)

	local function doKeepLocal()
		local ok, err = FS.remove(conflict_path)
		if ok then
			self:_cacheInvalidate()
			self:_invalidateConflictCache()
			if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
			if touchmenu_instance then touchmenu_instance:updateItems() end
			UIManager:show(InfoMessage:new{
				timeout = 2,
				text    = T(_("Kept your version of \"%1\". Conflict copy deleted."), name),
			})
		else
			UIManager:show(InfoMessage:new{
				icon = "notice-warning",
				text = T(_("Failed to delete conflict copy: %1\n\nCheck file permissions."), tostring(err)),
			})
		end
	end
	
		local function doUseConflict()
		UIManager:show(ConfirmBox:new{
			text        = T(_("Replace your local \"%1\" with the conflict copy?\n\nThis cannot be undone."), name),
			ok_text     = _("Yes, replace it"),
			cancel_text = _("Cancel"),
			ok_callback = function()
				local ok, err = FS.rename(conflict_path, original_path)
				if ok then
					self:_cacheInvalidate()
					self:_invalidateConflictCache()
					if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
					if touchmenu_instance then touchmenu_instance:updateItems() end
					UIManager:show(InfoMessage:new{
						timeout = 2,
						text    = T(_("Conflict version of \"%1\" applied."), name),
					})
				else
					UIManager:show(InfoMessage:new{
						icon = "notice-warning",
						text = T(_("Failed to apply conflict version: %1\n\nCheck file permissions."), tostring(err)),
					})
				end
			end,
		})
	end

    if not original_exists then
        UIManager:show(ConfirmBox:new{
            text        = T(_(
                "Conflict: \"%1\"\n\n" ..
                "Your original file no longer exists.\n\n" ..
                "Keep this conflict copy as the new file, or discard it?"), name),
            ok_text     = _("Keep as new file"),
            cancel_text = _("Discard it"),
            ok_callback = function()
                local ok, err = FS.rename(conflict_path, original_path)
                if ok then
                    self:_cacheInvalidate()
                    self:_invalidateConflictCache()
                    if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{
                        timeout = 2,
                        text    = T(_("Saved as \"%1\"."), name),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        text    = T(_("Failed to save: %1"), tostring(err)),
                    })
                end
            end,
            cancel_callback = function()
                local ok, err = FS.remove(conflict_path)
                if ok then
                    self:_cacheInvalidate()
                    self:_invalidateConflictCache()
                    if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    UIManager:show(InfoMessage:new{ timeout = 2, text = _("Conflict copy discarded.") })
                else
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        timeout = 2,
                        text = T(_("Failed to discard conflict copy: %1"), tostring(err)),
                    })
                end
            end,
        })
        return
    end

    if has_reading_progress then
        local orig_raw = _readPercent(original_path)
        local conf_raw = _readPercent(conflict_path)
        local orig_pct = orig_raw and math.floor(orig_raw * 100 + 0.5) or nil
        local conf_pct = conf_raw and math.floor(conf_raw * 100 + 0.5) or nil
        local orig_str = orig_pct and (orig_pct .. "%") or _("unknown")
        local conf_str = conf_pct and (conf_pct .. "%") or _("unknown")

        UIManager:show(ConfirmBox:new{
            text = T(_(
                "Reading progress conflict: \"%1\"\n\n" ..
                "Your device:   %2\n" ..
                "Other device:  %3\n\n" ..
                "Keep which version?"),
                name, orig_str, conf_str),
            ok_text         = T(_("Mine (%1)"),   orig_str),
            cancel_text     = T(_("Theirs (%1)"), conf_str),
            ok_callback     = doKeepLocal,
            cancel_callback = doUseConflict,
        })
        return
    end

    -- For non-metadata files, show file timestamps so the user can make
    -- an informed choice: the newer mtime almost always means the more recent edit.
    -- Best-effort: also try to resolve the short device ID embedded in the
    -- conflict filename to a human-readable device name.  Falls back silently
    -- (no name shown) when the daemon is not running or the device is unknown.
    local orig_mtime = fileMtime(original_path)
    local conf_mtime = fileMtime(conflict_path)
    local orig_ts    = formatMtime(orig_mtime)
    local conf_ts    = formatMtime(conf_mtime)

    local short_id   = _parseConflictShortId(conflict_path)
    local my_short   = (function()
        local ok, id = pcall(function() return self:getDeviceId() end)
        return (ok and type(id) == "string") and id:sub(1, 7) or nil
    end)()
    local conf_device_name
    if short_id and my_short and short_id == my_short:upper() then
        -- The conflict copy is OUR own version that Syncthing moved aside
        -- because the remote write arrived first.
        conf_device_name = _("this device")
    else
        conf_device_name = _deviceNameForShortId(self, short_id)
    end
    local conf_ts_full = conf_device_name
        and (conf_ts .. " (" .. conf_device_name .. ")")
        or  conf_ts

    local newer_hint = ""
    if orig_mtime and conf_mtime then
        if orig_mtime > conf_mtime then
            newer_hint = _("\n\n-> Your version is newer.")
        elseif conf_mtime > orig_mtime then
            newer_hint = _("\n\n-> The other version is newer.")
        else
            newer_hint = _("\n\n-> Both versions have the same timestamp.")
        end
    end

    UIManager:show(ConfirmBox:new{
        text = T(_(
            "File conflict: \"%1\"\n\n"
            .. "Your version:   %2\n"
            .. "Other version:  %3%4\n\n"
            .. "Keep which version?"),
            name, orig_ts, conf_ts_full, newer_hint),
        ok_text         = T(_("Mine (%1)"),   orig_ts),
        cancel_text     = T(_("Theirs (%1)"), conf_ts_full),
        ok_callback     = doKeepLocal,
        cancel_callback = doUseConflict,
    })
end

---------------------------------------------------------------------------
-- autoMergeReadingProgress(conflict_paths)
--
-- For each conflict in the list:
--   * if it's a KOReader metadata file with a percent_finished value in
--     both the local and conflict copy, keep whichever has the higher
--     reading progress;
--   * otherwise leave it untouched.
--
-- This is the unique-to-KOReader resolution strategy: when two devices
-- read the same book and sync, you almost always want the version that
-- read further, not "mine vs theirs" by chance.
--
-- Returns a summary table:
--   { merged = N, kept_local = N, kept_remote = N, skipped = N, failed = N }
---------------------------------------------------------------------------


local function autoMergeReadingProgress(self, conflict_paths)
    local stats = { merged = 0, kept_local = 0, kept_remote = 0, skipped = 0, failed = 0 }

    for _, conflict_path in ipairs(conflict_paths) do
        -- Use the same metadata detector that resolveConflict uses, so we
        -- never apply this logic to a non-metadata file by accident.
        local is_metadata =
            conflict_path:match("%.sdr/metadata%.[^/]+%.lua$") ~= nil

        if not is_metadata then
            stats.skipped = stats.skipped + 1
        else
            local original_path = deriveOriginalPath(conflict_path)
            if original_path == conflict_path then
                stats.skipped = stats.skipped + 1
            else
                local local_pct  = _readPercent(original_path)
                local remote_pct = _readPercent(conflict_path)

                if not local_pct or not remote_pct then
                    -- Can't compare safely — leave for manual review.
                    stats.skipped = stats.skipped + 1
				elseif remote_pct > local_pct then
					local ok, err = FS.rename(conflict_path, original_path)
					if ok then
						stats.merged = stats.merged + 1; stats.kept_remote = stats.kept_remote + 1
					else
						stats.failed = stats.failed + 1
						logger.warn("[Syncthing] autoMerge: rename failed for " .. conflict_path .. ": " .. tostring(err))
					end
				else
					local ok, err = FS.remove(conflict_path)
					if ok then
						stats.merged = stats.merged + 1; stats.kept_local = stats.kept_local + 1
					else
						stats.failed = stats.failed + 1
						logger.warn("[Syncthing] autoMerge: remove failed for " .. conflict_path .. ": " .. tostring(err))
					end
                end
            end
        end
    end

    self:_cacheInvalidate()
    self:_invalidateConflictCache()

    -- If we actually merged anything, fire the notifier directly so
    -- companion plugins (e.g. an "open the next file with conflicts"
    -- workflow) see the change immediately.  Without this the notifier
    -- only fires when something later calls findConflicts (which may
    -- not happen for a long time on an idle device).  We pass nil here
    -- because the merged conflicts have been removed and the recipient
    -- should re-fetch — see notifyConflictsChanged in st_api_public.
    if stats.merged > 0 then
        if self._notifiers then self._notifiers.notifyConflictsChanged(nil) end
        -- Update any open menu immediately rather than waiting for the next health cycle
        -- UIManager is imported at module level; require Event once (cached by Lua).
        UIManager:broadcastEvent(require("ui/event"):new("SyncthingStateChanged"))
    end

    return stats
end

local function getConflictsDetailed(self)
    local conflicts = self:findConflicts()
    local result = {}
    for _, cp in ipairs(conflicts) do
        local orig = deriveOriginalPath(cp)
        local is_metadata = cp:match("%.sdr/metadata%.[^/]+%.lua$") ~= nil
        local has_progress = false
        local local_pct, remote_pct
        if is_metadata then
            if orig and orig ~= cp then
                local_pct  = _readPercent(orig)
                remote_pct = _readPercent(cp)
                if local_pct or remote_pct then
                    has_progress = true
                end
            end
        end
        local orig_mtime = fileMtime(orig)
        local conf_mtime = fileMtime(cp)
        table.insert(result, {
            path            = cp,
            original_path   = orig,
            is_metadata     = is_metadata,
            has_progress    = has_progress,
            local_progress  = local_pct and math.floor(local_pct * 100 + 0.5) or nil,
            remote_progress = remote_pct and math.floor(remote_pct * 100 + 0.5) or nil,
            local_mtime     = orig_mtime,
            remote_mtime    = conf_mtime,
        })
    end
    return result
end

return {
    resolveConflict          = resolveConflict,
    deriveOriginalPath       = deriveOriginalPath,
    autoMergeReadingProgress = autoMergeReadingProgress,
    getConflictsDetailed     = getConflictsDetailed,
    parseConflictShortId     = _parseConflictShortId,
    deviceNameForShortId     = _deviceNameForShortId,
}
