local config = require("witness.config")
local git = require("witness.git")

local M = {}

local ns = vim.api.nvim_create_namespace("witness_commit")

-- All state for the currently open commit window/buffers lives here so the
-- module can be re-entered (M.open() called again, keymap callbacks fired)
-- without threading everything through function arguments.
local session = {
    buf = nil,
    win = nil,
    msg_buf = nil,
    msg_win = nil,
    prev_win = nil, -- window to jump into for <CR>, restored on quit
    root = nil,
    files = {},
    line_file = {}, -- buffer line number -> index into session.files
    header_lines = {}, -- index into session.files -> its header line number
}

local SECTION_HL = {
    staged = "String",
    unstaged = "Comment",
    untracked = "Comment",
}

-- ============================================================
-- status / diff collection
-- ============================================================

-- Parses `git status --porcelain=v1` into a flat list of files. The -z
-- (NUL-delimited) form would be the robust choice for exotic filenames,
-- but `vim.fn.system()` replaces embedded NUL bytes with SOH (0x01) in the
-- returned string, which silently defeats splitting on "\0" — so this
-- sticks to the newline-delimited default, same as the rest of the
-- codebase's diff parsing, and accepts that a path containing " -> " or a
-- leading space is an edge case it won't handle.
local function parse_status(lines)
    local files = {}
    for _, line in ipairs(lines) do
        local index_status, worktree_status, rest = line:sub(1, 1), line:sub(2, 2), line:sub(4)

        local orig_path, path = nil, rest
        if index_status == "R" or index_status == "C" then
            orig_path, path = rest:match("^(.-) %-> (.*)$")
            path = path or rest
        end

        local section
        if index_status == "?" and worktree_status == "?" then
            section = "untracked"
        elseif index_status ~= " " and index_status ~= "?" then
            section = "staged"
        else
            section = "unstaged"
        end

        table.insert(files, {
            index_status = index_status,
            worktree_status = worktree_status,
            path = path,
            orig_path = orig_path,
            section = section,
        })
    end
    return files
end

-- `git diff --no-index` reports success (exit 0) only when the two sides
-- are identical, which never happens here — an untracked file always
-- differs from /dev/null — so a non-error exit code of 1 is the expected
-- "diff produced" result, not a failure.
local function diff_untracked(root, path)
    local cmd = { "git", "-C", root, "diff", "--no-color", "--no-index", "--", "/dev/null", path }
    local out = vim.fn.systemlist(cmd)
    if vim.v.shell_error > 1 then
        return nil
    end
    -- Drop the leading "diff --git a/path b/path" and "new file mode"
    -- lines; the caller renders its own per-file header.
    return vim.list_slice(out, 3)
end

local function diff_tracked(root, path, staged)
    local args = { "diff", "--no-color" }
    if staged then
        table.insert(args, "--cached")
    end
    vim.list_extend(args, { "--", path })
    local out = git.run(root, args)
    return out or {}
end

local function collect_files(root)
    local raw, err = git.run(root, { "status", "--porcelain=v1", "--" })
    if not raw then
        vim.notify("witness.nvim: `git status` failed\n" .. (err or ""), vim.log.levels.ERROR)
        return {}
    end

    local files = parse_status(raw)
    for _, file in ipairs(files) do
        if file.section == "untracked" then
            file.diff_lines = diff_untracked(root, file.path) or {}
        else
            file.diff_lines = diff_tracked(root, file.path, file.section == "staged")
        end
    end
    return files
end

-- ============================================================
-- rendering
-- ============================================================

local function status_label(file)
    if file.orig_path then
        return string.format("%s -> %s", file.orig_path, file.path)
    end
    return file.path
end

