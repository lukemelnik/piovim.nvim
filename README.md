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

## Development

Run local checks:

```sh
luac -p lua/piovim/*.lua
nvim --headless -u NONE --cmd 'set rtp^=/path/to/piovim.nvim' -c 'lua require("piovim").setup({ keys = {} })' -c 'qa'
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
