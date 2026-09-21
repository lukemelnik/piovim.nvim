local function assert_true(value, message)
  if not value then
    error(message or "assertion failed", 2)
  end
end

vim.g.piovim_auto_accept_edits = true

local piovim = require("piovim")
piovim.setup({ keys = {}, dev = { self_fix = true } })

assert_true(vim.fn.exists(":Piovim") == 2, ":Piovim command missing")
assert_true(vim.fn.exists(":PiovimSelfFix") == 2, ":PiovimSelfFix command missing")
assert_true(vim.fn.exists(":PiovimAppendContext") == 2, ":PiovimAppendContext command missing")
assert_true(vim.fn.exists(":PiovimRefreshCommands") == 2, ":PiovimRefreshCommands command missing")
assert_true(vim.fn.exists(":PiovimToggleEditAutoAccept") == 2, ":PiovimToggleEditAutoAccept command missing")
local panel = require("piovim.panel")
panel.open({ focus_prompt = false })
local function widget_buffers()
  local buffers = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "piovim-widget" then
      buffers[#buffers + 1] = buf
    end
  end
  return buffers
end

local prompt_win = vim.fn.win_findbuf(panel.prompt_buf())[1]
assert_true(prompt_win ~= nil, "prompt window missing")
assert_true(vim.api.nvim_win_get_height(prompt_win) == 3, "prompt window should start at fixed height")
panel.set_extension_widget("example-widget", { "Example Widget", "────────────────", "first item" })
assert_true(vim.api.nvim_win_get_height(prompt_win) == 3, "widget must not resize prompt window")
local widget_bufs = widget_buffers()
assert_true(#widget_bufs == 1, "widget window was not shown")
local widget_lines = vim.api.nvim_buf_get_lines(widget_bufs[1], 0, -1, false)
assert_true(widget_lines[1] == "Example Widget", "widget injected an extension key header")
panel.set_extension_widget("example-widget", nil)
assert_true(#widget_buffers() == 0, "cleared widget did not close widget window")
assert_true(vim.api.nvim_win_get_height(prompt_win) == 3, "cleared widget changed prompt window height")
panel.set_prompt_text("/thi")
assert_true(panel.complete_slash_command(), "slash completion was not handled")
assert_true(vim.wait(1000, function()
  return panel.prompt_text() == "/thinking"
end, 10), "slash completion did not update prompt text")
panel.set_prompt_text("hello")
assert_true(panel.prompt_text() == "hello", "prompt text was not set")
panel.append_prompt_text("world")
assert_true(panel.prompt_text() == "hello world", "prompt text was not appended")
panel.clear_prompt()
assert_true(panel.prompt_text() == "", "prompt text was not cleared")

local self_fix = require("piovim.self_fix")
local self_fix_context = self_fix.prompt_context()
assert_true(self_fix_context:find("Fix piovim.nvim itself", 1, true) ~= nil, "self-fix context missing title")
assert_true(self_fix_context:find("luac %-p lua/piovim/%*.lua") ~= nil, "self-fix context missing luac check")

local context = require("piovim.context")
local tmp = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local value = 1" }, tmp)
vim.cmd.edit(vim.fn.fnameescape(tmp))
local mention = context.mention(nil)
assert_true(mention:find("@buffer", 1, true) ~= nil, "buffer mention missing")
assert_true(mention:find(":1", 1, true) ~= nil, "buffer mention missing cursor line")

local buffer_ops = require("piovim.buffer_ops")
local empty = vim.fn.tempname() .. ".ts"
vim.fn.writefile({}, empty)
vim.cmd.edit(vim.fn.fnameescape(empty))
local read = buffer_ops.read_buffer({})
buffer_ops.edit_buffer({
  expected_changedtick = read.buffer.changedtick,
  rangeEdits = {
    {
      startLine = 1,
      startCol = 0,
      endLine = 1,
      endCol = 0,
      newText = "const value = 1;\n",
    },
  },
})
local edited_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert_true(edited_lines[1] == "const value = 1;", "range edit did not update empty buffer")

local plugin_buf = vim.api.nvim_create_buf(false, true)
vim.bo[plugin_buf].filetype = "piovim-test"
vim.api.nvim_buf_set_name(plugin_buf, "piovim://fake")
vim.api.nvim_buf_set_lines(plugin_buf, 0, -1, false, { "local fake = true" })
local ok, err = pcall(buffer_ops.edit_buffer, {
  bufnr = plugin_buf,
  rangeEdits = {
    { startLine = 1, startCol = 0, endLine = 1, endCol = 0, newText = "local fake = false" },
  },
})
assert_true(not ok and tostring(err):find("Piovim plugin buffer", 1, true), "plugin buffer edit was not rejected")

panel.close()
vim.cmd("%bdelete!")
vim.fn.delete(tmp)
vim.fn.delete(empty)
