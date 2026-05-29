<p align="center">
  <img src="assets/readme-header.png" alt="piovim.nvim header: Pi and Neovim pixel characters hugging">
</p>

# piovim.nvim — Pi inside Neovim with live editor context

Piovim is a Neovim frontend for [Pi](https://pi.dev) that lets Pi collaborate with the buffers, selections, diagnostics, and diffs already open in the editor.

```vim
:Piovim
" Ask in the side panel: explain this buffer and highlight the important lines
```

## Fast setup

### 1. Install and authenticate Pi

Piovim runs the `pi` CLI in RPC mode. Install the current Pi package, then sign in once:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi
# In Pi: run /login, or configure an API-key provider.
# Then quit Pi and return to Neovim.
```

Migrating from the old npm scope? Uninstall only the old global package first if npm reports a `pi` binary conflict:

```sh
npm uninstall -g @mariozechner/pi-coding-agent
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

Do not delete `~/.pi/agent`; that is where Pi keeps settings, sessions, extensions, skills, prompts, themes, and package config.

### 2. Install piovim.nvim

With Lazy.nvim:

```lua
{
  "lukemelnik/piovim.nvim",
  version = "v0.1.0",
  config = function()
    require("piovim").setup()
  end,
}
```

Restart Neovim or run `:Lazy sync`.

### 3. Verify and start

```vim
:checkhealth piovim
:Piovim
```

If `:checkhealth piovim` cannot find `pi`, launch Neovim from the same shell where `pi` works or configure `bin` with the full path to the executable.

## What it does

- **Live editor awareness** — Pi can inspect current/open Neovim buffers, including unsaved changes.
- **Learning-oriented navigation** — Pi can open files, jump to lines, and highlight ranges while explaining code.
- **Previewed buffer edits** — Pi can propose undoable in-place Neovim edits before anything is saved.
- **Code review workflow** — Piovim includes a diff viewer with notes, quickfix export, and Pi-visible annotations.
- **Explicit tool boundary** — Pi uses `nvim_*` tools for live editor state and normal Pi tools for unopened files and disk state.

Pi's full terminal agent workflow is still the better fit for large autonomous edits and repo-wide implementation. Piovim is for moments where Neovim should be the shared workspace: explaining the code under the cursor, reading unsaved buffers, highlighting ranges, previewing small edits, and reviewing diffs with annotations.

## Requirements

- Neovim 0.10+.
- Current [Pi](https://pi.dev) CLI installed as `pi` and authenticated.
- `git` for review diffs and repository comparisons.
- Lazy.nvim or another Neovim plugin manager that can install GitHub repos.

Optional:

- `gh` for GitHub PR review sources (`/diff pr`, `:PiovimReviewPR`).
- [vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator) for `<C-h/j/k/l>` navigation inside Piovim panels.

There are no required Neovim plugin dependencies: no plenary.nvim, Telescope, nui.nvim, diffview.nvim, or Treesitter dependency.

## Configuration

Default setup:

```lua
require("piovim").setup()
```

Common custom setup:

```lua
require("piovim").setup({
  bin = "pi",
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
```

Full option reference:

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
  review = {
    default_base = nil,
    watch_interval_ms = 1500,
    large_line_threshold = 5000,
    omit_line_threshold = 20000,
    max_untracked_file_bytes = 512 * 1024,
  },
})
```

Set any key to `false` or `nil` to skip creating that keymap.

Model/thinking settings are persisted at:

```text
~/.local/state/nvim/piovim/config.json
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

If vim-tmux-navigator is installed, Piovim also maps `<C-h/j/k/l>` inside chat and prompt buffers to tmux-aware window navigation. Without it, those optional maps are not created.

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
- `/diff pr` or `/diff pr 123` opens the current branch PR or a numbered GitHub PR via `gh`.
- `/apply` asks Pi to fix active review notes and resolve them as it goes.

In the Pi prompt buffer, type a slash prefix and press `<Tab>` to complete slash commands. Multiple matches open a picker.

## Context mentions

`<leader>pa` appends a plain mention into the prompt and places the cursor on the next line so the request can be typed below it.

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
- current branch vs default base (`<base>...HEAD`)
- GitHub PR review via `gh pr diff`
- last N commits
- recent commit picker (`git show <sha>`)
- commit range or picked base/head refs (`git diff <range>`)
- patch file (`*.patch` / unified diff text)
- custom `git diff` args

