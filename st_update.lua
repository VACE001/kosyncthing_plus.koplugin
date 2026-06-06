-- st_update.lua – Binary download and update logic for KOSyncthing+
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Device      = require("device")
local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local ffiutil     = require("ffi/util")
local logger      = require("logger")
local socketutil  = require("socketutil")
local U           = require("st_utils")
local util        = require("util")
local _           = require("syncthing_i18n").gettext
local T           = ffiutil.template
local Guard       = require("st_guard")

local rapidjson_ok, rapidjson = pcall(require, "rapidjson")
local JSON = rapidjson_ok and rapidjson or require("json")

local tmp_tar_path     = U.plugin_path .. "syncthing_update.tar.gz"
local tmp_extract_path = U.plugin_path .. "syncthing_extract"

---------------------------------------------------------------------------
-- Transport helpers
---------------------------------------------------------------------------

-- Download via KOReader's built-in LuaSocket / LuaSec stack.
-- Works for both http:// and https:// URLs and follows redirects.
local function _downloadViaLua(url, save_path)
    local http   = require("socket.http")
    local socket = require("socket")

    local f, err = io.open(save_path, "wb")
    if not f then
        return false, "Cannot write to file: " .. (err or "unknown")
    end

    -- Wrap http.request in pcall so that socketutil:reset_timeout() and
    -- f:close() are guaranteed on every exit path — including when LuaSocket
    -- raises a Lua error (DNS failure, malformed URL, etc.).
    -- Previously neither was called on success OR failure (BUG-35/BUG-36).
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local req_ok, code, _, status = pcall(function()
        return socket.skip(1, http.request{
            url  = url,
            sink = socketutil.file_sink(f),
        })
    end)
    socketutil:reset_timeout()  -- always reset, even if http.request raised
    f:close()                   -- always close, even on failure

    if not req_ok then
        -- pcall caught a Lua error — remove the partial file
        os.remove(save_path)
        return false, "Download error: " .. tostring(code)
    end
    if code ~= 200 then
        os.remove(save_path)
        return false, "Request failed: " .. tostring(status or code)
    end
    return true
end

-- Download a file using the best available transport on the device.
-- Tries wget first (most common on Linux-based e-readers), then curl
-- (faster TLS, requires cacert.pem), and finally the pure-Lua LuaSocket
-- stack that ships with KOReader.
local function _downloadFile(url, save_path)
    -- 1. wget — widely available, no extra dependencies
    local wget_cmd = string.format(
        "wget -qO '%s' '%s' 2>/dev/null",
        U.shellEscape(save_path),
        U.shellEscape(url))
    if U.execOk(os.execute(wget_cmd)) then
        return true
    end

    -- 2. curl — faster and more secure when cacert.pem is present
    if U.curlAvailable() and U.cacertExists() then
        local dl_cmd = string.format(
            "curl -f -L -s --max-time 600 --cacert '%s' '%s' -o '%s'",
            U.shellEscape(U.cacert_path),
            U.shellEscape(url),
            U.shellEscape(save_path))
        if U.execOk(os.execute(dl_cmd)) then
            return true
        end
        return false, "curl failed (exit code non-zero). Check network and cacert.pem."
    end

    -- 3. KOReader built-in LuaSocket / LuaSec
    return _downloadViaLua(url, save_path)
end

---------------------------------------------------------------------------
-- Version & architecture helpers
---------------------------------------------------------------------------
local _version_cache = nil

local function getCurrentVersion(self)
    if _version_cache ~= nil then return _version_cache end
    if not util.pathExists(U.plugin_path .. "syncthing") then return nil end
    local p = io.popen("'" .. U.shellEscape(U.plugin_path .. "syncthing") .. "' --version 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a"); p:close()
    if not out then return nil end
    _version_cache = out:match("syncthing v(%d+%.%d+%.%d+)")
    return _version_cache
end

local function invalidateVersionCache(self)
    _version_cache = nil
end

local detectArch = U.detectArch

