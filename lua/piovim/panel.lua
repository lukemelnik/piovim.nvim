local PluginBuffer = require("piovim.plugin_buffer")

local M = {}

local state = {
  history_buf = nil,
  history_win = nil,
  prompt_buf = nil,
  prompt_win = nil,
  active_assistant = false,
  on_submit = nil,
  slash_commands = {},
  status = "",
}

local ns = vim.api.nvim_create_namespace("piovim")
local pattern_ns = vim.api.nvim_create_namespace("piovim-patterns")
local prompt_hint_ns = vim.api.nvim_create_namespace("piovim-prompt-hints")
local highlights_ready = false
local protection_ready = false
local protecting = false

local function setup_highlights()
  if highlights_ready then
    return
  end
  highlights_ready = true
  vim.api.nvim_set_hl(0, "PiovimTitle", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "PiovimMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "PiovimUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "PiovimAssistant", { default = true, link = "Function" })
  vim.api.nvim_set_hl(0, "PiovimSystem", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "PiovimTool", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "PiovimPath", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "PiovimCode", { default = true, link = "String" })
  vim.api.nvim_set_hl(0, "PiovimPrompt", { default = true, link = "Question" })
  vim.api.nvim_set_hl(0, "PiovimPromptHint", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "PiovimDivider", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "PiovimCancelled", { default = true, link = "DiagnosticError" })
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_pi_buf(buf)
  return PluginBuffer.is_plugin_buffer(buf)
end

local function source_win()
  local best_win = nil
  local best_area = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not is_pi_buf(buf) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_win = win
        best_area = area
      end
    end
  end
  return best_win
end

local function ensure_source_win()
  local win = source_win()
  if win then
    return win
  end

  local current = vim.api.nvim_get_current_win()
  vim.cmd("topleft vnew")
  local created = vim.api.nvim_get_current_win()
  if valid_win(current) then
    vim.api.nvim_set_current_win(current)
  end
  return created
end

local function set_modifiable(buf, value)
  vim.bo[buf].modifiable = value
end

local function add_match(buf, row, line, pattern, hl_group)
  local init = 1
  while init <= #line do
    local start_col, end_col = line:find(pattern, init)
    if not start_col then
      break
    end
    if end_col >= start_col then
      vim.api.nvim_buf_set_extmark(buf, pattern_ns, row, start_col - 1, {
        end_col = end_col,
        hl_group = hl_group,
        priority = 120,
      })
    end
    init = end_col + 1
  end
end

local function highlight_patterns(buf, start_row, lines)
  vim.api.nvim_buf_clear_namespace(buf, pattern_ns, start_row, start_row + #lines)
  for i, line in ipairs(lines) do
    local row = start_row + i - 1
    add_match(buf, row, line, "`[^`]+`", "PiovimCode")
    add_match(buf, row, line, "@[%w%._~/%-]+#?L?%d*%-?%d*", "PiovimPath")
    add_match(buf, row, line, "[%w%._~%-]+/[%w%._~/%-]+", "PiovimPath")
    add_match(buf, row, line, "[%w%._%-]+%.[%w_%-]+:%d+", "PiovimPath")
  end
end

local function start_markdown_highlighter(buf)
  vim.bo[buf].syntax = "markdown"
  pcall(vim.treesitter.language.register, "markdown", "piovim-chat")
  pcall(vim.treesitter.start, buf, "markdown")
end

local function protect_panel_windows()
  if protecting then
    return
  end
  protecting = true

  local focused = vim.api.nvim_get_current_win()
  local moved_win = nil
  local checks = {
    { win = state.history_win, buf = state.history_buf },
    { win = state.prompt_win, buf = state.prompt_buf },
  }

  for _, item in ipairs(checks) do
    if valid_win(item.win) and valid_buf(item.buf) then
      local current_buf = vim.api.nvim_win_get_buf(item.win)
      if current_buf ~= item.buf then
        if valid_buf(current_buf) and not is_pi_buf(current_buf) then
          moved_win = ensure_source_win()
          vim.api.nvim_win_set_buf(moved_win, current_buf)
        end
        vim.api.nvim_win_set_buf(item.win, item.buf)
      end
    end
  end

  if moved_win and valid_win(moved_win) then
    vim.api.nvim_set_current_win(moved_win)
  elseif valid_win(focused) then
    vim.api.nvim_set_current_win(focused)
  end

  protecting = false
end

local function setup_protection()
  if protection_ready then
    return
  end
  protection_ready = true

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("piovim-panel-protection", { clear = true }),
    callback = function()
      vim.schedule(protect_panel_windows)
    end,
  })
