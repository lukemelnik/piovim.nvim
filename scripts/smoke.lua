local function assert_true(value, message)
  if not value then
    error(message or "assertion failed", 2)
  end
end

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

panel.close()
vim.cmd("bdelete!")
vim.fn.delete(tmp)
