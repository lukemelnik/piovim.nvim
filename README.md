# piovim.nvim

Experimental Neovim frontend for [Pi](https://github.com/lukemelnik/pi-coding-agent) focused on live editor context.

Piovim runs Pi in RPC mode and opens a side-panel chat with a bottom prompt. It also loads a Pi extension that exposes explicit `nvim_*` tools for live Neovim buffers, diagnostics, highlights, previewed edits, saves, and safe buffer closing.

## Requirements

- Neovim 0.10+
- The `pi` CLI available on `$PATH`
- Lazy.nvim or another Neovim plugin manager

## Installation

With Lazy.nvim:

```lua
{
  "lukemelnik/piovim.nvim",
  config = function()
    require("piovim").setup()
  end,
}
```

With custom options:

```lua
{
  "lukemelnik/piovim.nvim",
  config = function()
    require("piovim").setup({
      side_width = 80,
      keys = {
        toggle = "<leader>pp",
        ask = "<leader>pq",
        append = "<leader>pa",
        stop = "<leader>px",
        clear = "<leader>pc",
        clear_highlights = "<leader>pH",
        thinking_select = "<leader>pt",
        thinking_cycle = "<leader>pT",
        model_select = "<leader>pm",
        model_cycle = "<leader>pM",
        diff = "<leader>pd",
        close_diff = "<leader>pD",
      },
    })
  end,
}
```

## Default keymaps

Global keys:

| Key | Action |
| --- | --- |
| `<leader>pp` | Toggle Piovim side panel |
| `<leader>pq` | Quick ask from current buffer/selection |
| `<leader>pa` | Append current buffer/selection mention into the prompt |
| `<leader>px` | Stop Pi and close the panel |
| `<leader>pc` | Clear Pi session, chat, prompt, and highlights |
| `<leader>pH` | Clear Pi highlights |
| `<leader>pd` | Open review diff picker |
| `<leader>pD` | Close review diff |
| `<leader>pt` | Select thinking level |
| `<leader>pT` | Cycle thinking level |
| `<leader>pm` | Select model |
| `<leader>pM` | Cycle model |

Prompt-buffer keys:

| Key | Action |
| --- | --- |
| `<CR>` | Submit prompt |
| `<Esc>` | Abort current Pi turn |
| `<C-c>` | Clear prompt text |
| `<C-u>` | Clear prompt text |
| `q` | Close panel from normal mode |

Chat-buffer keys:

| Key | Action |
| --- | --- |
| `i` | Focus prompt |
| `q` | Close panel |

## Slash commands

Typed in the Piovim prompt:

- `/clear` clears the current Pi session, visible chat, prompt, and highlights.
- `/model` opens model selection.
- `/thinking` opens thinking-level selection.
- `/diff` opens the Pi review-source picker.
- `/diff <args>` opens a Pi review diff with custom `git diff` args, e.g. `/diff main...HEAD`.
- `/apply` asks Pi to fix active review notes and resolve them as it goes.

In the Pi prompt buffer, type a slash prefix and press `<Tab>` to complete slash commands. Multiple matches open a picker.

## Context mentions

`<leader>pa` appends a plain mention into the prompt and places the cursor on the next line so you can type your request below it.

Examples:

```text
@selection lua/piovim/init.lua#L120-148
explain this flow
```

```text
@buffer lua/piovim/rpc.lua:42
make this easier to follow
```

Mentions are intentionally plain text. Piovim does not paste selected code into the prompt for mention mode; Pi can use the `nvim_*` tools to read live Neovim buffers when needed.

## Review diff

`:PiovimReviewDiff` opens a review-source picker:

- working tree (`git diff`, including untracked files)
- staged changes (`git diff --cached`)
- PR / branch comparison (`<base>...HEAD`)
- recent commit picker (`git show <sha>`)
- commit range (`git diff <range>`)
- patch file (`*.patch` / unified diff text)
- custom `git diff` args

While a review is open, Piovim watches the active review source and refreshes when Git or patch-file contents change. Refreshes are deferred while you are typing or editing a review note so annotations are not interrupted.

Large files are guarded during rendering: files over 5,000 rendered lines are marked as large, and sides over 20,000 rendered lines are omitted with a placeholder instead of filling Neovim with huge buffers.

Inside the diff view:

| Key | Action |
| --- | --- |
| `]f` / `[f` | Next / previous file |
| `f` | Pick file without focusing the file-list pane |
| `b` | Toggle the file-list pane |
| `]h` / `[h` | Next / previous hunk |
| `a` | Annotate current diff line |
| visual `a` | Annotate selected diff lines |
| `]c` / `[c` | Next / previous review note |
| `e` | Edit the current/nearest review note |
| `x` | Delete the current/nearest review note |
| `z` | Toggle compact/expanded review notes |
| `c` | Change comparison |
| `Q` | Open review notes in quickfix |
| `r` | Refresh current comparison |

`:PiovimReviewNotes` opens all current review annotations in the quickfix list.

Review annotations are persisted outside the repo at `stdpath("state")/piovim/reviews/` and old review state files are pruned after 30 days. Comments are anchored by file, line, selected text, and nearby context; refresh attempts to re-anchor notes when edits move code.

## Neovim tools

Piovim exposes explicit Pi tools for live editor state:

- `nvim_get_context`
- `nvim_list_open_buffers`
- `nvim_read_buffer`
- `nvim_get_diagnostics`
- `nvim_open_buffer`
- `nvim_highlight_range`
- `nvim_clear_highlights`
- `nvim_edit_buffer`
- `nvim_save_buffer`
- `nvim_close_buffer`
- `nvim_get_review_diff`
- `nvim_add_review_annotation`
- `nvim_refresh_review_diff`
- `nvim_resolve_review_annotation`

`nvim_edit_buffer` shows an in-place diff preview before applying unsaved, undoable Neovim buffer edits. It supports both exact replacements and explicit range edits for insertions/empty buffers.

`nvim_save_buffer` saves file-backed buffers. `nvim_close_buffer` only closes unmodified buffers and refuses to discard unsaved changes.

`nvim_get_review_diff` exposes the active Pi review diff state to Pi, including the selected comparison, file list, current hunk, and annotations. `nvim_add_review_annotation` lets Pi add actionable notes to the active review diff.

## Configuration

Default setup:

```lua
require("piovim").setup()
```

Options:

```lua
require("piovim").setup({
  bin = "pi",
  side_width = 80,
  snippet_context_lines = 40,
  keys = {
    toggle = "<leader>pp",
    ask = "<leader>pq",
    append = "<leader>pa",
    stop = "<leader>px",
    clear = "<leader>pc",
    clear_highlights = "<leader>pH",
    thinking_select = "<leader>pt",
    thinking_cycle = "<leader>pT",
    model_select = "<leader>pm",
    model_cycle = "<leader>pM",
    diff = "<leader>pd",
    close_diff = "<leader>pD",
  },
})
```

Set any key to `false` or `nil` to skip creating that keymap.

Model/thinking settings are persisted at:

```text
~/.local/state/nvim/piovim/config.json
```

## Commands

- `:Piovim`
- `:PiovimToggle`
- `:PiovimAsk`
- `:PiovimAppendContext`
- `:PiovimStop`
- `:PiovimClear`
- `:PiovimClearHighlights`
- `:PiovimAbort`
- `:PiovimThinkingSelect`
- `:PiovimThinkingCycle`
- `:PiovimModelSelect`
- `:PiovimModelCycle`
- `:PiovimReviewDiff [working-tree|staged|main|origin/main|<git diff args>]`
- `:PiovimReviewCommit [rev]`
- `:PiovimReviewRange [range]`
- `:PiovimReviewPatch [patch-file]`
- `:PiovimReviewFiles`
- `:PiovimReviewToggleFiles`
- `:PiovimReviewClose`
- `:PiovimReviewRefresh`
- `:PiovimReviewEditNote`
- `:PiovimReviewDeleteNote`
- `:PiovimReviewNotes`

## Development

Code layout:

- `lua/piovim/init.lua` wires setup, commands, keymaps, and user actions.
- `lua/piovim/context.lua` builds prompt context and plain `@buffer` / `@selection` mentions.
- `lua/piovim/panel.lua` owns the side-panel UI and prompt buffer.
- `lua/piovim/rpc.lua` starts Pi RPC mode and renders Pi events into the panel.
- `lua/piovim/bridge.lua` owns the local TCP bridge between Pi and Neovim.
- `lua/piovim/buffer_ops.lua` implements Neovim buffer tools.
- `lua/piovim/edit_preview.lua` renders in-place edit previews.
- `lua/piovim/review_diff.lua` renders Git diff review buffers, navigation, and annotations.
- `pi-extension/nvim-tools.ts` registers Pi-side `nvim_*` tools.

Run local checks:

```sh
luac -p lua/piovim/*.lua scripts/smoke.lua scripts/review_diff_tests.lua
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -c 'lua require("piovim").setup({ keys = {} })' -c 'qa'
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -S scripts/smoke.lua -c 'qa'
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -S scripts/review_diff_tests.lua -c 'qa'
```

## Release flow

Piovim uses simple git tags for releases.

1. Make changes and run checks.
2. Commit with a conventional commit message.
3. Choose a semver tag:
   - `v0.0.x` for fixes/internal polish while experimental
   - `v0.x.0` for user-facing features
   - `v1.0.0` only once the API/UX is stable
4. Create and push the tag:

```sh
git tag v0.1.0
git push origin main --tags
```

Lazy.nvim users can pin a release:

```lua
{
  "lukemelnik/piovim.nvim",
  version = "v0.1.0",
  config = function()
    require("piovim").setup()
  end,
}
```

Until the plugin stabilizes, installing from `main` is expected.

## Status

Piovim is experimental. Expect fast iteration and occasional breaking changes.
