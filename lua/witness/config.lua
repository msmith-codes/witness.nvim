local M = {}

local defaults = {
    state_dir = vim.fn.stdpath("state") .. "/witness",

    keymaps = {
        mark_reviewed = "r",
        flag = "f",
        stage = "s",
        unstage = "u",
        next_hunk = "]h",
        prev_hunk = "[h",
        quit = "q",
    },

    signs = {
        pending = "○",
        reviewed = "●",
        flagged = "!",
    },

    integration = {
        gitsigns = true,
        lualine = false,
    },
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return M
