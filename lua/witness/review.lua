local config = require("witness.config")
local state = require("witness.state")
local git = require("witness.git")

local M = {}

local ns = vim.api.nvim_create_namespace("witness_review")

-- All state for the currently open review window/buffer lives here so the
-- module can be re-entered (M.open() called again, keymap callbacks fired)
-- without threading everything through function arguments.
local session = {
    buf = nil,
    win = nil,
    root = nil,
    hunks = {},
    line_hunk = {}, -- buffer line number -> index into session.hunks
    header_lines = {}, -- index into session.hunks -> its header line number
}

local STATUS_HL = {
    pending = "Comment",
    reviewed = "String",
    flagged = "ErrorMsg",
}

-- ============================================================
-- diff parsing
-- ============================================================

-- Parses `git diff --unified=0` output into a flat list of hunks. Zero
-- context means every +/- line belongs to exactly one hunk, which is what
-- lets us stage/unstage a single hunk in isolation later.
local function parse_diff(diff_lines, section)
    local hunks = {}
    local current_file, old_header, new_header, current_hunk

    local function flush()
        if current_hunk then
            table.insert(hunks, current_hunk)
            current_hunk = nil
        end
    end

    for _, line in ipairs(diff_lines) do
        if vim.startswith(line, "diff --git ") then
            flush()
            current_file, old_header, new_header = nil, nil, nil
        elseif vim.startswith(line, "--- ") then
            old_header = line
        elseif vim.startswith(line, "+++ ") then
            new_header = line
            current_file = line:match("^%+%+%+ b/(.*)$")
            if (not current_file or current_file == "") and old_header then
                current_file = old_header:match("^%-%-%- a/(.*)$")
            end
        elseif vim.startswith(line, "@@ ") then
            flush()
            local old_start, old_count, new_start, new_count =
                line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
            if old_start and current_file then
                current_hunk = {
                    file = current_file,
                    section = section,
                    old_start = tonumber(old_start),
                    old_count = (old_count ~= "" and tonumber(old_count)) or 1,
                    new_start = tonumber(new_start),
                    new_count = (new_count ~= "" and tonumber(new_count)) or 1,
                    header = line,
                    old_header_line = old_header,
                    new_header_line = new_header,
                    lines = {},
                }
            end
        elseif current_hunk and (vim.startswith(line, "+") or vim.startswith(line, "-")) then
            table.insert(current_hunk.lines, line)
        end
    end
    flush()

    return hunks
end

local function collect_hunks(root)
    local hunks = {}

    local unstaged, unstaged_err = git.run(root, { "diff", "--no-color", "--unified=0", "--" })
    if unstaged then
        vim.list_extend(hunks, parse_diff(unstaged, "unstaged"))
    else
        vim.notify("witness.nvim: `git diff` failed\n" .. (unstaged_err or ""), vim.log.levels.ERROR)
    end

    local staged, staged_err = git.run(root, { "diff", "--no-color", "--unified=0", "--cached", "--" })
    if staged then
        vim.list_extend(hunks, parse_diff(staged, "staged"))
    else
        vim.notify("witness.nvim: `git diff --cached` failed\n" .. (staged_err or ""), vim.log.levels.ERROR)
    end

    return hunks
end

-- Content-based id: a hunk keeps its reviewed/flagged mark across reopens
-- as long as its diff text doesn't change, regardless of line shifts
-- elsewhere in the file.
local function hunk_id(hunk)
    local content = table.concat({ hunk.file, hunk.header, table.concat(hunk.lines, "\n") }, "\30")
    return vim.fn.sha256(content):sub(1, 16)
end

-- ============================================================
-- persisted state
-- ============================================================

local function load_statuses()
    local persisted = state.load()
    return persisted.hunks or {}
end

local function save_statuses()
    local statuses = {}
    for _, hunk in ipairs(session.hunks) do
        if hunk.status ~= "pending" then
            statuses[hunk.id] = hunk.status
        end
    end
    state.save({ hunks = statuses })
end

-- ============================================================
-- rendering
-- ============================================================

