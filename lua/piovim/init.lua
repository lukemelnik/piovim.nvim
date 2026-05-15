local Bridge = require("piovim.bridge")
local Context = require("piovim.context")
local Panel = require("piovim.panel")
local Rpc = require("piovim.rpc")
local SelfFix = require("piovim.self_fix")

local M = {}

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

local function set_panel_keymaps(buf)
  local maps = {
    h = "Left",
    j = "Down",
    k = "Up",
    l = "Right",
  }
  for key, direction in pairs(maps) do
    vim.keymap.set("n", "<C-" .. key .. ">", "<Cmd>TmuxNavigate" .. direction .. "<CR>", { buffer = buf })
    vim.keymap.set("i", "<C-" .. key .. ">", "<Esc><Cmd>TmuxNavigate" .. direction .. "<CR>", { buffer = buf })
  end

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
    vim.keymap.set({ "n", "i" }, "<Esc>", function()
      Rpc.abort()
      vim.cmd("startinsert")
    end, { buffer = buf, desc = "Abort Pi turn" })
    vim.keymap.set("n", "q", function()
      Panel.close()
    end, { buffer = buf, desc = "Close Pi panel" })
  end
end

local function setup_commands()
  vim.api.nvim_create_user_command("Piovim", M.open, { desc = "Open Piovim side panel" })
  vim.api.nvim_create_user_command("PiovimToggle", M.toggle, { desc = "Toggle Piovim side panel" })
  vim.api.nvim_create_user_command("PiovimAsk", M.prompt_input, { desc = "Ask Pi about current selection or buffer", range = true })
  vim.api.nvim_create_user_command("PiovimStop", M.stop, { desc = "Stop Piovim process" })
  vim.api.nvim_create_user_command("PiovimClear", M.clear, { desc = "Clear Piovim session" })
  vim.api.nvim_create_user_command("PiovimClearHighlights", M.clear_highlights, { desc = "Clear Pi code highlights" })
  vim.api.nvim_create_user_command("PiovimAppendContext", M.append_context, { desc = "Append current Pi context mention" })
  vim.api.nvim_create_user_command("PiovimSelfFix", M.append_self_fix_context, { desc = "Append Piovim self-fix context" })
  vim.api.nvim_create_user_command("PiovimAbort", M.abort, { desc = "Abort current Pi turn" })
  vim.api.nvim_create_user_command("PiovimThinkingCycle", M.cycle_thinking_level, { desc = "Cycle Pi thinking level" })
  vim.api.nvim_create_user_command("PiovimThinkingSelect", M.select_thinking_level, { desc = "Select Pi thinking level" })
  vim.api.nvim_create_user_command("PiovimModelSelect", M.select_model, { desc = "Select Pi model" })
  vim.api.nvim_create_user_command("PiovimModelCycle", M.cycle_model, { desc = "Cycle Pi model" })
end

local function setup_keymaps()
  local keys = config.keys or {}
  if keys.toggle then
    vim.keymap.set("n", keys.toggle, M.toggle, { desc = "Piovim toggle" })
  end
  if keys.ask then
    vim.keymap.set({ "n", "v" }, keys.ask, M.prompt_input, { desc = "Piovim ask" })
  end
  if keys.append then
    vim.keymap.set({ "n", "v" }, keys.append, M.append_context, { desc = "Pi append context mention" })
  end
  if keys.stop then
    vim.keymap.set("n", keys.stop, M.stop, { desc = "Piovim stop" })
  end
  if keys.clear then
    vim.keymap.set("n", keys.clear, M.clear, { desc = "Piovim clear" })
  end
  if keys.clear_highlights then
    vim.keymap.set("n", keys.clear_highlights, M.clear_highlights, { desc = "Pi clear highlights" })
  end
  if keys.thinking_cycle then
    vim.keymap.set("n", keys.thinking_cycle, M.cycle_thinking_level, { desc = "Pi thinking cycle" })
  end
  if keys.thinking_select then
    vim.keymap.set("n", keys.thinking_select, M.select_thinking_level, { desc = "Pi thinking select" })
  end
  if keys.model_select then
    vim.keymap.set("n", keys.model_select, M.select_model, { desc = "Pi model select" })
  end
  if keys.model_cycle then
    vim.keymap.set("n", keys.model_cycle, M.cycle_model, { desc = "Pi model cycle" })
  end
end

local function handle_prompt_submit(text)
  if text == "/clear" then
    M.clear()
    return
  end
  if text == "/model" then
    M.select_model()
    return
  end
  if text == "/thinking" then
    M.select_thinking_level()
    return
  end
  if text == "/pi-fix" then
    M.append_self_fix_context()
    return
  end
  M.ask(text)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  Context.setup({ snippet_context_lines = config.snippet_context_lines })
  Bridge.setup_autocmds()
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

end

return M
