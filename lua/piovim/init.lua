local Bridge = require("piovim.bridge")
local Context = require("piovim.context")
local Panel = require("piovim.panel")
local Rpc = require("piovim.rpc")
local ReviewDiff = require("piovim.review_diff")
local SelfFix = require("piovim.self_fix")
local version = require("piovim.version")

local M = {
  version = version,
}

local config = {
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
  dev = {
    self_fix = false,
  },
}


local function ensure_started()
  local port, token = Bridge.start()
  Panel.open({ width = config.side_width, focus_prompt = false })
  if Rpc.is_running() then
    return true
  end
  return Rpc.start({ bin = config.bin, bridge_port = port, bridge_token = token })
end

function M.ask(question, opts)
  opts = opts or {}
  if not question or question == "" then
    return
  end
  if not ensure_started() then
    return
  end

  local context, context_summary
  if opts.context then
    context = opts.context
    context_summary = opts.context_summary
  else
    context, context_summary = Context.build_prompt_context(opts.selection)
  end
  local message = context and context ~= "" and (question .. "\n\n" .. context) or question
  Bridge.clear_highlights()
  Panel.user_message(question, context_summary)
  Rpc.prompt(message)
end

function M.prompt_input()
  local selection = Context.get_visual_selection()
  local no_file_context = Context.should_confirm_no_file_context(selection)
  vim.ui.input({ prompt = "Ask Pi: " }, function(input)
    if not input or input == "" then
      return
    end

    if no_file_context then
      vim.ui.select({ "Ask without file context", "Cancel" }, { prompt = "No file-backed code buffer. Ask anyway?" }, function(choice)
        if choice == "Ask without file context" then
          M.ask(input, { context = "", context_summary = nil })
        end
      end)
      return
    end

    M.ask(input, { selection = selection })
  end)
end

function M.append_context()
  local selection = Context.get_visual_selection()
  local mention = Context.mention(selection)
  if not mention then
    vim.notify("No file-backed code buffer to append", vim.log.levels.WARN)
    return
  end
  Panel.open({ width = config.side_width, focus_prompt = true })
  ensure_started()
  Panel.append_prompt_text(mention .. "\n")
end

local function self_fix_enabled()
  return config.dev and config.dev.self_fix == true
end

function M.append_self_fix_context()
  if not self_fix_enabled() then
    vim.notify("Piovim self-fix mode is not enabled", vim.log.levels.WARN)
    return
  end

  Panel.open({ width = config.side_width, focus_prompt = true })
  ensure_started()
  Panel.append_prompt_text(SelfFix.prompt_context())
end

function M.toggle()
  Panel.toggle({ width = config.side_width, focus_prompt = true })
  if Panel.is_open() then
    ensure_started()
    Panel.focus_prompt()
  end
end

function M.open()
  Panel.open({ width = config.side_width, focus_prompt = true })
  ensure_started()
  Panel.focus_prompt()
end

function M.stop()
  Rpc.stop()
  Panel.close()
end

function M.clear()
  Rpc.stop()
  Bridge.clear_highlights()
  Panel.clear()
  Panel.open({ width = config.side_width, focus_prompt = true })
  Panel.focus_prompt()
end

function M.clear_highlights()
  Bridge.clear_highlights()
end

function M.abort()
  Rpc.abort()
end

function M.cycle_thinking_level()
  if ensure_started() then
    Rpc.cycle_thinking_level()
  end
end

function M.select_thinking_level()
  if not ensure_started() then
    return
  end
  vim.ui.select({ "off", "minimal", "low", "medium", "high", "xhigh" }, { prompt = "Pi thinking level" }, function(level)
    if level then
      Rpc.set_thinking_level(level)
    end
  end)
end

function M.select_model()
  if ensure_started() then
    Rpc.select_model()
  end
end

function M.cycle_model()
  if ensure_started() then
    Rpc.cycle_model()
  end
end

function M.apply_review_fixes()
  if not ensure_started() then
    return
  end
  local message = ReviewDiff.summary()
  Panel.user_message("/apply", "Active review diff notes")
  Rpc.prompt(message)
end

local slash_commands = {}
local configured_keymaps = {}

local function register_slash_commands()
  slash_commands = {
    { name = "/clear", description = "Clear Pi session", handler = M.clear },
    { name = "/model", description = "Select model", handler = M.select_model },
    { name = "/thinking", description = "Select thinking level", handler = M.select_thinking_level },
    { name = "/pi-fix", description = "Append Piovim self-fix context", handler = M.append_self_fix_context },
    { name = "/diff", description = "Open review diff picker", handler = ReviewDiff.pick, accepts_args = true },
    { name = "/apply", description = "Ask Pi to apply active review notes", handler = M.apply_review_fixes },
  }
  Panel.set_slash_commands(slash_commands)
end

local function set_tmux_navigation_keymaps(buf)
  local maps = {
    h = "Left",
    j = "Down",
    k = "Up",
    l = "Right",
  }
  for key, direction in pairs(maps) do
    local command = "TmuxNavigate" .. direction
    if vim.fn.exists(":" .. command) == 2 then
      vim.keymap.set("n", "<C-" .. key .. ">", "<Cmd>" .. command .. "<CR>", { buffer = buf, desc = "Tmux navigate " .. direction })
      vim.keymap.set("i", "<C-" .. key .. ">", "<Esc><Cmd>" .. command .. "<CR>", { buffer = buf, desc = "Tmux navigate " .. direction })
    end
  end
end

