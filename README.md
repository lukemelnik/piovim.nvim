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

### 2. Install piovim.nvim

With Lazy.nvim:

```lua
{
  "lukemelnik/piovim.nvim",
  version = "v0.2.0",
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
- **Session tree rewind** — `:PiovimTree` opens the current Pi session tree so tangents can be discarded from context.
- **Context usage status** — The prompt winbar shows current context-window usage and whether Pi auto-compaction is enabled.
- **Explicit tool boundary** — Pi uses `nvim_*` tools for live editor state and normal Pi tools for unopened files and disk state.

Pi's full terminal agent workflow is still the better fit for large autonomous edits and repo-wide implementation. Piovim is for moments where Neovim should be the shared workspace: explaining the code under the cursor, reading unsaved buffers, highlighting ranges, and previewing small edits.

## Requirements

- Neovim 0.10+.
- Current [Pi](https://pi.dev) CLI installed as `pi` and authenticated.
- Lazy.nvim or another Neovim plugin manager that can install GitHub repos.

Optional:

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
    auto_accept_edits = "<leader>pe",
    thinking_select = "<leader>pt",
    thinking_cycle = "<leader>pT",
    model_select = "<leader>pm",
    model_cycle = "<leader>pM",
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
    auto_accept_edits = "<leader>pe",
    thinking_select = "<leader>pt",
    thinking_cycle = "<leader>pT",
    model_select = "<leader>pm",
    model_cycle = "<leader>pM",
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
| `<leader>pe` | Toggle direct application of Pi edit previews for this session |
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
- `/tree` opens the Pi session tree picker.

Piovim also asks the Pi RPC backend for extension commands, prompt templates, and skills, then includes them in slash completion. Unknown slash commands are forwarded to Pi exactly as typed.

In the Pi prompt buffer, type a slash prefix and press `<Tab>` to complete slash commands. Multiple matches open a picker. Use `:PiovimRefreshCommands` to refresh completion after changing or reloading extensions.

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

## Diff review workflow

Piovim does not own a diff review UI. Use a dedicated Neovim diff plugin such as `diffview.nvim` for branch, worktree, staged, commit, and file-history review. Piovim focuses on exposing stable live-buffer tools to Pi.

A useful Diffview command for branch review is:

```vim
:DiffviewOpen origin/main...HEAD --imply-local
```

The `--imply-local` flag shows the worktree version on the right side, so Piovim's generic `nvim_*` tools can inspect the same live buffers you are reviewing.

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

`nvim_edit_buffer` shows an in-place diff preview before applying unsaved, undoable Neovim buffer edits. It supports both exact replacements and explicit range edits for insertions/empty buffers.

`nvim_save_buffer` saves file-backed buffers. `nvim_close_buffer` only closes unmodified buffers and refuses to discard unsaved changes.

## Commands

- `:Piovim`
- `:PiovimToggle`
- `:PiovimAsk`
- `:PiovimAppendContext`
- `:PiovimStop`
- `:PiovimClear`
- `:PiovimVersion`
- `:PiovimClearHighlights`
- `:PiovimToggleEditAutoAccept`
- `:PiovimAbort`
- `:PiovimThinkingSelect`
- `:PiovimThinkingCycle`
- `:PiovimModelSelect`
- `:PiovimModelCycle`
- `:PiovimTree`
- `:PiovimRefreshCommands`

## How it works

Piovim starts Pi in RPC mode with a bundled TypeScript extension:

```text
Neovim buffer/UI state
        │
        ▼
piovim.nvim TCP bridge ◀── Pi RPC process + pi-extension/nvim-tools.ts
        │
        ▼
side-panel chat and edit previews
```

The extension registers fixed `nvim_*` tools. Tools call back into Neovim through a local bridge using a per-session token, so Pi can read live buffers, inspect diagnostics, add highlights, and preview edits.

## Development

Code layout:

- `lua/piovim/init.lua` wires setup, commands, keymaps, and user actions.
- `lua/piovim/context.lua` builds prompt context and plain `@buffer` / `@selection` mentions.
- `lua/piovim/panel.lua` owns the side-panel UI and prompt buffer.
- `lua/piovim/rpc.lua` starts Pi RPC mode and renders Pi events into the panel.
- `lua/piovim/bridge.lua` owns the local TCP bridge between Pi and Neovim.
- `lua/piovim/buffer_ops.lua` implements Neovim buffer tools.
- `lua/piovim/edit_preview.lua` renders in-place edit previews.
- `pi-extension/nvim-tools.ts` registers Pi-side `nvim_*` tools.

Run local checks:

```sh
make check
```

Or run the underlying checks directly:

```sh
luac -p lua/piovim/*.lua scripts/smoke.lua
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -c 'lua require("piovim").setup({ keys = {} })' -c 'qa'
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -S scripts/smoke.lua -c 'qa'
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
  version = "v0.2.0",
  config = function()
    require("piovim").setup()
  end,
}
```

## Status

Piovim is experimental. Expect fast iteration and occasional breaking changes.