local function render()
    local lines = {}
    local line_file = {}
    local header_lines = {}
    local hl = {}
    local folds = {}

    local function add(text)
        table.insert(lines, text)
        return #lines
    end

    local sections = {
        { key = "staged", title = "Staged changes" },
        { key = "unstaged", title = "Unstaged changes" },
        { key = "untracked", title = "Untracked files" },
    }

    for _, section in ipairs(sections) do
        local in_section = {}
        for idx, file in ipairs(session.files) do
            if file.section == section.key then
                table.insert(in_section, idx)
            end
        end

        if #in_section > 0 then
            if #lines > 0 then
                add("")
            end
            add(string.format("── %s %s", section.title, string.rep("─", 40)))
            add("")

            for _, idx in ipairs(in_section) do
                local file = session.files[idx]
                local glyph = config.options.signs[file.section] or "?"
                local lnum = add(string.format("%s %s", glyph, status_label(file)))
                line_file[lnum] = idx
                header_lines[idx] = lnum
                table.insert(hl, { line = lnum, group = SECTION_HL[file.section] or "Comment", col_end = #glyph })

                if #file.diff_lines > 0 then
                    for _, dl in ipairs(file.diff_lines) do
                        local n = add(dl)
                        line_file[n] = idx
                    end
                    table.insert(folds, { from = lnum + 1, to = #lines })
                else
                    local n = add("  (binary or empty diff)")
                    line_file[n] = idx
                end
            end
        end
    end

    if #lines == 0 then
        add("Nothing to commit, working tree clean.")
    end

    session.line_file = line_file
    session.header_lines = header_lines

    return lines, hl, folds
end

local function apply_buffer(lines, hl, folds)
    local buf = session.buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, mark in ipairs(hl) do
        vim.api.nvim_buf_add_highlight(buf, ns, mark.group, mark.line - 1, 0, mark.col_end)
    end

    if session.win and vim.api.nvim_win_is_valid(session.win) then
        vim.api.nvim_win_call(session.win, function()
            vim.cmd("normal! zE") -- clear existing folds before redrawing them
            for _, fold in ipairs(folds) do
                if fold.to > fold.from then
                    vim.cmd(string.format("%d,%dfold", fold.from, fold.to))
                end
            end
        end)
    end
end

-- ============================================================
-- navigation / lookups
-- ============================================================

local function file_at_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local idx = session.line_file[lnum]
    return idx and session.files[idx] or nil
end

-- ============================================================
-- refresh
-- ============================================================

-- Re-collects file statuses/diffs from git and redraws. `keep_path`
-- (optional) re-positions the cursor on that path's header if it still
-- appears after the refresh (e.g. it moved from unstaged to staged).
local function refresh(keep_path)
    session.files = collect_files(session.root)
    local lines, hl, folds = render()
    apply_buffer(lines, hl, folds)

    if keep_path then
        for idx, file in ipairs(session.files) do
            if file.path == keep_path and session.header_lines[idx] then
                vim.api.nvim_win_set_cursor(session.win, { session.header_lines[idx], 0 })
                return
            end
        end
    end

    local line_count = vim.api.nvim_buf_line_count(session.buf)
    local cur = vim.api.nvim_win_get_cursor(session.win)
    if cur[1] > line_count then
        vim.api.nvim_win_set_cursor(session.win, { line_count, 0 })
    end
end

-- ============================================================
-- file actions
-- ============================================================

local function stage_current()
    local file = file_at_cursor()
    if not file then
        vim.notify("witness.nvim: cursor is not on a file", vim.log.levels.WARN)
        return
    end
    if file.section == "staged" then
        vim.notify("witness.nvim: file is already staged", vim.log.levels.WARN)
        return
    end

    local _, err = git.run(session.root, { "add", "--", file.path })
    if err then
        vim.notify("witness.nvim: failed to stage " .. file.path .. "\n" .. err, vim.log.levels.ERROR)
        return
    end

    refresh(file.path)
end

local function unstage_current()
    local file = file_at_cursor()
    if not file then
        vim.notify("witness.nvim: cursor is not on a file", vim.log.levels.WARN)
        return
    end
    if file.section ~= "staged" then
        vim.notify("witness.nvim: file is not staged", vim.log.levels.WARN)
        return
    end

    local _, err = git.run(session.root, { "restore", "--staged", "--", file.path })
    if err then
        vim.notify("witness.nvim: failed to unstage " .. file.path .. "\n" .. err, vim.log.levels.ERROR)
        return
    end

    refresh(file.path)
end

local function stage_all()
    local _, err = git.run(session.root, { "add", "-A", "--", "." })
    if err then
        vim.notify("witness.nvim: failed to stage all\n" .. err, vim.log.levels.ERROR)
        return
    end
    refresh()
end

local function unstage_all()
    local _, err = git.run(session.root, { "restore", "--staged", "--", "." })
    if err then
        vim.notify("witness.nvim: failed to unstage all\n" .. err, vim.log.levels.ERROR)
        return
    end
    refresh()
end

local function jump_to_file()
    local file = file_at_cursor()
    if not file then
        return
    end

    local path = session.root .. "/" .. file.path
    if session.prev_win and vim.api.nvim_win_is_valid(session.prev_win) then
        vim.api.nvim_set_current_win(session.prev_win)
    else
        vim.cmd("wincmd p")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
end

-- ============================================================
-- commit message window
-- ============================================================

local function close_commit_window()
    if session.msg_win and vim.api.nvim_win_is_valid(session.msg_win) then
        vim.api.nvim_win_close(session.msg_win, true)
    end
    session.msg_win = nil
    session.msg_buf = nil
end

local function commit_template()
    local lines = { "", "# Please enter the commit message for your changes. Lines starting" }
    vim.list_extend(lines, {
        "# with '#' will be ignored, and an empty message aborts the commit.",
        "#",
    })

    local branch = git.run(session.root, { "rev-parse", "--abbrev-ref", "HEAD" })
    if branch and branch[1] then
        table.insert(lines, "# On branch " .. branch[1])
    end

    table.insert(lines, "# Changes to be committed:")
    for _, file in ipairs(session.files) do
        if file.section == "staged" then
            table.insert(lines, string.format("#\t%s: %s", file.index_status, status_label(file)))
        end
    end

    return lines
end

local function open_commit_window()
    local staged_count = 0
    for _, file in ipairs(session.files) do
        if file.section == "staged" then
            staged_count = staged_count + 1
        end
    end
    if staged_count == 0 then
        vim.notify("witness.nvim: nothing staged to commit", vim.log.levels.WARN)
        return
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "gitcommit"
    pcall(vim.api.nvim_buf_set_name, buf, "witness://commit-message")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, commit_template())
    vim.bo[buf].modified = false

    local columns, editor_lines = vim.o.columns, vim.o.lines
    local width = math.floor(columns * config.options.commit.width)
    local height = 14
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((editor_lines - height) / 2),
        col = math.floor((columns - width) / 2),
        border = "rounded",
        title = " Commit message ",
        title_pos = "center",
    })
    vim.wo[win].wrap = true
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    session.msg_buf = buf
    session.msg_win = win

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local ok, out = git.run_with_stdin(session.root, { "commit", "--cleanup=strip", "-F", "-" }, lines)
            if not ok then
                -- Signal failure so `:wq`'s implicit quit does not proceed
                -- and the user can fix the message and retry.
                error("witness.nvim: commit failed\n" .. vim.trim(out))
            end

            vim.bo[buf].modified = false
            vim.notify("witness.nvim: " .. vim.trim(out), vim.log.levels.INFO)
            close_commit_window()
            refresh()
        end,
    })

    vim.keymap.set("n", config.options.commit.keymaps.quit, close_commit_window,
        { buffer = buf, nowait = true, silent = true, desc = "witness: cancel commit" })
