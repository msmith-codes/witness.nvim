local M = {}

local registered = false

function M.register()
    if registered then
        return
    end

    registered = true

    vim.api.nvim_create_user_command("Witness", function (cmd_opts)
        local sub = cmd_opts.fargs[1]
        if sub == "review" or sub == nil then
            require("witness.review").open()
        elseif sub == "reset" then
            require("witness.state").reset()
        else
            vim.notify("witness.nvim unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
        end
    end, {
        nargs = "?",
        complete = function()
            return { "review", "reset" }
        end,
        desc = "Open or manage the witness.nvim hunk review list",
    })
end

return M
