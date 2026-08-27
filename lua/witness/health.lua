local M = {}

function M.check()
    local health = vim.health or require("health")
    local start = health.start or health.report_start
    local ok = health.ok or health.report_ok
    local warn = health.warn or health.report_warn
    local error_ = health.error or health.report_error

    start("witness.nvim")

    if vim.fn.executable("git") == 1 then
        ok("git executable found")
    else
        error_("git executable not found on PATH — witness.nvim requires git")
    end

    local has_gitsigns = pcall(require, "gitsigns")
    if has_gitsigns then
        ok("gitsigns.nvim detected")
    else
        warn("gitsigns.nvim not found — required for hunk detection until internal diff parsing lands")
    end

    local config = require("witness.config")
    local state_dir = config.options.state_dir
    if vim.fn.isdirectory(state_dir) == 1 or vim.fn.mkdir(state_dir, "p") == 1 then
        ok("state directory writable: " .. state_dir)
    else
        error_("cannot create state directory: " .. state_dir)
    end
end


return M
