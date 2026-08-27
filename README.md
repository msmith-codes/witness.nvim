<div align="center">

# Witness.nvim
##### Manage your git with an easy to use window.

![Lua](https://img.shields.io/badge/Lua-5.5-blue?style=flat&logo=lua)
![Neovim](https://img.shields.io/badge/NeoVim-v0.12-green?style=flat&logo=neovim)

</div>

## Table of Contents
* [Installation](#Installation)
* [Getting Started](#Getting-Started)
  * [Commands](#Commands)
  * [Commit Window Keymaps](#Commit-Window-Keymaps)
## Installation 
* Neovim v0.12.5 required
* Install using your favorite plugin manager. (Here I'm using `lazy.nvim`)
```lua
{
    "msmith-codes/witness.nvim",
    branch = "main",
    dependencies = { "lewis6991/gitsigns.nvim" },
    name = "witness.nvim",
    cmd = "Witness",
    opts = {},
}
```

## Getting Started


### Commands

- `:Witness` / `:Witness review` — open the hunk review list (split window).
  Walk unstaged/staged hunks, mark them reviewed/flagged, and stage/unstage
  individual hunks.
- `:Witness commit` — open the commit window (floating). Shows the diff for
  every staged, unstaged, and untracked file; stage or unstage whole files
  and write a commit message without leaving Neovim.
- `:Witness reset` — clear persisted hunk review state for the current
  project.

### Commit Window Keymaps

| Key  | Action                          |
|------|----------------------------------|
| `s`  | Stage the file under the cursor  |
| `u`  | Unstage the file under the cursor |
| `S`  | Stage all changes                |
| `U`  | Unstage all changes              |
| `cc` | Open the commit message window   |
| `R`  | Refresh                          |
| `<CR>` | Jump to the file               |
| `q`  | Close                            |

The commit message window is a normal git-commit-style buffer: edit the
message, then `:w` (or `:wq`) to commit, or `q`/`:q` to cancel. Lines
starting with `#` are ignored, matching git's own commit message
conventions.

All keymaps are configurable via `require("witness").setup({ commit = {
keymaps = { ... } } })`.
