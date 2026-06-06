-- st_insert_menu.lua — position the kosyncthing_plus entry inside the Tools tab,
-- instead of letting it fall to the bottom of the list.
--
-- IMPORTANT — unique module name. This file used to be named "insert_menu.lua"
-- and was loaded with require("insert_menu"). That collided with Syncery, which
-- ships its OWN "insert_menu.lua": all KOReader plugins share one Lua module
-- cache (package.loaded), and require() caches by module NAME. Whichever plugin
-- loaded first (Syncery, alphabetically before kosyncthing_plus) claimed the
-- "insert_menu" name; our require("insert_menu") then returned the cached
-- module and OUR file never executed — so the KOSyncthing+ entry was never positioned
-- and always fell to the bottom of Tools. Giving this module a unique name
-- ("st_insert_menu") makes our positioning code run independently of Syncery.
--
-- KOReader builds each menu tab's order from a static table in
-- `ui/elements/*_menu_order`. A plugin entry whose key isn't listed there is
-- appended at the end of its sorting_hint section. We splice the key in at the
-- desired spot at load time. kosyncthing_plus is NOT is_doc_only, so KOReader
-- instantiates it in both the READER and the FILE MANAGER; we patch both order
-- tables so the entry is positioned in either context.
--
-- Anchoring — same proven mechanism Syncery uses. We try, in order:
--   1. just before "syncery"        — keeps the two sync entries adjacent in a
--                                      stable, load-order-independent position
--                                      (KOSyncthing+ directly above Syncery);
--   2. just before "move_to_archive" — Syncery's own anchor; reliable across
--                                      KOReader versions and equivalent to
--                                      "right under Cloud storage" because the
--                                      two are adjacent in the default order;
--   3. just after  "cloudstorage" / "cloud_storage" — extra fallback;
--   4. append                        — never guess, never error, never dup.

local KEY = "kosyncthing_plus"

local function index_of(tools, key)
    for i, v in ipairs(tools) do
        if v == key then return i end
    end
end

local function splice(order)
    if type(order) ~= "table" or type(order.tools) ~= "table" then
        return
    end
    local tools = order.tools

    -- Guard against double-insertion (plugin reloaded, key already listed,
    -- or the same table reached twice).
    if index_of(tools, KEY) then return end

    -- Resolve the insertion position by the priority described above.
    local pos = index_of(tools, "syncery")              -- 1. above Syncery
             or index_of(tools, "move_to_archive")      -- 2. Syncery's anchor
    if not pos then                                      -- 3. after Cloud storage
        local anchor = index_of(tools, "cloudstorage")
                    or index_of(tools, "cloud_storage")
        if anchor then pos = anchor + 1 end
    end

    if pos then
        table.insert(tools, pos, KEY)
    else
        table.insert(tools, KEY)                         -- 4. append
    end
end

-- Patch both the reader and the file manager menus. pcall so a build lacking
-- either element module cannot break plugin load.
local ok_reader, reader_order = pcall(require, "ui/elements/reader_menu_order")
if ok_reader then splice(reader_order) end

local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
if ok_fm then splice(fm_order) end
