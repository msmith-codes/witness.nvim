local config = require("witness.config")

local M = {}

function M.setup(opts)
    config.setup(opts or {})
    require("witness.commands").register()
end

return M
