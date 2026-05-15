local Bridge = require("piovim.bridge")

local M = {}

local config = {
  snippet_context_lines = 40,
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function current_code_buf()
  local buf = Bridge.last_code_buf()
  if valid_buf(buf) then
    return buf
  end
  return vim.api.nvim_get_current_buf()
end

function M.get_visual_selection()
  local mode = vim.fn.mode()
  if not mode:match("[vV\22]") then
    return nil
  end

  vim.cmd("normal! \27")

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row = start_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_row = end_pos[2] - 1
  local end_col = end_pos[3]

  if start_row < 0 or end_row < 0 then
    return nil
  end

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  if mode == "V" then
    start_col = 0
    end_col = #(vim.api.nvim_buf_get_lines(0, end_row, end_row + 1, false)[1] or "")
  end

  local lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col, {})
  return {
    bufnr = vim.api.nvim_get_current_buf(),
    text = table.concat(lines, "\n"),
    start_line = start_row + 1,
    end_line = end_row + 1,
  }
end

local function rel_path(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(path, ":.")
end

local function code_fence(filetype, text)
  return "```" .. (filetype or "") .. "\n" .. text .. "\n```"
end

local function line_range_label(start_line, end_line)
  if start_line == end_line then
    return "L" .. start_line
  end
  return "L" .. start_line .. "-" .. end_line
end

local function current_cursor_line(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == buf then
    return vim.api.nvim_win_get_cursor(win)[1]
  end
  return 1
end

local function is_real_file_buffer(buf)
  return vim.api.nvim_buf_get_name(buf) ~= "" and vim.bo[buf].buftype == ""
end

function M.build_prompt_context(selection)
  if selection and selection.text ~= "" then
    local buf = selection.bufnr
    local filetype = vim.bo[buf].filetype
    return table.concat({
      "Live Neovim selection from " .. rel_path(buf) .. "#" .. line_range_label(selection.start_line, selection.end_line) .. ":",
      code_fence(filetype, selection.text),
      "This content came from the unsaved Neovim buffer and may differ from disk.",
      "If you need more context from this open buffer, use the nvim_read_buffer tool.",
    }, "\n"), "selection " .. rel_path(buf) .. "#" .. line_range_label(selection.start_line, selection.end_line)
  end

  local buf = current_code_buf()
  local filetype = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or "text"
  local cursor_line = current_cursor_line(buf)

  if not is_real_file_buffer(buf) then
    return table.concat({
      "The current Neovim buffer is not a file-backed code buffer.",
      "Buffer name: " .. rel_path(buf),
      "Filetype: " .. filetype,
      "Do not infer code context from dashboards or non-file buffers unless the user explicitly asks about them.",
    }, "\n"), nil
  end

  return table.concat({
    "Current Neovim buffer metadata:",
    "- path: " .. rel_path(buf),
    "- filetype: " .. filetype,
    "- cursor_line: " .. cursor_line,
    "- modified: " .. tostring(vim.bo[buf].modified),
    "- changedtick: " .. tostring(vim.b[buf].changedtick),
    "No full buffer text is inlined. If code context is needed, call nvim_read_buffer for this open buffer so you see live unsaved Neovim content.",
  }, "\n"), "current buffer " .. rel_path(buf) .. ":" .. cursor_line
end

function M.mention(selection)
  if selection and selection.text ~= "" then
    return "@selection " .. rel_path(selection.bufnr) .. "#" .. line_range_label(selection.start_line, selection.end_line)
  end

  local buf = vim.api.nvim_get_current_buf()
  if not is_real_file_buffer(buf) then
    return nil
  end
  return "@buffer " .. rel_path(buf) .. ":" .. current_cursor_line(buf)
end

function M.should_confirm_no_file_context(selection)
  if selection and selection.text ~= "" then
    return false
  end
  return not is_real_file_buffer(vim.api.nvim_get_current_buf())
end

return M
