local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function M.prompt_context()
  local root = plugin_root()
  return table.concat({
    "Fix piovim.nvim itself.",
    "",
    "Repo: " .. root,
    "Use normal Pi file tools for plugin source changes unless editing an already-open live buffer is specifically needed.",
    "Do not edit my Neovim config unless I explicitly ask.",
    "Keep changes scoped to piovim.nvim.",
    "After changes, run:",
    "- luac -p lua/piovim/*.lua",
    "- nvim --headless -u NONE --cmd 'set rtp^=" .. root .. "' -c 'lua require(\"piovim\").setup({ keys = {} })' -c 'qa'",
    "",
    "My fix request:",
    "",
  }, "\n")
end

return M