end

-- ============================================================
-- keymaps
-- ============================================================

local function setup_keymaps(buf)
    local keymaps = config.options.commit.keymaps
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", keymaps.stage, stage_current,
        vim.tbl_extend("force", opts, { desc = "witness: stage file" }))
    vim.keymap.set("n", keymaps.unstage, unstage_current,
        vim.tbl_extend("force", opts, { desc = "witness: unstage file" }))
    vim.keymap.set("n", keymaps.stage_all, stage_all,
        vim.tbl_extend("force", opts, { desc = "witness: stage all files" }))
    vim.keymap.set("n", keymaps.unstage_all, unstage_all,
        vim.tbl_extend("force", opts, { desc = "witness: unstage all files" }))
    vim.keymap.set("n", keymaps.commit, open_commit_window,
        vim.tbl_extend("force", opts, { desc = "witness: write commit message" }))
    vim.keymap.set("n", keymaps.refresh, function() refresh() end,
        vim.tbl_extend("force", opts, { desc = "witness: refresh" }))
    vim.keymap.set("n", keymaps.quit, function()
        if session.win and vim.api.nvim_win_is_valid(session.win) then
            vim.api.nvim_win_close(session.win, true)
        end
    end, vim.tbl_extend("force", opts, { desc = "witness: close commit window" }))
    vim.keymap.set("n", "<CR>", jump_to_file,
        vim.tbl_extend("force", opts, { desc = "witness: jump to file" }))
end

-- ============================================================
-- window/buffer management
-- ============================================================

local function create_window()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "diff"
    pcall(vim.api.nvim_buf_set_name, buf, "witness://commit")

    local columns, editor_lines = vim.o.columns, vim.o.lines
    local width = math.floor(columns * config.options.commit.width)
    local height = math.floor(editor_lines * config.options.commit.height)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((editor_lines - height) / 2),
        col = math.floor((columns - width) / 2),
        border = "rounded",
        title = " Witness commit ",
        title_pos = "center",
    })
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.buf == buf then
                session.buf = nil
                session.win = nil
            end
            close_commit_window()
        end,
    })

    setup_keymaps(buf)

    return buf, win
end

function M.open()
    local root = git.root()
    if not root then
        vim.notify("witness.nvim: not inside a git repository", vim.log.levels.ERROR)
        return
    end
    session.root = root
    session.prev_win = vim.api.nvim_get_current_win()

    if session.win and vim.api.nvim_win_is_valid(session.win) then
        vim.api.nvim_set_current_win(session.win)
    else
        session.buf, session.win = create_window()
    end

    refresh()
end

return M