end

local function ensure_history_buf()
  if valid_buf(state.history_buf) then
    return state.history_buf
  end

  setup_highlights()
  state.history_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.history_buf].buftype = "nofile"
  vim.bo[state.history_buf].bufhidden = "hide"
  vim.bo[state.history_buf].swapfile = false
  vim.bo[state.history_buf].filetype = "piovim-chat"
  start_markdown_highlighter(state.history_buf)
  vim.api.nvim_buf_set_name(state.history_buf, "piovim://history")
  vim.api.nvim_buf_set_lines(state.history_buf, 0, -1, false, {
    "πovim",
    "Ask with <leader>pq, append context with <leader>pa, or type below.",
    "",
  })
  vim.api.nvim_buf_add_highlight(state.history_buf, ns, "PiovimTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.history_buf, ns, "PiovimMuted", 1, 0, -1)
  vim.bo[state.history_buf].modifiable = false

  return state.history_buf
end

local function ensure_prompt_buf()
  if valid_buf(state.prompt_buf) then
    return state.prompt_buf
  end

  setup_highlights()
  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.prompt_buf].buftype = "nofile"
  vim.bo[state.prompt_buf].bufhidden = "hide"
  vim.bo[state.prompt_buf].swapfile = false
  vim.bo[state.prompt_buf].filetype = "piovim-prompt"
  vim.b[state.prompt_buf].completion = false
  vim.api.nvim_buf_set_name(state.prompt_buf, "piovim://prompt")
  vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "" })

  return state.prompt_buf
end

local function scroll_to_bottom()
  if valid_win(state.history_win) and valid_buf(state.history_buf) then
    local line_count = vim.api.nvim_buf_line_count(state.history_buf)
    pcall(vim.api.nvim_win_set_cursor, state.history_win, { line_count, 0 })
  end
end

local function set_history_win_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
  vim.wo[win].foldenable = false
end

local function hide_completion_menu()
  pcall(function()
    require("blink.cmp").hide()
  end)
end

local function set_prompt_win_options(win)
  hide_completion_menu()
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
  vim.wo[win].winfixheight = true
  local suffix = state.status ~= "" and (" %#PiovimMuted#" .. state.status .. " %*") or ""
  vim.wo[win].winbar = "%#PiovimPrompt# Ask π %*" .. suffix
end

function M.open(opts)
  opts = opts or {}
  setup_protection()
  local history_buf = ensure_history_buf()
  local prompt_buf = ensure_prompt_buf()

  if valid_win(state.history_win) and valid_win(state.prompt_win) then
    return state.history_win
  end

  M.close()

  local current_win = vim.api.nvim_get_current_win()
  local width = opts.width or 80
  vim.cmd("botright " .. width .. "vsplit")
  state.history_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.history_win, history_buf)
  set_history_win_options(state.history_win)

  vim.cmd("belowright 3split")
  state.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.prompt_win, prompt_buf)
  set_prompt_win_options(state.prompt_win)

  if opts.focus_prompt ~= false and valid_win(state.prompt_win) then
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd("startinsert")
  elseif valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  scroll_to_bottom()
  pcall(function()
    require("piovim.review_diff").resize_if_open()
  end)
  return state.history_win
end

function M.close()
  if valid_win(state.prompt_win) then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if valid_win(state.history_win) then
    vim.api.nvim_win_close(state.history_win, true)
  end
  state.prompt_win = nil
  state.history_win = nil
  vim.schedule(function()
    pcall(function()
      require("piovim.review_diff").resize_if_open()
    end)
  end)
