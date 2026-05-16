local BufferOps = require("piovim.buffer_ops")
local ReviewDiff = require("piovim.review_diff")

local M = {}

local uv = vim.uv or vim.loop

local state = {
  server = nil,
  port = nil,
  token = nil,
}

local max_request_bytes = 1024 * 1024

local handlers = {
  get_context = BufferOps.get_context,
  list_open_buffers = BufferOps.list_open_buffers,
  read_buffer = BufferOps.read_buffer,
  get_diagnostics = BufferOps.get_diagnostics,
  open_buffer = BufferOps.open_buffer,
  highlight_range = BufferOps.highlight_range,
  clear_highlights = BufferOps.clear_highlights,
  edit_buffer = BufferOps.edit_buffer,
  save_buffer = BufferOps.save_buffer,
  close_buffer = BufferOps.close_buffer,
  get_review_diff = ReviewDiff.get_context,
  add_review_annotation = ReviewDiff.add_annotation,
  resolve_review_annotation = ReviewDiff.resolve_annotation,
  refresh_review_diff = ReviewDiff.refresh,
}

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

local function handle_client(client)
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
    if #pending > max_request_bytes then
      client:read_stop()
      respond(client, { ok = false, error = "Neovim bridge request too large" })
      return
    end

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
end

function M.start()
  if state.server then
    return state.port, state.token
  end

  state.token = tostring(math.random()) .. tostring(uv.hrtime())
  state.server = uv.new_tcp()
  assert(state.server:bind("127.0.0.1", 0))
  state.port = state.server:getsockname().port

  state.server:listen(64, function(err)
    if err then
      vim.schedule(function()
        vim.notify("Piovim bridge error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    state.server:accept(client)
    handle_client(client)
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
  BufferOps.clear_highlights()
end

function M.setup_autocmds()
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("piovim-bridge", { clear = true }),
    callback = BufferOps.remember_current_code_buffer,
  })
end

function M.last_code_buf()
  return BufferOps.fallback_buf()
end

return M
