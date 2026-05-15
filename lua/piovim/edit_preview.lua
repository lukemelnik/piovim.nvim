local M = {}

local ns = vim.api.nvim_create_namespace("piovim-edit-preview")
local highlights_ready = false

local function setup_highlights()
  if highlights_ready then
    return
  end
  highlights_ready = true
  vim.api.nvim_set_hl(0, "PiovimDiffDelete", { default = true, link = "DiffDelete" })
  vim.api.nvim_set_hl(0, "PiovimDiffAdd", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "PiovimDiffChange", { default = true, link = "DiffChange" })
  vim.api.nvim_set_hl(0, "PiovimDiffHeader", { default = true, link = "DiagnosticHint" })
end

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function text_to_lines(text)
  return vim.split(text, "\n", { plain = true })
end

local function make_virt_line(prefix, line, hl_group)
  return { { prefix .. line, hl_group } }
end

local function confirm(anchor)
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
  vim.api.nvim_buf_add_highlight(prompt_buf, ns, "Question", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(prompt_buf, ns, "MoreMsg", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(prompt_buf, ns, "WarningMsg", 2, 0, -1)
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

function M.show(buf, previews)
  if #vim.api.nvim_list_uis() == 0 then
    return true
  end

  setup_highlights()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

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

    vim.api.nvim_buf_set_extmark(buf, ns, preview.start_row, preview.start_col, {
      end_row = preview.end_row,
      end_col = preview.end_col,
      hl_group = "PiovimDiffChange",
      hl_eol = true,
      priority = 250,
    })

    local anchor_row = math.min(math.max(preview.start_row, preview.end_row - 1), line_count - 1)
    vim.api.nvim_buf_set_extmark(buf, ns, anchor_row, 0, {
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

  local choice = confirm(anchor)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return choice
end

return M
