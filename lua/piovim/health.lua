local M = {}

local function start(name)
  if vim.health and vim.health.start then
    vim.health.start(name)
  else
    vim.fn['health#report_start'](name)
  end
end

local function ok(message)
  if vim.health and vim.health.ok then
    vim.health.ok(message)
  else
    vim.fn['health#report_ok'](message)
  end
end

local function warn(message, advice)
  if vim.health and vim.health.warn then
    vim.health.warn(message, advice)
  else
    vim.fn['health#report_warn'](message, advice or {})
  end
end

local function error_report(message, advice)
  if vim.health and vim.health.error then
    vim.health.error(message, advice)
  else
    vim.fn['health#report_error'](message, advice or {})
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function M.check()
  start("piovim.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim 0.10+ detected")
  else
    error_report("Neovim 0.10+ is required")
  end

  if vim.fn.executable("pi") == 1 then
    ok("pi CLI found on PATH")
  else
    error_report("pi CLI not found on PATH", { "Install Pi and make sure `pi` is executable from Neovim's PATH." })
  end

  if vim.fn.executable("git") == 1 then
    ok("git found on PATH")
  else
    error_report("git not found on PATH")
  end

  if vim.fn.executable("gh") == 1 then
    ok("gh found on PATH for PR review sources")
  else
    warn("gh not found; GitHub PR review sources are unavailable", { "Install GitHub CLI to review GitHub PR diffs from Piovim." })
  end

  ok("No required Neovim plugin dependencies")
  if vim.fn.exists(":TmuxNavigateLeft") == 2 then
    ok("Optional vim-tmux-navigator commands found for panel navigation")
  else
    ok("Optional vim-tmux-navigator commands not found; Ctrl-h/j/k/l panel navigation is disabled")
  end

  local extension = plugin_root() .. "/pi-extension/nvim-tools.ts"
  if vim.fn.filereadable(extension) == 1 then
    ok("Pi Neovim extension found")
  else
    error_report("Pi Neovim extension missing", { extension })
  end
end

return M