end

function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

function M.is_open()
  return valid_win(state.history_win) or valid_win(state.prompt_win)
end

function M.buf()
  return ensure_history_buf()
end

function M.prompt_buf()
  return ensure_prompt_buf()
end

function M.focus_prompt()
  M.open({ focus_prompt = true })
  if valid_win(state.prompt_win) then
    hide_completion_menu()
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd("startinsert")
  end
end

function M.redirect_history_focus()
  if not valid_win(state.history_win) or not valid_win(state.prompt_win) then
    return
  end
  if vim.api.nvim_get_current_win() ~= state.history_win then
    return
  end
  vim.schedule(function()
    if valid_win(state.prompt_win) then
      vim.api.nvim_set_current_win(state.prompt_win)
      vim.cmd("startinsert")
    end
  end)
end

function M.set_status(text)
  state.status = text or ""
  if valid_win(state.prompt_win) then
    set_prompt_win_options(state.prompt_win)
  end
end

function M.set_on_submit(callback)
  state.on_submit = callback
end

function M.set_slash_commands(commands)
  state.slash_commands = commands or {}
end

local function matching_slash_commands(prefix)
  local matches = {}
  for _, command in ipairs(state.slash_commands or {}) do
    if command.name:sub(1, #prefix) == prefix then
      matches[#matches + 1] = command
    end
  end
  return matches
end

function M.update_prompt_hints()
  local buf = ensure_prompt_buf()
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(buf, prompt_hint_ns, 0, -1)

  local text = M.prompt_text()
  if text:sub(1, 1) ~= "/" or text:find("%s") then
    return
  end

  local matches = matching_slash_commands(text)
  if #matches == 0 then
    vim.api.nvim_buf_set_extmark(buf, prompt_hint_ns, 0, 0, {
      virt_lines = { { { "  No Pi slash commands match " .. text, "PiovimPromptHint" } } },
    })
    return
  end

  local hint_lines = {}
  local max_items = math.min(#matches, 5)
  for i = 1, max_items do
    local item = matches[i]
    hint_lines[#hint_lines + 1] = { { "  " .. item.name .. " — " .. (item.description or ""), "PiovimPromptHint" } }
  end
  if #matches > max_items then
    hint_lines[#hint_lines + 1] = { { "  …" .. tostring(#matches - max_items) .. " more", "PiovimPromptHint" } }
  end

  vim.api.nvim_buf_set_extmark(buf, prompt_hint_ns, 0, 0, {
    virt_lines = hint_lines,
  })
end

local function normalize_lines(lines)
  local result = {}
  for _, line in ipairs(lines) do
    local parts = vim.split(tostring(line), "\n", { plain = true })
    for _, part in ipairs(parts) do
      result[#result + 1] = part
    end
  end
  return result
end

function M.append_lines(lines, hl_group)
  local buf = ensure_history_buf()
  local normalized = normalize_lines(lines)
  local start = vim.api.nvim_buf_line_count(buf)
  set_modifiable(buf, true)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, normalized)
  set_modifiable(buf, false)
  if hl_group then
    for i = 0, #normalized - 1 do
      vim.api.nvim_buf_add_highlight(buf, ns, hl_group, start + i, 0, -1)
    end
  end
  highlight_patterns(buf, start, normalized)
  scroll_to_bottom()
  return start, #normalized
end

function M.append_text(text)
  if text == "" then
    return
  end

  local buf = ensure_history_buf()
  set_modifiable(buf, true)

  local line_count = vim.api.nvim_buf_line_count(buf)
  local row = line_count - 1
  local last = vim.api.nvim_buf_get_lines(buf, row, line_count, false)[1] or ""
  local parts = vim.split(text, "\n", { plain = true })
  local replacement

  if #parts == 1 then
    replacement = { last .. parts[1] }
  else
    replacement = { last .. parts[1] }
    for i = 2, #parts do
      replacement[#replacement + 1] = parts[i]
    end
  end

  vim.api.nvim_buf_set_lines(buf, row, line_count, false, replacement)
  set_modifiable(buf, false)
  highlight_patterns(buf, row, replacement)
  scroll_to_bottom()
end

function M.user_message(text, context_summary)
  state.active_assistant = false
  M.append_lines({ "", "● You" }, "PiovimUser")
  M.append_lines({ "  ─────" }, "PiovimDivider")
  if context_summary and context_summary ~= "" then
    M.append_lines({ "  " .. context_summary }, "PiovimMuted")
  end
  M.append_lines({ text, "" })
end

function M.assistant_start()
  if state.active_assistant then
    return
  end
  state.active_assistant = true
  M.append_lines({ "", "π Pi" }, "PiovimAssistant")
  M.append_lines({ "  ────", "" }, "PiovimDivider")
end

function M.assistant_delta(text)
  M.assistant_start()
  M.append_text(text)
end

function M.assistant_end()
  if state.active_assistant then
    M.append_lines({ "" })
  end
  state.active_assistant = false
end

function M.system(text)
  state.active_assistant = false
  M.append_lines({ "", "· " .. text }, "PiovimSystem")
end

function M.cancelled()
  if state.active_assistant then
    M.append_lines({ "" })
  end
  state.active_assistant = false
  M.append_lines({ "", "⏹ cancelled" }, "PiovimCancelled")
end

function M.tool_start(name, args)
  state.active_assistant = false
  local summary = name
  if type(args) == "table" then
    if args.path then
      summary = summary .. " " .. tostring(args.path)
    elseif args.command then
      summary = summary .. " " .. tostring(args.command)
    elseif args.method then
      summary = summary .. " " .. tostring(args.method)
    end
  end
  M.append_lines({ "", "⚙ " .. summary }, "PiovimTool")
end

function M.tool_end(name, is_error)
  local status = is_error and "failed" or "done"
  M.append_lines({ "  ↳ " .. name .. " " .. status }, "PiovimMuted")
end

function M.prompt_text()
  local buf = ensure_prompt_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  return vim.trim(text)
end

function M.clear_prompt()
  local buf = ensure_prompt_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  M.update_prompt_hints()
end

function M.set_prompt_text(text)
  local buf = ensure_prompt_buf()
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.update_prompt_hints()
  if valid_win(state.prompt_win) then
    local last_line = #lines
    local last_col = #(lines[last_line] or "")
    vim.api.nvim_set_current_win(state.prompt_win)
    pcall(vim.api.nvim_win_set_cursor, state.prompt_win, { last_line, last_col })
    vim.cmd("startinsert")
  end
end

function M.append_prompt_text(text)
  local existing = M.prompt_text()
  if existing == "" then
    M.set_prompt_text(text)
  else
    M.set_prompt_text(existing .. " " .. text)
  end
end

function M.complete_slash_command()
  local text = M.prompt_text()
  if text:sub(1, 1) ~= "/" or text:find("%s") then
    return false
  end

  local matches = matching_slash_commands(text)
  if #matches == 0 then
    vim.notify("No matching Pi slash command", vim.log.levels.INFO)
    return true
  end
  if #matches == 1 then
    local name = matches[1].name
    vim.schedule(function()
      M.set_prompt_text(name)
    end)
    return true
  end

  vim.ui.select(matches, {
    prompt = "Pi command",
    format_item = function(item)
      return item.name .. " — " .. (item.description or "")
    end,
  }, function(choice)
    if choice then
      vim.schedule(function()
        M.set_prompt_text(choice.name)
      end)
    end
  end)
  return true
end

function M.submit_prompt()
  local text = M.prompt_text()
  if text == "" then
    return
  end
  M.clear_prompt()
  if state.on_submit then
    state.on_submit(text)
  end
end

function M.clear()
  local buf = ensure_history_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, pattern_ns, 0, -1)
  set_modifiable(buf, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "πovim",
    "Ask with <leader>pq, append context with <leader>pa, or type below.",
    "",
  })
  set_modifiable(buf, false)
  vim.api.nvim_buf_add_highlight(buf, ns, "PiovimTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "PiovimMuted", 1, 0, -1)
  state.active_assistant = false
end

return M