local function set_panel_keymaps(buf)
  set_tmux_navigation_keymaps(buf)

  local ft = vim.bo[buf].filetype
  if ft == "piovim-chat" then
    vim.keymap.set("n", "i", Panel.focus_prompt, { buffer = buf, desc = "Focus Pi prompt" })
    vim.keymap.set("n", "q", function()
      Panel.close()
    end, { buffer = buf, desc = "Close Pi panel" })
  elseif ft == "piovim-prompt" then
    vim.keymap.set({ "n", "i" }, "<CR>", function()
      Panel.submit_prompt()
    end, { buffer = buf, desc = "Submit Pi prompt" })
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
      Panel.clear_prompt()
      vim.cmd("startinsert")
    end, { buffer = buf, desc = "Clear Pi prompt" })
    vim.keymap.set({ "n", "i" }, "<C-u>", function()
      Panel.clear_prompt()
      vim.cmd("startinsert")
    end, { buffer = buf, desc = "Clear Pi prompt" })
    vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = buf, desc = "Leave insert mode" })
    vim.keymap.set("n", "<Esc>", function()
      Rpc.abort()
    end, { buffer = buf, desc = "Abort Pi turn" })
    vim.keymap.set("i", "<Tab>", function()
      if Panel.complete_slash_command() then
        return ""
      end
      return vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
    end, { buffer = buf, desc = "Complete Pi slash command", expr = true })
    vim.keymap.set("n", "<Tab>", function()
      Panel.complete_slash_command()
    end, { buffer = buf, desc = "Complete Pi slash command" })
    vim.keymap.set("n", "q", function()
      Panel.close()
    end, { buffer = buf, desc = "Close Pi panel" })
  end
end

local function setup_commands()
  local function command(name, callback, opts)
    vim.api.nvim_create_user_command(name, callback, vim.tbl_extend("force", opts or {}, { force = true }))
  end

  command("Piovim", M.open, { desc = "Open Piovim side panel" })
  command("PiovimToggle", M.toggle, { desc = "Toggle Piovim side panel" })
  command("PiovimAsk", M.prompt_input, { desc = "Ask Pi about current selection or buffer", range = true })
  command("PiovimStop", M.stop, { desc = "Stop Piovim process" })
  command("PiovimClear", M.clear, { desc = "Clear Piovim session" })
  command("PiovimVersion", function()
    print("piovim.nvim " .. M.version)
  end, { desc = "Print Piovim version" })
  command("PiovimClearHighlights", M.clear_highlights, { desc = "Clear Pi code highlights" })
  command("PiovimAppendContext", M.append_context, { desc = "Append current Pi context mention" })
  command("PiovimSelfFix", M.append_self_fix_context, { desc = "Append Piovim self-fix context" })
  command("PiovimAbort", M.abort, { desc = "Abort current Pi turn" })
  command("PiovimThinkingCycle", M.cycle_thinking_level, { desc = "Cycle Pi thinking level" })
  command("PiovimThinkingSelect", M.select_thinking_level, { desc = "Select Pi thinking level" })
  command("PiovimModelSelect", M.select_model, { desc = "Select Pi model" })
  command("PiovimModelCycle", M.cycle_model, { desc = "Cycle Pi model" })
  ReviewDiff.setup_commands()
end

local function set_keymap(modes, lhs, rhs, desc)
  if not lhs then
    return
  end
  vim.keymap.set(modes, lhs, rhs, { desc = desc })
  table.insert(configured_keymaps, { modes = type(modes) == "table" and modes or { modes }, lhs = lhs })
end

local function clear_configured_keymaps()
  for _, map in ipairs(configured_keymaps) do
    for _, mode in ipairs(map.modes) do
      pcall(vim.keymap.del, mode, map.lhs)
    end
  end
  configured_keymaps = {}
end

local function setup_keymaps()
  clear_configured_keymaps()
  local keys = config.keys or {}
  set_keymap("n", keys.toggle, M.toggle, "Piovim toggle")
  set_keymap({ "n", "v" }, keys.ask, M.prompt_input, "Piovim ask")
  set_keymap({ "n", "v" }, keys.append, M.append_context, "Pi append context mention")
  set_keymap("n", keys.stop, M.stop, "Piovim stop")
  set_keymap("n", keys.clear, M.clear, "Piovim clear")
  set_keymap("n", keys.clear_highlights, M.clear_highlights, "Pi clear highlights")
  set_keymap("n", keys.thinking_cycle, M.cycle_thinking_level, "Pi thinking cycle")
  set_keymap("n", keys.thinking_select, M.select_thinking_level, "Pi thinking select")
  set_keymap("n", keys.model_select, M.select_model, "Pi model select")
  set_keymap("n", keys.model_cycle, M.cycle_model, "Pi model cycle")
  set_keymap("n", keys.diff, ReviewDiff.pick, "Pi review diff")
  set_keymap("n", keys.close_diff, ReviewDiff.close, "Pi close review diff")
end

local function handle_prompt_submit(text)
  if text:sub(1, 1) == "/" then
    local name, args = text:match("^(%S+)%s*(.*)$")
    for _, command in ipairs(slash_commands) do
      if command.name == name then
        if command.name == "/diff" and args ~= "" then
          ReviewDiff.open(args)
        else
          command.handler(args)
        end
        return
      end
    end
  end
  M.ask(text)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  Context.setup({ snippet_context_lines = config.snippet_context_lines })
  ReviewDiff.setup(config.review or {})
  Bridge.setup_autocmds()
  register_slash_commands()
  Panel.set_on_submit(handle_prompt_submit)
  setup_commands()
  setup_keymaps()

  local group = vim.api.nvim_create_augroup("piovim-panel", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "piovim-chat", "piovim-prompt" },
    callback = function(event)
      set_panel_keymaps(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "piovim://prompt",
    callback = function()
      Panel.update_prompt_hints()
    end,
  })

end

return M
