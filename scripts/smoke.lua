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

local panel = require("piovim.panel")
panel.open({ focus_prompt = false })
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

panel.close()
vim.cmd("%bdelete!")
vim.fn.delete(tmp)
vim.fn.delete(empty)
