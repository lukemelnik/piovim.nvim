# piovim.nvim

Experimental Neovim frontend for Pi.

Piovim runs Pi in RPC mode and provides a side-panel chat with a bottom prompt, plus explicit `nvim_*` tools for live Neovim buffers.

## Current UX

- `<leader>pp` toggles the Piovim side panel.
- `<leader>pq` asks Pi from a quick prompt.
- `<leader>pa` appends a plain context mention into the prompt, then places the cursor below it.
- `<leader>pc` clears the Pi session, visible chat, and Pi highlights.
- `<Esc>` in the prompt aborts the current Pi turn.
- `/model` and `/thinking` select Pi model/thinking settings.

## Neovim tools

Piovim exposes explicit tools for:

- reading live open buffers, including unsaved changes
- diagnostics
- opening and highlighting buffers/ranges
- previewed unsaved buffer edits
- saving file-backed buffers
- closing unmodified buffers

Model/thinking settings are persisted at `~/.local/state/nvim/piovim/config.json`.

This is intentionally small and experimental.