---------------------------------------------------------------------------
-- _finishInstallation: extract the archive, locate the syncthing binary,
-- atomically move it into the plugin folder, and announce the result.
---------------------------------------------------------------------------
local function _finishInstallation(self, version, post_install_callback, lease)
    os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
    local extract_ok, extract_err = Device:unpackArchive(tmp_tar_path, tmp_extract_path, true)
    if not extract_ok then
        os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
        os.execute("rm -f '"  .. U.shellEscape(tmp_tar_path)     .. "'")
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("The downloaded archive is corrupt or extraction failed.\n\nPlease try again.") ..
                   (extract_err and "\n\nDetails: " .. tostring(extract_err) or ""),
        })
        lease:release()
        if post_install_callback then post_install_callback() end
        return
    end

    local fp = io.popen(
        "find '" .. U.shellEscape(tmp_extract_path) .. "' -name syncthing -type f -maxdepth 3 2>/dev/null")
    local binary_path = fp and fp:read("*l")
    if fp then fp:close() end

    if not binary_path or binary_path == "" then
        os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
        os.execute("rm -f '"  .. U.shellEscape(tmp_tar_path)     .. "'")
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Syncthing binary not found inside the archive.\n\nThis is unexpected — please report this to the plugin author."),
        })
        lease:release()
        if post_install_callback then post_install_callback() end
        return
    end

    local should_restart = self:isRunning()

    local function do_install()
        if not util.pathExists(U.plugin_path) then
            if not util.makePath(U.plugin_path) then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = _("Could not create plugin directory.\nCheck file system permissions."),
                })
                lease:release()
                if post_install_callback then post_install_callback() end
                return
            end
        end

        local mv_ok = U.execOk(os.execute(string.format(
            "mv '%s' '%s'", U.shellEscape(binary_path), U.shellEscape(U.plugin_path .. "syncthing"))))

        os.execute("rm -rf '" .. U.shellEscape(tmp_extract_path) .. "'")
        os.execute("rm -f '"  .. U.shellEscape(tmp_tar_path)     .. "'")

        if not mv_ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Could not install the binary into the plugin folder.\n\nThe folder may be on a read-only filesystem."),
            })
            lease:release()
            if post_install_callback then post_install_callback() end
            return
        end

        os.execute("chmod +x '" .. U.shellEscape(U.plugin_path .. "syncthing") .. "'")
        self:_invalidateBinaryCache()
        self:_invalidateVersionCache()
        self:_cacheInvalidate()

        UIManager:show(InfoMessage:new{
            text = should_restart
                and T(_("Syncthing updated to v%1 and restarting…"), version)
                or  T(_("Syncthing v%1 installed!\n\nYou can now start syncing."), version),
            -- Show the password suggestion right after the user dismisses
            -- the success message, so they can secure the GUI immediately.
            dismiss_callback = function()
                if self._suggestPassword and not self.gui_password then
                    self:_suggestPassword()
                end
            end,
        })

        lease:release()
        if should_restart then
            self._silentStart = true
            self:start(post_install_callback)
        elseif post_install_callback then
            post_install_callback()
        end
    end

    if should_restart then self:stop(do_install) else do_install() end
end

---------------------------------------------------------------------------
-- Perform the actual download and installation
---------------------------------------------------------------------------
local function performUpdate(self, url, version, expected_size, post_install_callback)
    local dl_msg = InfoMessage:new{
        text = T(_(
            "Downloading Syncthing v%1…\n\n" ..
            "This may take a few minutes.\n" ..
            "Please do not close KOReader."), version)
    }
    UIManager:show(dl_msg)
    local lease = Guard:acquire("update_download", {
        standby  = true,
        wakelock = true,
    })
    UIManager:scheduleIn(0.1, function()
        os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")

        local dl_ok, dl_err = _downloadFile(url, tmp_tar_path)
        UIManager:close(dl_msg)

        if not dl_ok then
            os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Download failed.\n\nPlease check your Wi-Fi connection and try again.") ..
                       (dl_err and "\n\nDetails: " .. dl_err or "")
            })
            lease:release()
            return
        end

        -- Size check
        if expected_size and expected_size > 0 then
            local sf = io.popen(string.format("stat -c %%s '%s' 2>/dev/null", U.shellEscape(tmp_tar_path)))
            if sf then
                local actual = tonumber(sf:read("*l")) or 0
                sf:close()
                local ratio = actual / expected_size
                if ratio < 0.75 or ratio > 1.25 then
                    os.execute("rm -f '" .. U.shellEscape(tmp_tar_path) .. "'")
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        text = T(_(
                            "Downloaded file size is unexpected.\n\n" ..
                            "Expected: ~%1\nActual: %2\n\n" ..
                            "The download may be corrupt. Please try again."),
                            util.getFriendlySize(expected_size), util.getFriendlySize(actual)),
                    })
                    lease:release()
                    return
                end
            end
        end

        _finishInstallation(self, version, post_install_callback, lease)
    end)
end

