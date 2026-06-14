local spec_file = debug.getinfo(1, "S").source:gsub("^@", "")
local spec_dir = spec_file:match("^(.*)[/\\][^/\\]+$") or "spec"
local plugin_dir = spec_dir:gsub("[/\\]spec$", "")

package.path = table.concat({
    plugin_dir .. "/?.lua",
    spec_dir .. "/?.lua",
    package.path,
}, ";")

local Mock = require("spec.mock_koreader")
Mock.install()

return Mock