While a review is open, Piovim watches the active review source and refreshes when Git or patch-file contents change. Refreshes are deferred while a review note is being typed or edited so annotations are not interrupted.

Large files are guarded during rendering: files over 5,000 rendered lines are marked as large, and sides over 20,000 rendered lines are omitted with a placeholder instead of filling Neovim with huge buffers.

The diff panes label their sources, such as `OLD · index` and `NEW · worktree`. Alignment filler is rendered blank, while real added blank lines show a faint `+` marker.

Press `?` in a review diff window to show the shortcut list.

Inside the diff view:

| Key | Action |
| --- | --- |
| `]f` / `[f` | Next / previous file |
| `f` | Pick file with preview |
| `b` | Toggle the file-list pane |
| `]h` / `[h` | Next / previous hunk |
| `J` / `K` | Next / previous hunk fallback |
| `a` | Comment on current diff line |
| visual `a` | Comment on selected diff lines |
| `]c` / `[c` | Next / previous review comment |
| `C` / `X` | Next / previous review comment fallback |
| `e` | Edit the current/nearest review comment |
| `x` | Delete the current/nearest review comment |
| `z` | Toggle compact/expanded review comments |
| `c` | Browse review comments with context |
| `s` | Change source/comparison |
| `Q` | Open review comments in quickfix |
| `r` | Refresh current comparison |
| `?` | Show review diff shortcuts |

`:PiovimReviewNotes` opens a review-comment browser with context. `Q` still sends comments to the quickfix list.

Custom diff args support simple shell-like quoting for paths with spaces, e.g. `/diff main...HEAD -- "docs/my file.md"`.

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

## Commands

- `:Piovim`
- `:PiovimToggle`
- `:PiovimAsk`
- `:PiovimAppendContext`
- `:PiovimStop`
- `:PiovimClear`
- `:PiovimVersion`
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
- `:PiovimReviewPR [number]`
- `:PiovimReviewFiles`
- `:PiovimReviewToggleFiles`
- `:PiovimReviewClose`
- `:PiovimReviewRefresh`
- `:PiovimReviewEditNote`
- `:PiovimReviewDeleteNote`
- `:PiovimReviewNotes`

## How it works

Piovim starts Pi in RPC mode with a bundled TypeScript extension:

```text
Neovim buffer/UI state
        │
        ▼
piovim.nvim TCP bridge ◀── Pi RPC process + pi-extension/nvim-tools.ts
        │
        ▼
side-panel chat, edit previews, review annotations
```

The extension registers `nvim_*` tools. Those tools call back into Neovim through a local bridge using a per-session token, so Pi can read live buffers, inspect diagnostics, add highlights, preview edits, and work with the active review diff.

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
make check
```

Or run the underlying checks directly:

```sh
luac -p lua/piovim/*.lua scripts/smoke.lua scripts/review_diff_tests.lua
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -c 'lua require("piovim").setup({ keys = {} })' -c 'qa'
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -S scripts/smoke.lua -c 'qa'
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -S scripts/review_diff_tests.lua -c 'qa'
```

## Release tags

Piovim uses semver git tags. The plugin version lives in `VERSION` and `lua/piovim/version.lua`.

To prepare and tag a release from a clean working tree:

```sh
make release:patch
make release:minor
make release:major
```

For an explicit version:

```sh
make release VERSION=0.1.0
```

Pass release script options through `RELEASE_FLAGS`:

```sh
make release:patch RELEASE_FLAGS=--dry-run
make release:patch RELEASE_FLAGS=--push-tag
```

The release flow updates version files, runs local checks, commits changed version files when needed, and creates an annotated tag named `v<version>`. It does not push branches; `--push-tag` only pushes the tag.

Users can pin a semver tag with Lazy.nvim:

```lua
{
  "lukemelnik/piovim.nvim",
  version = "v0.1.0",
  config = function()
    require("piovim").setup()
  end,
}
```

## Inspiration

Piovim's diff review flow is inspired by [diffview.nvim](https://github.com/sindrets/diffview.nvim): side-by-side review, file navigation, hunk movement, and a review-focused workspace. Piovim does not depend on diffview.nvim; it keeps the diff state inside Piovim so Pi can inspect the active comparison and add or resolve annotations through `nvim_*` tools.

## Status

Piovim is experimental. Expect fast iteration and occasional breaking changes.
