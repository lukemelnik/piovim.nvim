local M = {}

local highlight_ns = vim.api.nvim_create_namespace("piovim-highlights")
local diff_ns = vim.api.nvim_create_namespace("piovim-edit-preview")
local highlights_ready = false

local function setup_highlights()
  if highlights_ready then
    return
  end
  highlights_ready = true

  local visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
  local cursor_line = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local bg = visual.bg or cursor_line.bg

  if bg then
    vim.api.nvim_set_hl(0, "PiovimRange", { default = true, bg = bg, underline = true, blend = 35 })
  else
    vim.api.nvim_set_hl(0, "PiovimRange", { default = true, underline = true })
  end

  vim.api.nvim_set_hl(0, "PiovimRangeLabel", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "PiovimDiffDelete", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "PiovimDiffAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "PiovimDiffChange", { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "PiovimDiffHeader", { default = true, link = "DiagnosticHint" })
end

local state = {
  server = nil,
  port = nil,
  token = nil,
  last_code_buf = nil,
  last_code_win = nil,
}

local uv = vim.uv or vim.loop

local function is_pi_buffer(buf)
  local ft = vim.bo[buf].filetype
  return ft == "piovim-chat" or ft == "piovim-prompt"
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function remember_current_code_buffer()
  local buf = vim.api.nvim_get_current_buf()
  if not valid_buf(buf) or is_pi_buffer(buf) then
    return
  end

  state.last_code_buf = buf
  state.last_code_win = vim.api.nvim_get_current_win()
end

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function path_for_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and normalize_path(name) or nil
end

local function find_buf_by_path(path)
  local abs = normalize_path(path)
  if not abs then
    return nil
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and path_for_buf(buf) == abs then
      return buf
    end
  end

  return nil
end

local function fallback_buf()
  if valid_buf(state.last_code_buf) and not is_pi_buffer(state.last_code_buf) then
    return state.last_code_buf
  end

  local buf = vim.api.nvim_get_current_buf()
  if valid_buf(buf) and not is_pi_buffer(buf) then
    return buf
  end

  return nil
end

local function resolve_buf(params)
  params = params or {}

  if type(params.bufnr) == "number" and valid_buf(params.bufnr) then
    return params.bufnr
  end

  if type(params.path) == "string" and params.path ~= "" then
    local by_path = find_buf_by_path(params.path)
    if by_path then
      return by_path
    end
    return nil
  end

  return fallback_buf()
end

local function buffer_summary(buf)
  local diagnostics = vim.diagnostic.get(buf)
  return {
    bufnr = buf,
    path = vim.api.nvim_buf_get_name(buf),
    filetype = vim.bo[buf].filetype,
    modified = vim.bo[buf].modified,
    changedtick = vim.b[buf].changedtick,
    line_count = vim.api.nvim_buf_line_count(buf),
    diagnostics = #diagnostics,
  }
end

local function truncate_text(text, max_bytes)
  max_bytes = max_bytes or 50000
  if #text <= max_bytes then
    return text, false
  end
  return text:sub(1, max_bytes) .. "\n[truncated at " .. max_bytes .. " bytes]", true
end

local function lines_to_text(lines)
  return table.concat(lines, "\n")
end

local function text_to_lines(text)
  return vim.split(text, "\n", { plain = true })
end

local function read_buffer(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = math.max(1, tonumber(params.start_line) or 1)
  local end_line = math.min(line_count, tonumber(params.end_line) or line_count)

  if end_line < start_line then
    error("end_line must be >= start_line")
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local text, truncated = truncate_text(lines_to_text(lines), tonumber(params.max_bytes) or 50000)

  return {
    buffer = buffer_summary(buf),
    start_line = start_line,
    end_line = end_line,
    text = text,
    truncated = truncated,
  }
end

local function byte_to_position(text, byte_index)
  local before = text:sub(1, byte_index - 1)
  local lines = vim.split(before, "\n", { plain = true })
  return #lines - 1, #(lines[#lines] or "")
end

local function make_virt_line(prefix, line, hl_group)
  return { { prefix .. line, hl_group } }
end

local function confirm_edit_preview(anchor)
  local prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt_buf].buftype = "nofile"
  vim.bo[prompt_buf].bufhidden = "wipe"
  vim.bo[prompt_buf].swapfile = false
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, {
    "Apply Pi edit preview?",
    "a / y / enter  apply",
    "q / n / esc / ctrl-c  cancel",
  })
  vim.bo[prompt_buf].modifiable = false

  local width = 38
  local height = 3
  local win_opts
  if anchor and valid_win(anchor.win) then
    local row = math.min(anchor.row + 1, math.max(0, vim.api.nvim_win_get_height(anchor.win) - height - 1))
    win_opts = {
      relative = "win",
      win = anchor.win,
      row = row,
      col = 0,
      width = math.min(width, vim.api.nvim_win_get_width(anchor.win) - 2),
      height = height,
      border = "rounded",
      title = " Pi edit ",
      style = "minimal",
    }
  else
    win_opts = {
      relative = "editor",
      row = math.max(1, vim.o.lines - height - 4),
      col = math.max(1, vim.o.columns - width - 4),
      width = width,
      height = height,
      border = "rounded",
      title = " Pi edit ",
      style = "minimal",
    }
  end
  local prompt_win = vim.api.nvim_open_win(prompt_buf, false, win_opts)
  vim.api.nvim_buf_add_highlight(prompt_buf, diff_ns, "Question", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(prompt_buf, diff_ns, "MoreMsg", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(prompt_buf, diff_ns, "WarningMsg", 2, 0, -1)
  vim.cmd("redraw")

  local function close_prompt()
    if valid_win(prompt_win) then
      vim.api.nvim_win_close(prompt_win, true)
    elseif valid_buf(prompt_buf) then
      vim.api.nvim_buf_delete(prompt_buf, { force = true })
    end
  end

  while true do
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok then
      close_prompt()
      return false
    end
    key = key:lower()
    if key == "a" or key == "y" or key == "\r" or key == "\n" then
      close_prompt()
      return true
    end
    if key == "q" or key == "n" or key == "\027" or key == "\003" then
      close_prompt()
      return false
    end
  end
end

local function preview_edits(buf, previews)
  if #vim.api.nvim_list_uis() == 0 then
    return true
  end

  setup_highlights()
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  local current_win = vim.api.nvim_get_current_win()
  local preview_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      preview_win = win
      break
    end
  end
  if preview_win then
    vim.api.nvim_set_current_win(preview_win)
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, preview in ipairs(previews) do
    local virt_lines = {
      { { "╭─ π edit preview L" .. (preview.start_row + 1) .. "-" .. (preview.end_row + 1), "PiovimDiffHeader" } },
    }
    for _, line in ipairs(text_to_lines(preview.edit.oldText)) do
      virt_lines[#virt_lines + 1] = make_virt_line("- ", line, "PiovimDiffDelete")
    end
    for _, line in ipairs(text_to_lines(preview.edit.newText)) do
      virt_lines[#virt_lines + 1] = make_virt_line("+ ", line, "PiovimDiffAdd")
    end
    virt_lines[#virt_lines + 1] = { { "╰─ Apply? confirm below", "PiovimDiffHeader" } }

    vim.api.nvim_buf_set_extmark(buf, diff_ns, preview.start_row, preview.start_col, {
      end_row = preview.end_row,
      end_col = preview.end_col,
      hl_group = "PiovimDiffChange",
      hl_eol = true,
      priority = 250,
    })

    local anchor_row = math.min(math.max(preview.start_row, preview.end_row - 1), line_count - 1)
    vim.api.nvim_buf_set_extmark(buf, diff_ns, anchor_row, 0, {
      priority = 251,
      virt_lines = virt_lines,
      virt_lines_leftcol = true,
    })
  end

  if previews[1] then
    local line = math.max(1, previews[1].start_row + 1)
    pcall(vim.api.nvim_win_set_cursor, 0, { line, previews[1].start_col })
    vim.cmd("normal! zv")
  end

  local anchor = nil
  if preview_win and previews[1] then
    local diff_lines = 2 + #text_to_lines(previews[1].edit.oldText) + #text_to_lines(previews[1].edit.newText)
    local screen_row = vim.fn.screenpos(preview_win, previews[1].end_row + 1, 1).row
    if screen_row > 0 then
      anchor = { win = preview_win, row = screen_row - vim.fn.win_screenpos(preview_win)[1] + diff_lines }
    end
  end
  local choice = confirm_edit_preview(anchor)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
  if valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return choice
end

local function position_before(a_row, a_col, b_row, b_col)
  return a_row < b_row or (a_row == b_row and a_col < b_col)
end

local function ranges_overlap(a, b)
  return position_before(a.start_row, a.start_col, b.end_row, b.end_col)
    and position_before(b.start_row, b.start_col, a.end_row, a.end_col)
end

local function validate_range(buf, edit)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_row = tonumber(edit.startLine or edit.start_line)
  local start_col = tonumber(edit.startCol or edit.start_col)
  local end_row = tonumber(edit.endLine or edit.end_line)
  local end_col = tonumber(edit.endCol or edit.end_col)

  if not start_row or not start_col or not end_row or not end_col then
    error("Each rangeEdit needs startLine, startCol, endLine, endCol, and newText")
  end

  start_row = start_row - 1
  end_row = end_row - 1
  if start_row < 0 or end_row < 0 or start_row >= line_count or end_row >= line_count then
    error("rangeEdit line is outside the live Neovim buffer")
  end
  if position_before(end_row, end_col, start_row, start_col) then
    error("rangeEdit end must be after start")
  end

  local start_line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ""
  local end_line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
  if start_col < 0 or start_col > #start_line or end_col < 0 or end_col > #end_line then
    error("rangeEdit column is outside the live Neovim buffer")
  end

  return start_row, start_col, end_row, end_col
end

local function edit_buffer(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end

  local expected = params.expected_changedtick
  if expected ~= nil and tonumber(expected) ~= vim.b[buf].changedtick then
    error("Buffer changedtick mismatch; re-read the buffer before editing")
  end

  local edits = type(params.edits) == "table" and params.edits or {}
  local range_edits = type(params.rangeEdits or params.range_edits) == "table" and (params.rangeEdits or params.range_edits) or {}
  if #edits == 0 and #range_edits == 0 then
    error("Provide edits or rangeEdits")
  end

  local previews = {}
  local full_text = lines_to_text(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  for index, edit in ipairs(edits) do
    if type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
      error("Each edit needs oldText and newText strings")
    end
    if edit.oldText == "" then
      error("oldText cannot be empty. Use rangeEdits for insertion or empty-buffer edits.")
    end

    local first_start, first_end = full_text:find(edit.oldText, 1, true)
    if not first_start then
      error("oldText not found in live Neovim buffer")
    end
    local second_start = full_text:find(edit.oldText, first_end + 1, true)
    if second_start then
      error("oldText matches multiple regions in live Neovim buffer")
    end

    local start_row, start_col = byte_to_position(full_text, first_start)
    local end_row, end_col = byte_to_position(full_text, first_end + 1)
    previews[#previews + 1] = {
      index = index,
      edit = edit,
      start_row = start_row,
      start_col = start_col,
      end_row = end_row,
      end_col = end_col,
    }
  end

  for index, edit in ipairs(range_edits) do
    if type(edit.newText) ~= "string" then
      error("Each rangeEdit needs newText")
    end
    local start_row, start_col, end_row, end_col = validate_range(buf, edit)
    local old_text = lines_to_text(vim.api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {}))
    previews[#previews + 1] = {
      index = #edits + index,
      edit = {
        oldText = old_text,
        newText = edit.newText,
      },
      start_row = start_row,
      start_col = start_col,
      end_row = end_row,
      end_col = end_col,
    }
  end

  for i = 1, #previews do
    for j = i + 1, #previews do
      if ranges_overlap(previews[i], previews[j]) then
        error("edits must not overlap")
      end
    end
  end

  table.sort(previews, function(a, b)
    return position_before(a.start_row, a.start_col, b.start_row, b.start_col)
  end)

  if not preview_edits(buf, previews) then
    error("Neovim edit cancelled")
  end

  local applied = {}
  for i = #previews, 1, -1 do
    local preview = previews[i]
    vim.api.nvim_buf_set_text(
      buf,
      preview.start_row,
      preview.start_col,
      preview.end_row,
      preview.end_col,
      text_to_lines(preview.edit.newText)
    )

    applied[#applied + 1] = {
      start_line = preview.start_row + 1,
      end_line = preview.end_row + 1,
    }
  end

  table.sort(applied, function(a, b)
    return a.start_line < b.start_line
  end)

  return {
    buffer = buffer_summary(buf),
    applied = applied,
    saved = false,
  }
end

local function ensure_changedtick(buf, expected)
  if expected ~= nil and tonumber(expected) ~= vim.b[buf].changedtick then
    error("Buffer changedtick mismatch; re-read the buffer before continuing")
  end
end

local function is_file_backed(buf)
  return vim.api.nvim_buf_get_name(buf) ~= "" and vim.bo[buf].buftype == ""
end

local function save_buffer(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end
  if is_pi_buffer(buf) then
    error("Refusing to save Pi plugin buffer")
  end
  if not is_file_backed(buf) then
    error("Buffer is not file-backed and cannot be saved with nvim_save_buffer")
  end

  ensure_changedtick(buf, params.expected_changedtick)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)

  return {
    buffer = buffer_summary(buf),
    saved = true,
  }
end

local function close_buffer(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end
  if is_pi_buffer(buf) then
    error("Refusing to close Pi plugin buffer")
  end
  if vim.bo[buf].modified then
    error("Buffer has unsaved changes. Ask the user whether to save, cancel, or discard before closing.")
  end

  ensure_changedtick(buf, params.expected_changedtick)
  local summary = buffer_summary(buf)
  vim.cmd("bdelete " .. tostring(buf))

  return {
    buffer = summary,
    closed = true,
  }
end

local function diagnostics(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end

  local max_items = tonumber(params.max_items) or 100
  local items = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(buf)) do
    if #items >= max_items then
      break
    end
    items[#items + 1] = {
      line = diagnostic.lnum + 1,
      col = diagnostic.col,
      end_line = diagnostic.end_lnum and diagnostic.end_lnum + 1 or nil,
      end_col = diagnostic.end_col,
      severity = diagnostic.severity,
      source = diagnostic.source,
      code = diagnostic.code,
      message = diagnostic.message,
    }
  end

  return {
    buffer = buffer_summary(buf),
    diagnostics = items,
    truncated = #vim.diagnostic.get(buf) > #items,
  }
end

local function target_code_win()
  if valid_win(state.last_code_win) then
    local buf = vim.api.nvim_win_get_buf(state.last_code_win)
    if valid_buf(buf) and not is_pi_buffer(buf) then
      return state.last_code_win
    end
  end

  local current_win = vim.api.nvim_get_current_win()
  if valid_win(current_win) then
    local buf = vim.api.nvim_win_get_buf(current_win)
    if valid_buf(buf) and not is_pi_buffer(buf) then
      return current_win
    end
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if valid_buf(buf) and not is_pi_buffer(buf) then
      return win
    end
  end

  return nil
end

local function open_buffer(params)
  local path = normalize_path(params.path)
  if not path then
    error("path is required")
  end

  local focus = params.focus ~= false
  local current_win = vim.api.nvim_get_current_win()
  local target_win = target_code_win()

  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end

  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local line = math.max(1, tonumber(params.line) or 1)
  local col = math.max(0, tonumber(params.col) or 0)
  line = math.min(line, vim.api.nvim_buf_line_count(buf))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, col })
  vim.cmd("normal! zv")

  state.last_code_buf = buf
  state.last_code_win = vim.api.nvim_get_current_win()

  if not focus and valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end

  return {
    buffer = buffer_summary(buf),
    focused = focus,
    line = line,
    col = col,
  }
end

local function clear_highlights()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
    end
  end
  return { cleared = true }
end

local function highlight_range(params)
  setup_highlights()
  if params.append ~= true then
    clear_highlights()
  end

  local open_result = open_buffer({
    path = params.path,
    line = params.start_line,
    col = params.start_col,
    focus = params.focus,
  })
  local buf = vim.api.nvim_get_current_buf()
  if open_result.buffer and type(open_result.buffer.bufnr) == "number" then
    buf = open_result.buffer.bufnr
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = math.max(1, math.min(line_count, tonumber(params.start_line) or 1))
  local end_line = math.max(start_line, math.min(line_count, tonumber(params.end_line) or start_line))
  local start_col = math.max(0, tonumber(params.start_col) or 0)
  local end_col = params.end_col ~= nil and math.max(0, tonumber(params.end_col) or 0) or -1
  local label = type(params.label) == "string" and params.label or nil

  for line = start_line, end_line do
    local row = line - 1
    local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local from_col = line == start_line and start_col or 0
    local to_col = line == end_line and end_col or -1
    if to_col == -1 then
      to_col = #line_text
    end
    if to_col <= from_col then
      to_col = #line_text
    end

    vim.api.nvim_buf_set_extmark(buf, highlight_ns, row, from_col, {
      end_col = to_col,
      hl_group = "PiovimRange",
      priority = 200,
    })
  end

  if label then
    vim.api.nvim_buf_set_extmark(buf, highlight_ns, start_line - 1, 0, {
      virt_text = { { "  ← π " .. label, "PiovimRangeLabel" } },
      virt_text_pos = "eol",
      priority = 201,
    })
  end

  return {
    buffer = buffer_summary(buf),
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
    label = label,
    focused = params.focus ~= false,
  }
end

local handlers = {}

function handlers.get_context()
  local buf = fallback_buf()
  if not buf then
    return { current_buffer = nil, open_buffers = {} }
  end

  local cursor = nil
  if valid_win(state.last_code_win) and vim.api.nvim_win_get_buf(state.last_code_win) == buf then
    cursor = vim.api.nvim_win_get_cursor(state.last_code_win)
  end

  return {
    current_buffer = buffer_summary(buf),
    cursor = cursor and { line = cursor[1], col = cursor[2] } or nil,
  }
end

function handlers.list_open_buffers()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and not is_pi_buffer(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" then
        buffers[#buffers + 1] = buffer_summary(buf)
      end
    end
  end
  return { buffers = buffers }
end

function handlers.read_buffer(params)
  return read_buffer(params or {})
end

function handlers.get_diagnostics(params)
  return diagnostics(params or {})
end

function handlers.open_buffer(params)
  return open_buffer(params or {})
end

function handlers.highlight_range(params)
  return highlight_range(params or {})
end

function handlers.clear_highlights()
  return clear_highlights()
end

function handlers.edit_buffer(params)
  return edit_buffer(params or {})
end

function handlers.save_buffer(params)
  return save_buffer(params or {})
end

function handlers.close_buffer(params)
  return close_buffer(params or {})
end

local function handle_request(req)
  if req.token ~= state.token then
    error("Invalid Neovim bridge token")
  end

  local handler = handlers[req.method]
  if not handler then
    error("Unknown Neovim bridge method: " .. tostring(req.method))
  end

  return handler(req.params or {})
end

local function respond(client, payload)
  if not client or client:is_closing() then
    return
  end
  client:write(vim.json.encode(payload) .. "\n", function()
    if client and not client:is_closing() then
      client:shutdown(function()
        if client and not client:is_closing() then
          client:close()
        end
      end)
    end
  end)
end

function M.start()
  if state.server then
    return state.port, state.token
  end

  state.token = tostring(math.random()) .. tostring(vim.loop.hrtime())
  state.server = uv.new_tcp()
  assert(state.server:bind("127.0.0.1", 0))
  state.port = state.server:getsockname().port

  state.server:listen(64, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Pi Neovim bridge error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    state.server:accept(client)
    local pending = ""

    client:read_start(function(read_err, chunk)
      if read_err then
        respond(client, { ok = false, error = read_err })
        return
      end
      if not chunk then
        return
      end

      pending = pending .. chunk
      local newline = pending:find("\n", 1, true)
      if not newline then
        return
      end

      local line = pending:sub(1, newline - 1)
      client:read_stop()

      vim.schedule(function()
        local ok, req = pcall(vim.json.decode, line)
        if not ok then
          respond(client, { ok = false, error = "Invalid JSON request" })
          return
        end

        local success, result = pcall(handle_request, req)
        if success then
          respond(client, { ok = true, result = result })
        else
          respond(client, { ok = false, error = tostring(result) })
        end
      end)
    end)
  end)

  return state.port, state.token
end

function M.stop()
  if state.server and not state.server:is_closing() then
    state.server:close()
  end
  state.server = nil
  state.port = nil
  state.token = nil
end

function M.clear_highlights()
  clear_highlights()
end

function M.setup_autocmds()
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("piovim-bridge", { clear = true }),
    callback = remember_current_code_buffer,
  })
end

function M.last_code_buf()
  return fallback_buf()
end

return M