local function _doFetchRelease(self, post_install_callback)
    local release_json = nil

    -- Use the unified download function (wget → curl → LuaSocket)
    local tmp_json = "/tmp/syncthing_release.json"
    os.remove(tmp_json)
    local ok, err = _downloadFile(
        "https://api.github.com/repos/syncthing/syncthing/releases/latest",
        tmp_json)
    if ok then
        local f = io.open(tmp_json, "r")
        if f then
            release_json = f:read("*a")
            f:close()
        end
        os.remove(tmp_json)
    else
        logger.warn("[KOSyncthing+] Release download failed: " .. tostring(err))
    end

    if not release_json or release_json == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Update check failed.\n\nThe server could not be reached. Please check your Wi-Fi connection."),
        })
        return
    end

    local parse_ok, release = pcall(JSON.decode, release_json)
    if not parse_ok or type(release) ~= "table" or not release.tag_name then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not read release information from GitHub.\n\nThe response may have been malformed."),
        })
        return
    end

    local latest_ver  = release.tag_name:match("v?(%d+%.%d+%.%d+)") or release.tag_name
    local current_ver = getCurrentVersion(self)

    -- Treat a non-ELF file at the binary path (e.g. the Kobo appstream metadata
    -- file named "syncthing" that some Kobo firmware versions place in the plugin
    -- folder) as "not installed".  Using util.pathExists alone causes the update
    -- flow to treat the text file as an existing installation, showing a confusing
    -- "Installed: v?" confirm dialog instead of downloading silently.
    local function _isELF(path)
        local f = io.open(path, "rb")
        if not f then return false end
        local magic = f:read(4)
        f:close()
        return magic == "\x7fELF"
    end
    local is_new_install = not _isELF(U.plugin_path .. "syncthing")

    if not is_new_install and current_ver == latest_ver then
        UIManager:show(InfoMessage:new{
            text = T(_("Syncthing is already up to date.\n\nInstalled version: %1"), current_ver),
        })
        return
    end

    local arch, arch_fallback, raw_machine = detectArch()
    local prefix = "linux-" .. arch .. "-"
    local dl_url, dl_size

    for _, asset in ipairs(release.assets or {}) do
        local n = asset.name or ""
        if n:find(prefix, 1, true) and n:sub(-7) == ".tar.gz" then
            dl_url  = asset.browser_download_url
            dl_size = asset.size
            break
        end
    end

    if not dl_url then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_(
                "No binary found for this device.\n\n" ..
                "Architecture detected: %1\n" ..
                "Latest release: v%2\n\n" ..
                "You can download the binary manually from:\n" ..
                "github.com/syncthing/syncthing/releases"),
                arch, latest_ver),
        })
        return
    end

    if arch_fallback then
        UIManager:show(ConfirmBox:new{
            text = T(_(
                "Architecture detection warning\n\n" ..
                "This device reported \"%1\", which is not a recognised CPU identifier.\n\n" ..
                "The plugin will attempt to download the 32-bit ARM binary — this is correct " ..
                "for most Kindles and Kobos, but may be wrong for your device.\n\n" ..
                "If Syncthing fails to start after installation, please download the correct " ..
                "binary manually from:\ngithub.com/syncthing/syncthing/releases\n\n" ..
                "Continue with the ARM download?"),
                raw_machine),
            ok_text     = _("Download anyway"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
            end,
        })
        return
    end

    if is_new_install then
        performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
    else
        local size_str = dl_size and (" (~" .. util.getFriendlySize(dl_size) .. ")") or ""
        local confirm_text = T(_(
            "A new version is available!\n\n" ..
            "Installed:  v%1\n" ..
            "Available:  v%2%3\n\n" ..
            "Update now?"), current_ver or "?", latest_ver, size_str)

        UIManager:show(ConfirmBox:new{
            text        = confirm_text,
            ok_text     = _("Update"),
            cancel_text = _("Not now"),
            ok_callback = function()
                performUpdate(self, dl_url, latest_ver, dl_size, post_install_callback)
            end,
        })
    end
end

local function checkForUpdates(self, post_install_callback, is_new_install)
    if not U.cacertExists() then
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = U.NO_CACERT_MSG })
        return
    end
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("Please connect to Wi-Fi before checking for updates."),
        })
        return
    end

    local free = U.getFreeSpace(U.plugin_path)
    if free and free < 20 * 1024 * 1024 then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Not enough free space to download Syncthing.\n\nFree: %1\nRequired: 20 MB"), util.getFriendlySize(free)),
        })
        return
    end

    if is_new_install then
        _doFetchRelease(self, post_install_callback)
    else
        local checking_msg = InfoMessage:new{ text = _("Checking for updates…\n\nThis may take a moment.") }
        UIManager:show(checking_msg)
        UIManager:scheduleIn(0.1, function()
            UIManager:close(checking_msg)
            _doFetchRelease(self, post_install_callback)
        end)
    end
end

return {
    getCurrentVersion       = getCurrentVersion,
    _invalidateVersionCache = invalidateVersionCache,
    checkForUpdates         = checkForUpdates,
    performUpdate           = performUpdate,
}
