local EditPreview = require("piovim.edit_preview")

local M = {}

local state = {
  last_code_buf = nil,
  last_code_win = nil,
}

local highlight_ns = vim.api.nvim_create_namespace("piovim-highlights")
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
end

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

function M.fallback_buf()
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
    return find_buf_by_path(params.path)
  end

  return M.fallback_buf()
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

local function byte_to_position(text, byte_index)
  local before = text:sub(1, byte_index - 1)
  local lines = vim.split(before, "\n", { plain = true })
  return #lines - 1, #(lines[#lines] or "")
end

local function position_before(a_row, a_col, b_row, b_col)
  return a_row < b_row or (a_row == b_row and a_col < b_col)
end

local function ranges_overlap(a, b)
  return position_before(a.start_row, a.start_col, b.end_row, b.end_col)
    and position_before(b.start_row, b.start_col, a.end_row, a.end_col)
end

local function ensure_changedtick(buf, expected, message)
  if expected ~= nil and tonumber(expected) ~= vim.b[buf].changedtick then
    error(message or "Buffer changedtick mismatch; re-read the buffer before continuing")
  end
end

local function is_file_backed(buf)
  return vim.api.nvim_buf_get_name(buf) ~= "" and vim.bo[buf].buftype == ""
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

function M.remember_current_code_buffer()
  local buf = vim.api.nvim_get_current_buf()
  if not valid_buf(buf) or is_pi_buffer(buf) then
    return
  end

  state.last_code_buf = buf
  state.last_code_win = vim.api.nvim_get_current_win()
end

function M.get_context()
  local buf = M.fallback_buf()
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

function M.list_open_buffers()
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

function M.read_buffer(params)
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

function M.edit_buffer(params)
  local buf = resolve_buf(params)
  if not buf then
    error("No matching open Neovim buffer")
  end

  ensure_changedtick(buf, params.expected_changedtick, "Buffer changedtick mismatch; re-read the buffer before editing")

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
    if full_text:find(edit.oldText, first_end + 1, true) then
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

  if not EditPreview.show(buf, previews) then
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

  local path = path_for_buf(buf)
  if path then
    pcall(function()
      require("piovim.review_diff").refresh_if_open(path)
    end)
  end

  return {
    buffer = buffer_summary(buf),
    applied = applied,
    saved = false,
  }
end

function M.get_diagnostics(params)
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

function M.open_buffer(params)
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

function M.clear_highlights()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
    end
  end
  return { cleared = true }
end

function M.highlight_range(params)
  setup_highlights()
  if params.append ~= true then
    M.clear_highlights()
  end

  local open_result = M.open_buffer({
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

function M.save_buffer(params)
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

function M.close_buffer(params)
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

return M
