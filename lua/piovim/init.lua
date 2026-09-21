local Bridge = require("piovim.bridge")
local Context = require("piovim.context")
local Panel = require("piovim.panel")
local Rpc = require("piovim.rpc")
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
    auto_accept_edits = "<leader>pe",
    thinking_select = "<leader>pt",
    thinking_cycle = "<leader>pT",
    model_select = "<leader>pm",
    model_cycle = "<leader>pM",
  },
  dev = {
    self_fix = false,
  },
}

local local_slash_commands = {}
local remote_slash_commands = {}
local slash_commands = {}
local commands_loaded = false
local commands_refresh_in_flight = false
local refresh_remote_slash_commands

local function normalize_slash_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if name:sub(1, 1) == "/" then
    return name
  end
  return "/" .. name
end

local function merge_slash_commands()
  local merged = {}
  local seen = {}

  local function add(command)
    if type(command) ~= "table" then
      return
    end
    local name = normalize_slash_name(command.name)
    if not name or seen[name] then
      return
    end
    seen[name] = true
    merged[#merged + 1] = vim.tbl_extend("force", command, { name = name })
  end

  for _, command in ipairs(local_slash_commands) do
    add(command)
  end
  for _, command in ipairs(remote_slash_commands) do
    add(command)
  end

  slash_commands = merged
  Panel.set_slash_commands(slash_commands)
end

local function ensure_started()
  local port, token = Bridge.start()
  Panel.open({ width = config.side_width, focus_prompt = false })
  if Rpc.is_running() then
    if refresh_remote_slash_commands then
      refresh_remote_slash_commands()
    end
    return true
  end

  local started = Rpc.start({
    bin = config.bin,
    bridge_port = port,
    bridge_token = token,
    on_lifecycle = function(event)
      if event == "stopped" or event == "exited" then
        commands_refresh_in_flight = false
        commands_loaded = false
        remote_slash_commands = {}
        merge_slash_commands()
      end
    end,
  })
  if started and refresh_remote_slash_commands then
    refresh_remote_slash_commands(true)
  end
  return started
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

local function reset_panel()
  Bridge.clear_highlights()
  Panel.clear()
  Panel.open({ width = config.side_width, focus_prompt = true })
  Panel.focus_prompt()
end

function M.clear()
  if Rpc.is_running() and not Rpc.is_streaming() then
    Rpc.new_session(function(cleared)
      if cleared then
        reset_panel()
      end
    end)
    return
  end

  Rpc.stop()
  reset_panel()
end

function M.clear_highlights()
  Bridge.clear_highlights()
end

function M.toggle_edit_auto_accept()
  local enabled = vim.g.piovim_auto_accept_edits ~= true
  vim.g.piovim_auto_accept_edits = enabled

  if enabled then
    vim.notify("Pi edit previews disabled for this session; edits will apply directly", vim.log.levels.INFO)
  else
    vim.notify("Pi edit previews enabled; edits will ask before applying", vim.log.levels.INFO)
  end

  return enabled
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

function M.tree()
  if ensure_started() then
    Rpc.tree()
  end
end

function M.refresh_commands()
  if ensure_started() and refresh_remote_slash_commands then
    refresh_remote_slash_commands(true)
  end
end

local configured_keymaps = {}

refresh_remote_slash_commands = function(force)
  if not Rpc.is_running() then
    return false
  end
  if commands_refresh_in_flight then
    return false
  end
  if commands_loaded and not force then
    return false
  end

  commands_refresh_in_flight = true
  local dispatched = Rpc.get_commands(function(commands)
    commands_refresh_in_flight = false
    if type(commands) ~= "table" then
      return
    end

    local remote = {}
    for _, command in ipairs(commands) do
      local name = normalize_slash_name(command.name)
      if name then
        remote[#remote + 1] = {
          name = name,
          description = command.description or command.source or "",
          source = command.source,
          location = command.location,
          path = command.path,
        }
      end
    end

    remote_slash_commands = remote
    commands_loaded = true
    merge_slash_commands()
  end)
  if not dispatched then
    commands_refresh_in_flight = false
  end
  return dispatched
end

local function register_slash_commands()
  local_slash_commands = {
    { name = "/clear", description = "Clear Pi session", source = "piovim", handler = M.clear },
    { name = "/model", description = "Select model", source = "piovim", handler = M.select_model },
    { name = "/thinking", description = "Select thinking level", source = "piovim", handler = M.select_thinking_level },
    { name = "/tree", description = "Navigate Pi session tree", source = "piovim", handler = M.tree },
    { name = "/pi-fix", description = "Append Piovim self-fix context", source = "piovim", handler = M.append_self_fix_context },
  }
  merge_slash_commands()
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
      local text = Panel.prompt_text()
      if text:sub(1, 1) == "/" and not text:find("%s") then
        vim.schedule(function()
          Panel.complete_slash_command()
        end)
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
  command("PiovimToggleEditAutoAccept", M.toggle_edit_auto_accept, { desc = "Toggle direct application of Pi edit previews" })
  command("PiovimAppendContext", M.append_context, { desc = "Append current Pi context mention" })
  command("PiovimSelfFix", M.append_self_fix_context, { desc = "Append Piovim self-fix context" })
  command("PiovimAbort", M.abort, { desc = "Abort current Pi turn" })
  command("PiovimThinkingCycle", M.cycle_thinking_level, { desc = "Cycle Pi thinking level" })
  command("PiovimThinkingSelect", M.select_thinking_level, { desc = "Select Pi thinking level" })
  command("PiovimModelSelect", M.select_model, { desc = "Select Pi model" })
  command("PiovimModelCycle", M.cycle_model, { desc = "Cycle Pi model" })
  command("PiovimTree", M.tree, { desc = "Navigate Pi session tree" })
  command("PiovimRefreshCommands", M.refresh_commands, { desc = "Refresh Pi slash command completion" })
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
  set_keymap("n", keys.auto_accept_edits, M.toggle_edit_auto_accept, "Pi toggle edit auto-accept")
  set_keymap("n", keys.thinking_cycle, M.cycle_thinking_level, "Pi thinking cycle")
  set_keymap("n", keys.thinking_select, M.select_thinking_level, "Pi thinking select")
  set_keymap("n", keys.model_select, M.select_model, "Pi model select")
  set_keymap("n", keys.model_cycle, M.cycle_model, "Pi model cycle")
end

local function handle_prompt_submit(text)
  if text:sub(1, 1) == "/" then
    local name, args = text:match("^(%S+)%s*(.*)$")
    for _, command in ipairs(local_slash_commands) do
      if command.name == name then
        command.handler(args)
        return
      end
    end

    -- Let Pi handle extension commands, prompt templates, and skills. These
    -- must be sent exactly as typed; adding Neovim context turns them into a
    -- normal model prompt instead of a slash command.
    M.ask(text, { context = "", context_summary = nil })
    return
  end
  M.ask(text)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  Context.setup({ snippet_context_lines = config.snippet_context_lines })
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
