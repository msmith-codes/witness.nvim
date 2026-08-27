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

    commit = {
        keymaps = {
            stage = "s",
            unstage = "u",
            stage_all = "S",
            unstage_all = "U",
            commit = "cc",
            refresh = "R",
            quit = "q",
        },
        -- Fraction of the editor's columns/lines the floating window uses.
        width = 0.8,
        height = 0.8,
    },

    signs = {
        pending = "○",
        reviewed = "●",
        flagged = "!",
        staged = "●",
        unstaged = "○",
        untracked = "?",
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
