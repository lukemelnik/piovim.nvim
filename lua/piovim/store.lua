local M = {}

local path = vim.fn.stdpath("state") .. "/piovim/config.json"
local data = nil

local function ensure_loaded()
  if data then
    return data
  end

  data = {}
  local fd = io.open(path, "r")
  if not fd then
    return data
  end

  local content = fd:read("*a")
  fd:close()
  if content == "" then
    return data
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    data = decoded
  end
  return data
end

local function encode_pretty(value, indent)
  indent = indent or ""
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end

  local keys = vim.tbl_keys(value)
  table.sort(keys)
  local next_indent = indent .. "  "
  local lines = { "{" }
  for index, key in ipairs(keys) do
    local comma = index < #keys and "," or ""
    lines[#lines + 1] = next_indent .. vim.json.encode(key) .. ": " .. encode_pretty(value[key], next_indent) .. comma
  end
  lines[#lines + 1] = indent .. "}"
  return table.concat(lines, "\n")
end

local function save()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(encode_pretty(ensure_loaded()) .. "\n")
  fd:close()
end

function M.get()
  return vim.deepcopy(ensure_loaded())
end

function M.update(values)
  local current = ensure_loaded()
  for key, value in pairs(values) do
    current[key] = value
  end
  save()
end

function M.path()
  return path
end

return M
