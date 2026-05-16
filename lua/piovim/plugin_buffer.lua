local M = {}

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.is_plugin_buffer(buf)
  if not valid_buf(buf) then
    return false
  end

  local ft = vim.bo[buf].filetype or ""
  if ft:match("^piovim%-") then
    return true
  end

  local name = vim.api.nvim_buf_get_name(buf) or ""
  if name:match("^piovim://") or name:match("^Pi Review") then
    return true
  end

  return false
end

function M.is_file_backed_code_buffer(buf)
  return valid_buf(buf)
    and not M.is_plugin_buffer(buf)
    and vim.api.nvim_buf_get_name(buf) ~= ""
    and vim.bo[buf].buftype == ""
end

return M
