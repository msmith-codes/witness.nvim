local config = require("witness.config")

local M = {}

local function project_key()
    local out = vim.fn.systemlist("git rev-parse --show-toplevel")
    local root
    if vim.v.shell_error == 0 and out[1] then
        root = out[1]
    else
        root = vim.fn.getcwd()
    end
    return vim.fn.sha256(root):sub(1, 16)
end

local function state_path()
    return config.options.state_dir .. "/" .. project_key() .. ".json"
end

function M.load()
    local path = state_path()
    if vim.fn.filereadable(path) == 0 then
        return {}
    end

    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if not ok then
        vim.notify("witness.nvim: failed to parse state file, starting fresh", vim.log.levels.WARN)
        return {}
    end

    return decoded
end

function M.save(state)
    vim.fn.mkdir(config.options.state_dir, "p")
    vim.fn.writefile({ vim.json.encode(state) }, state_path())
end

function M.reset()
    local path = state_path()
    if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
    end
    vim.notify("witness.nvim: state reset for this project", vim.log.levels.INFO)
end

return M
