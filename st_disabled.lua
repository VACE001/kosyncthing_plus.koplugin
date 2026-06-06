-- st_disabled.lua — Centralised "why is this disabled?" helper
--
-- Every disabled menu item in this plugin can be in one of a small number
-- of "why" states (Syncthing not running, no folders, no Wi-Fi, etc.).
-- Rather than scatter ad-hoc explanations across the menu code, model
-- each gate as a named predicate paired with a human-readable explanation.
--
-- Usage in menu items:
--   {
--     text         = _("Sync now"),
--     enabled_func = function() return D.isRunning(self) end,
--     hold_callback = function() D.explain(self, "isRunning") end,
--     ...
--   }
--
-- The convention is: tap-and-hold on a disabled item shows a short
-- InfoMessage explaining the gate and what to do about it.  Tap-and-hold
-- on an enabled item still works (it shows "this action is available")
-- so the affordance is consistent.

local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local NetworkMgr  = require("ui/network/manager")
local _           = require("syncthing_i18n").gettext

---------------------------------------------------------------------------
-- Gate registry.
--
-- Each entry has:
--   check(self)   → returns true if the gate is OPEN (action available)
--   reason(self)  → returns a short string explaining why it's closed
---------------------------------------------------------------------------
local gates = {}

gates.binaryExists = {
    check  = function(self) return self:binaryExists() end,
    reason = function()
        return _("This action requires the Syncthing program to be installed first.\n\n"
              .. "Tap “Start Syncthing” from the main menu — it will offer to download the binary.")
    end,
}

gates.isRunning = {
    check  = function(self) return self:isRunning() end,
    reason = function()
        return _("This action requires Syncthing to be running.\n\n"
              .. "Start Syncthing from the main menu first.")
    end,
}

gates.isStopped = {
    check  = function(self) return not self:isRunning() end,
    reason = function()
        return _("This action requires Syncthing to be stopped.\n\n"
              .. "Stop Syncthing from the main menu first, then try again.")
    end,
}

gates.online = {
    check  = function() return NetworkMgr:isOnline() end,
    reason = function()
        return _("This action requires Wi-Fi.\n\n"
              .. "Connect to a network first, then try again.")
    end,
}

gates.hasFolders = {
    check  = function(self)
        local h = self:getFolderHealth()
        return h ~= nil and h.total > 0
    end,
    reason = function()
        return _("No folders are configured yet.\n\n"
              .. "Open the Web GUI from a browser and add a folder first, "
              .. "or accept a pending folder offered by another device.")
    end,
}

gates.hasConflicts = {
    check  = function(self) return #self:findConflicts() > 0 end,
    reason = function()
        return _("There are no sync conflicts to resolve.\n\n"
              .. "This option becomes available when two devices change the same file simultaneously.")
    end,
}

gates.hasApiError = {
    check  = function(self)
        local errors = self:getApiErrors()
        return errors and #errors > 0
    end,
    reason = function()
        return _("No recent API errors to show.\n\n"
              .. "This option becomes available after Syncthing fails to respond to a request — useful when reporting bugs.")
    end,
}

gates.notAutoStart = {
    check  = function(self) return not self.auto_start_always end,
    reason = function()
        return _("Periodic Quick Sync is redundant when \"Autostart Syncthing\" is on"
              .. " — Syncthing is already running continuously.\n\n"
              .. "Disable \"Autostart Syncthing\" first if you want Periodic Quick Sync instead.")
    end,
}

gates.hasAutomation = {
    -- Checks the real automation fields.
    -- The old code referenced auto_quicksync_wifi which no longer exists.
    check  = function(self) return self.auto_start_always or self.periodic_sync_enabled end,
    reason = function()
        return _("This setting only applies when an automation rule is active.\n\n"
              .. "Enable \"Autostart Syncthing\" or \"Periodic Quick Sync\" first.")
    end,
}

---------------------------------------------------------------------------
-- explain(self, gate_name)
--
-- Show a popup explaining why the given gate is currently closed (or
-- confirming the action is available if it's open).  Safe to call from
-- any callback.
---------------------------------------------------------------------------
local function explain(self, gate_name)
    local g = gates[gate_name]
    if not g then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = "[Syncthing] Unknown gate: " .. tostring(gate_name),
        })
        return
    end

    if g.check(self) then
        UIManager:show(InfoMessage:new{
            timeout = 2,
            text    = _("This action is currently available — just tap it."),
        })
    else
        UIManager:show(InfoMessage:new{
            text = g.reason(self),
        })
    end
end

---------------------------------------------------------------------------
-- enabled(self, gate_name)
--
-- Convenience: returns the gate's check function bound to self, suitable
-- for direct use as a menu item's `enabled_func`.
---------------------------------------------------------------------------
local function enabled(self, gate_name)
    local g = gates[gate_name]
    if not g then return function() return false end end
    return function() return g.check(self) end
end

---------------------------------------------------------------------------
-- hold(self, gate_name)
--
-- Convenience: returns a hold_callback that shows the gate's explanation.
-- This is what makes "tap-and-hold to learn why" work uniformly across
-- the whole plugin for items that have an enabled_func gate.
---------------------------------------------------------------------------
local function hold(self, gate_name)
    return function() explain(self, gate_name) end
end

---------------------------------------------------------------------------
-- helpHold(help_text)
--
-- For menu items WITHOUT a gate (always available items, headers, even
-- non-interactive read-only rows): returns a hold_callback that shows
-- the given help text in an InfoMessage.
--
-- This is what makes EVERY item in the plugin tap-and-hold to learn what
-- it does.  Call this on items without enabled_func; use hold() above on
-- items WITH enabled_func.
---------------------------------------------------------------------------
local function helpHold(help_text)
    if not help_text or help_text == "" then
        return function()
            UIManager:show(InfoMessage:new{
                timeout = 2,
                text    = _("No additional help is available for this item."),
            })
        end
    end
    return function()
        UIManager:show(InfoMessage:new{ text = help_text })
    end
end

---------------------------------------------------------------------------
-- gatedHold(self, gate_name, help_text)
--
-- For menu items that have BOTH a gate AND a meaningful help_text: when
-- the gate is closed, explain why; when the gate is open, show the help.
-- This way tap-and-hold always says something useful regardless of state.
---------------------------------------------------------------------------
local function gatedHold(self, gate_name, help_text)
    return function()
        local g = gates[gate_name]
        if g and not g.check(self) then
            UIManager:show(InfoMessage:new{ text = g.reason(self) })
        elseif help_text and help_text ~= "" then
            UIManager:show(InfoMessage:new{ text = help_text })
        else
            UIManager:show(InfoMessage:new{
                timeout = 2,
                text    = _("This action is currently available — just tap it."),
            })
        end
    end
end

return {
    enabled   = enabled,
    hold      = hold,
    helpHold  = helpHold,
    gatedHold = gatedHold,
    explain   = explain,
}
