local Panel = require("piovim.panel")
local Store = require("piovim.store")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  job = nil,
  next_id = 1,
  stdout_pending = "",
  streaming = false,
  status_mode = "idle",
  tool_name = nil,
  model_name = nil,
  thinking_level = nil,
  callbacks = {},
  spinner_timer = nil,
  spinner_index = 1,
}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function append_error(message)
  Panel.system("error: " .. message)
end

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function update_status()
  local parts = {}
  if state.model_name then
    parts[#parts + 1] = tostring(state.model_name)
  end
  if state.thinking_level then
    parts[#parts + 1] = tostring(state.thinking_level)
  end
  local frame = spinner_frames[state.spinner_index] or "⠋"
  if state.status_mode == "streaming" then
    parts[#parts + 1] = "thinking " .. frame
  elseif state.status_mode == "tool" and state.tool_name then
    parts[#parts + 1] = tostring(state.tool_name) .. " " .. frame
  end
  Panel.set_status(table.concat(parts, " · "))
end

local function stop_spinner()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
  state.spinner_index = 1
end

local function start_spinner()
  if state.spinner_timer then
    return
  end
  local timer = uv.new_timer()
  state.spinner_timer = timer
  timer:start(0, 120, vim.schedule_wrap(function()
    if state.status_mode == "idle" then
      stop_spinner()
      update_status()
      return
    end
    state.spinner_index = (state.spinner_index % #spinner_frames) + 1
    update_status()
  end))
end

local function set_status_mode(mode, tool_name)
  state.status_mode = mode
  state.tool_name = tool_name
  if mode == "idle" then
    stop_spinner()
  else
    start_spinner()
  end
  update_status()
end

local function model_label(model)
  if type(model) ~= "table" then
    return nil
  end
  return model.name or model.id or model.modelId
end

local function persist_state(data)
  if type(data) ~= "table" then
    return
  end

  local values = {}
  local model = data.model
  if type(model) == "table" then
    local id = model.id or model.modelId
    if id then
      values.model = {
        provider = model.provider,
        id = id,
        name = model.name,
      }
    end
  end
  local thinking = data.thinkingLevel or data.level
  if thinking then
    values.thinking = thinking
  end
  if next(values) then
    Store.update(values)
  end
end

local function handle_response(msg)
  if msg.success == false then
    append_error(msg.error or ("RPC command failed: " .. tostring(msg.command)))
    return
  end

  if msg.command == "get_state" and type(msg.data) == "table" then
    local model = msg.data.model
    state.model_name = model_label(model) or state.model_name
    state.thinking_level = msg.data.thinkingLevel or state.thinking_level
    persist_state(msg.data)
    update_status()
    return
  end

  if msg.command == "cycle_thinking_level" and type(msg.data) == "table" then
    state.thinking_level = msg.data.level or state.thinking_level
    persist_state(msg.data)
    update_status()
    return
  end

  if msg.command == "cycle_model" then
    local data = msg.data or {}
    local model = data.model
    state.model_name = model_label(model) or state.model_name
    state.thinking_level = data.thinkingLevel or state.thinking_level
    persist_state(data)
    update_status()
    return
  end

  if msg.command == "set_model" then
    M.refresh_state()
    return
  end

  if msg.command == "set_thinking_level" then
    M.refresh_state()
  end
end

local function handle_extension_ui_request(msg)
  if msg.method == "notify" then
    Panel.system(msg.message or "extension notification")
    return
  end

  if msg.method == "select" then
    vim.ui.select(msg.options or {}, { prompt = msg.title or "Pi" }, function(choice)
      if choice == nil then
        M.send({ type = "extension_ui_response", id = msg.id, cancelled = true })
      else
        M.send({ type = "extension_ui_response", id = msg.id, value = choice })
      end
    end)
    return
  end

  if msg.method == "confirm" then
    vim.ui.select({ "Yes", "No" }, { prompt = (msg.title or "Confirm") .. "\n" .. (msg.message or "") }, function(choice)
      M.send({ type = "extension_ui_response", id = msg.id, confirmed = choice == "Yes" })
    end)
    return
  end

  if msg.method == "input" or msg.method == "editor" then
    vim.ui.input({ prompt = msg.title or "Pi input", default = msg.prefill or "" }, function(value)
      if value == nil then
        M.send({ type = "extension_ui_response", id = msg.id, cancelled = true })
      else
        M.send({ type = "extension_ui_response", id = msg.id, value = value })
      end
    end)
  end
end

local function handle_event(msg)
  if msg.type == "response" then
    if msg.id and state.callbacks[msg.id] then
      local callback = state.callbacks[msg.id]
      state.callbacks[msg.id] = nil
      callback(msg)
    end
    handle_response(msg)
    return
  end

  if msg.type == "agent_start" then
    state.streaming = true
    set_status_mode("streaming")
    return
  end

  if msg.type == "agent_end" then
    state.streaming = false
    set_status_mode("idle")
    Panel.assistant_end()
    return
  end

  if msg.type == "message_update" then
    local event = msg.assistantMessageEvent
    if event and event.type == "text_delta" then
      Panel.assistant_delta(event.delta or "")
    end
    return
  end

  if msg.type == "tool_execution_start" then
    set_status_mode("tool", msg.toolName or "tool")
    Panel.tool_start(msg.toolName or "tool", msg.args)
    return
  end

  if msg.type == "tool_execution_end" then
    set_status_mode(state.streaming and "streaming" or "idle")
    Panel.tool_end(msg.toolName or "tool", msg.isError == true)
    return
  end

  if msg.type == "extension_ui_request" then
    handle_extension_ui_request(msg)
    return
  end

  if msg.type == "extension_error" then
    append_error(msg.error or "extension error")
  end
end

local function handle_line(line)
  if line == "" then
    return
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    append_error("failed to parse Pi RPC output")
    return
  end

  vim.schedule(function()
    handle_event(msg)
  end)
end

local function handle_stdout(data)
  if not data then
    return
  end

  for i, line in ipairs(data) do
    if i == 1 then
      line = state.stdout_pending .. line
      state.stdout_pending = ""
    end

    if i == #data and line ~= "" then
      state.stdout_pending = line
    else
      handle_line(line)
    end
  end
end

function M.is_running()
  return state.job ~= nil
end

function M.is_streaming()
  return state.streaming
end

function M.start(opts)
  opts = opts or {}
  if state.job then
    return true
  end

  local extension_path = plugin_root() .. "/pi-extension/nvim-tools.ts"
  local append_prompt = table.concat({
    "You are running inside Neovim via piovim.nvim.",
    "The user may ask about live unsaved Neovim buffers. Prefer nvim_* tools for current/open buffers when editor state matters.",
    "Use normal Pi file tools for unopened files, project-wide search, and disk state.",
    "Use nvim_edit_buffer only when the user asks to change an open/current Neovim buffer; those edits are unsaved and undoable in Neovim.",
    "Use nvim_save_buffer only when the user asks to save an open file-backed buffer. Use nvim_close_buffer only for unmodified buffers; it must not discard changes.",
  }, "\n")

  state.model_name = nil
  state.thinking_level = nil
  state.streaming = false
  set_status_mode("idle")
  local saved = Store.get()
  local cmd = {
    opts.bin or "pi",
    "--mode",
    "rpc",
    "--no-session",
    "--extension",
    extension_path,
    "--append-system-prompt",
    append_prompt,
  }

  if type(saved.model) == "table" and saved.model.id then
    local pattern = saved.model.id
    if saved.model.provider and saved.model.provider ~= "" and not tostring(pattern):find("/", 1, true) then
      pattern = saved.model.provider .. "/" .. pattern
    end
    table.insert(cmd, "--model")
    table.insert(cmd, pattern)
    state.model_name = saved.model.name or saved.model.id
  end
  if saved.thinking then
    table.insert(cmd, "--thinking")
    table.insert(cmd, tostring(saved.thinking))
    state.thinking_level = saved.thinking
  end
  update_status()

  state.stdout_pending = ""
  state.job = vim.fn.jobstart(cmd, {
    cwd = vim.fn.getcwd(),
    env = {
      PIOVIM_BRIDGE_PORT = tostring(opts.bridge_port),
      PIOVIM_BRIDGE_TOKEN = opts.bridge_token,
    },
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      handle_stdout(data)
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      local lines = {}
      for _, line in ipairs(data) do
        if line ~= "" then
          lines[#lines + 1] = line
        end
      end
      if #lines > 0 then
        vim.schedule(function()
          Panel.system(table.concat(lines, "\n"))
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        state.job = nil
        state.streaming = false
        set_status_mode("idle")
        Panel.system("Pi process exited (" .. tostring(code) .. ")")
      end)
    end,
  })

  if state.job <= 0 then
    state.job = nil
    Panel.system("failed to start pi")
    return false
  end

  Panel.system("Pi started")
  vim.defer_fn(function()
    M.refresh_state()
  end, 250)
  return true
end

function M.stop()
  if not state.job then
    return
  end
  local job = state.job
  state.job = nil
  state.streaming = false
  set_status_mode("idle")
  vim.fn.jobstop(job)
  Panel.system("Pi stopped")
end

function M.send(command, callback)
  if not state.job then
    return false
  end

  command.id = command.id or ("piovim-" .. state.next_id)
  if callback then
    state.callbacks = state.callbacks or {}
    state.callbacks[command.id] = callback
  end
  state.next_id = state.next_id + 1
  vim.fn.chansend(state.job, vim.json.encode(command) .. "\n")
  return true
end

function M.prompt(message)
  local command = {
    type = "prompt",
    message = message,
  }

  if state.streaming then
    command.streamingBehavior = "followUp"
  end

  return M.send(command)
end

function M.refresh_state()
  if state.job then
    M.send({ type = "get_state" })
  end
end

function M.cycle_thinking_level()
  if state.job then
    M.send({ type = "cycle_thinking_level" })
  end
end

function M.set_thinking_level(level)
  if state.job then
    M.send({ type = "set_thinking_level", level = level })
  end
end

function M.cycle_model()
  if state.job then
    M.send({ type = "cycle_model" })
  end
end

function M.select_model()
  if not state.job then
    return
  end

  M.send({ type = "get_available_models" }, function(msg)
    if not msg.success then
      append_error(msg.error or "Failed to get available models")
      return
    end

    local models = (msg.data or {}).models or {}
    if #models == 0 then
      Panel.system("No available models")
      return
    end

    local labels = {}
    local by_label = {}
    for _, model in ipairs(models) do
      local provider = model.provider or "unknown"
      local id = model.id or "unknown"
      local name = model.name or id
      local label = provider .. "/" .. id
      if name ~= id then
        label = label .. " — " .. name
      end
      labels[#labels + 1] = label
      by_label[label] = model
    end

    vim.ui.select(labels, { prompt = "Pi model" }, function(label)
      if not label then
        return
      end
      local model = by_label[label]
      if model then
        M.send({ type = "set_model", provider = model.provider, modelId = model.id })
      end
    end)
  end)
end

function M.abort()
  if state.job then
    M.send({ type = "abort" })
    state.streaming = false
    set_status_mode("idle")
    Panel.cancelled()
  end
end

return M
