-- Shared git plumbing used by both the hunk review window and the commit
-- window. Kept dependency-free (no config/state) so either can require it
-- in isolation.

local M = {}

function M.root()
    local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
    if vim.v.shell_error ~= 0 or vim.tbl_isempty(out) then
        return nil
    end
    return out[1]
end

function M.run(root, args)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local out = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
        return nil, table.concat(out, "\n")
    end
    return out
end

-- Feeds `input_lines` to git on stdin, e.g. for `git apply` on a
-- hand-built single-hunk patch, or `git commit -F -`. `vim.fn.system()`
-- joins a list input with "\n" but does not add a trailing one, which
-- git's patch/message parsers can treat as a truncated last line — so the
-- newline is added explicitly.
function M.run_with_stdin(root, args, input_lines)
    local cmd = { "git", "-C", root }
    vim.list_extend(cmd, args)
    local input = table.concat(input_lines, "\n") .. "\n"
    local out = vim.fn.system(cmd, input)
    return vim.v.shell_error == 0, out
end

return M