local function render()
    local lines = {}
    local line_hunk = {}
    local header_lines = {}
    local hl = {}

    local function add(text)
        table.insert(lines, text)
        return #lines
    end

    local sections = {
        { key = "unstaged", title = "Unstaged changes" },
        { key = "staged", title = "Staged changes" },
    }

    for _, section in ipairs(sections) do
        local in_section = {}
        for idx, hunk in ipairs(session.hunks) do
            if hunk.section == section.key then
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
                local hunk = session.hunks[idx]
                local glyph = config.options.signs[hunk.status] or "?"
                local lnum = add(string.format(
                    "%s %s  -%d,%d +%d,%d",
                    glyph, hunk.file, hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count
                ))
                line_hunk[lnum] = idx
                header_lines[idx] = lnum
                table.insert(hl, { line = lnum, group = STATUS_HL[hunk.status] or "Comment", col_end = #glyph })

                for _, dl in ipairs(hunk.lines) do
                    local n = add(dl)
                    line_hunk[n] = idx
                end
            end
        end
    end

    if #lines == 0 then
        add("No changes to review.")
    end

    session.line_hunk = line_hunk
    session.header_lines = header_lines

    return lines, hl
end

local function apply_buffer(lines, hl)
    local buf = session.buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, mark in ipairs(hl) do
        vim.api.nvim_buf_add_highlight(buf, ns, mark.group, mark.line - 1, 0, mark.col_end)
    end
end

-- ============================================================
-- navigation / lookups
-- ============================================================

local function hunk_at_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local idx = session.line_hunk[lnum]
    return idx and session.hunks[idx] or nil
end

local function sorted_headers()
    local list = {}
    for idx, lnum in pairs(session.header_lines) do
        table.insert(list, { idx = idx, lnum = lnum })
    end
    table.sort(list, function(a, b) return a.lnum < b.lnum end)
    return list
end

local function goto_hunk(delta)
    local list = sorted_headers()
    if #list == 0 then
        return
    end

    local cur = vim.api.nvim_win_get_cursor(0)[1]
    if delta > 0 then
        for _, entry in ipairs(list) do
            if entry.lnum > cur then
                vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
                return
            end
        end
        vim.api.nvim_win_set_cursor(0, { list[1].lnum, 0 }) -- wrap to first
    else
        for i = #list, 1, -1 do
            if list[i].lnum < cur then
                vim.api.nvim_win_set_cursor(0, { list[i].lnum, 0 })
                return
            end
        end
        vim.api.nvim_win_set_cursor(0, { list[#list].lnum, 0 }) -- wrap to last
    end
end

-- ============================================================
-- refresh
-- ============================================================

-- Re-collects hunks from git, re-merges persisted state, and redraws.
-- `keep_id` (optional) re-positions the cursor on that hunk if it still
-- exists after the refresh (e.g. it moved from unstaged to staged).
local function refresh(keep_id)
    session.hunks = collect_hunks(session.root)
    local statuses = load_statuses()
    for _, hunk in ipairs(session.hunks) do
        hunk.id = hunk_id(hunk)
        hunk.status = statuses[hunk.id] or "pending"
    end

    local lines, hl = render()
    apply_buffer(lines, hl)

    if keep_id then
        for idx, hunk in ipairs(session.hunks) do
            if hunk.id == keep_id and session.header_lines[idx] then
                vim.api.nvim_win_set_cursor(0, { session.header_lines[idx], 0 })
                return
            end
        end
    end

    local line_count = vim.api.nvim_buf_line_count(session.buf)
    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] > line_count then
        vim.api.nvim_win_set_cursor(0, { line_count, 0 })
    end
end

-- ============================================================
-- hunk actions
-- ============================================================

local function build_patch(hunk)
    local lines = { string.format("diff --git a/%s b/%s", hunk.file, hunk.file) }

    -- Without an explicit new/deleted-file marker, `git apply --reverse` on
    -- a creation or deletion hunk can misparse the /dev/null side and
    -- corrupt the index instead of just adding/removing the file.
    if hunk.old_header_line and hunk.old_header_line:match("^%-%-%- /dev/null") then
        table.insert(lines, "new file mode 100644")
    elseif hunk.new_header_line and hunk.new_header_line:match("^%+%+%+ /dev/null") then
        table.insert(lines, "deleted file mode 100644")
    end

    table.insert(lines, hunk.old_header_line)
    table.insert(lines, hunk.new_header_line)
    table.insert(lines, hunk.header)
    vim.list_extend(lines, hunk.lines)
    return lines
end

local function toggle_status(target)
    local hunk = hunk_at_cursor()
    if not hunk then
        vim.notify("witness.nvim: cursor is not on a hunk", vim.log.levels.WARN)
        return
    end

    local id = hunk.id
    hunk.status = (hunk.status == target) and "pending" or target
    save_statuses()

    local lines, hl = render()
    apply_buffer(lines, hl)

    for idx, h in ipairs(session.hunks) do
        if h.id == id and session.header_lines[idx] then
            vim.api.nvim_win_set_cursor(0, { session.header_lines[idx], 0 })
            break
        end
    end
end

local function stage_current()
    local hunk = hunk_at_cursor()
    if not hunk then
        vim.notify("witness.nvim: cursor is not on a hunk", vim.log.levels.WARN)
        return
    end
    if hunk.section ~= "unstaged" then
        vim.notify("witness.nvim: hunk is already staged", vim.log.levels.WARN)
        return
    end

    local ok, err = git.run_with_stdin(session.root, { "apply", "--cached", "--unidiff-zero", "-" }, build_patch(hunk))
    if not ok then
        vim.notify("witness.nvim: failed to stage hunk\n" .. err, vim.log.levels.ERROR)
        return
    end

    refresh(hunk.id)
end

local function unstage_current()
    local hunk = hunk_at_cursor()
    if not hunk then
        vim.notify("witness.nvim: cursor is not on a hunk", vim.log.levels.WARN)
        return
    end
    if hunk.section ~= "staged" then
        vim.notify("witness.nvim: hunk is not staged", vim.log.levels.WARN)
        return
    end

    local ok, err = git.run_with_stdin(
        session.root,
        { "apply", "--cached", "--reverse", "--unidiff-zero", "-" },
        build_patch(hunk)
    )
    if not ok then
        vim.notify("witness.nvim: failed to unstage hunk\n" .. err, vim.log.levels.ERROR)
        return
    end

    refresh(hunk.id)
end

local function jump_to_hunk()
    local hunk = hunk_at_cursor()
    if not hunk then
        return
    end

    local path = session.root .. "/" .. hunk.file
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_win() == session.win then
        vim.cmd("topleft split")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { math.max(hunk.new_start, 1), 0 })
end

-- ============================================================
-- keymaps
-- ============================================================

local function setup_keymaps(buf)
    local keymaps = config.options.keymaps
    local opts = { buffer = buf, nowait = true, silent = true }

    vim.keymap.set("n", keymaps.mark_reviewed, function() toggle_status("reviewed") end,
        vim.tbl_extend("force", opts, { desc = "witness: toggle reviewed" }))
    vim.keymap.set("n", keymaps.flag, function() toggle_status("flagged") end,
        vim.tbl_extend("force", opts, { desc = "witness: toggle flagged" }))
    vim.keymap.set("n", keymaps.stage, stage_current,
        vim.tbl_extend("force", opts, { desc = "witness: stage hunk" }))
    vim.keymap.set("n", keymaps.unstage, unstage_current,
        vim.tbl_extend("force", opts, { desc = "witness: unstage hunk" }))
    vim.keymap.set("n", keymaps.next_hunk, function() goto_hunk(1) end,
        vim.tbl_extend("force", opts, { desc = "witness: next hunk" }))
    vim.keymap.set("n", keymaps.prev_hunk, function() goto_hunk(-1) end,
        vim.tbl_extend("force", opts, { desc = "witness: previous hunk" }))
    vim.keymap.set("n", keymaps.quit, function()
        if session.win and vim.api.nvim_win_is_valid(session.win) then
            vim.api.nvim_win_close(session.win, true)
        end
    end, vim.tbl_extend("force", opts, { desc = "witness: close review" }))
    vim.keymap.set("n", "<CR>", jump_to_hunk,
        vim.tbl_extend("force", opts, { desc = "witness: jump to hunk" }))
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
    pcall(vim.api.nvim_buf_set_name, buf, "witness://review")

    vim.cmd("botright vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, 80)
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixwidth = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.buf == buf then
                session.buf = nil
                session.win = nil
            end
        end,
    })

    setup_keymaps(buf)

    return buf, win
end

function M.open()
    if config.options.integration.gitsigns and not pcall(require, "gitsigns") then
        vim.notify(
            "witness.nvim: gitsigns.nvim not found; falling back to internal diff parsing",
            vim.log.levels.WARN
        )
    end

    local root = git.root()
    if not root then
        vim.notify("witness.nvim: not inside a git repository", vim.log.levels.ERROR)
        return
    end
    session.root = root

    if session.win and vim.api.nvim_win_is_valid(session.win) then
        vim.api.nvim_set_current_win(session.win)
    else
        session.buf, session.win = create_window()
    end

    refresh()
end

return M
