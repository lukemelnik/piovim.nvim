local ReviewDiff = require("piovim.review_diff")
local T = ReviewDiff._test

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual), 2)
  end
end

local function assert_true(value, message)
  if not value then
    error(message or "assertion failed", 2)
  end
end

local function test_normal_diff()
  local files = T.parse_diff(table.concat({
    "diff --git a/foo.txt b/foo.txt",
    "index 1111111..2222222 100644",
    "--- a/foo.txt",
    "+++ b/foo.txt",
    "@@ -1,2 +1,2 @@",
    " hello",
    "-old",
    "+new",
  }, "\n"))
  assert_eq(#files, 1, "normal diff file count")
  assert_eq(files[1].path, "foo.txt", "normal diff path")
  assert_eq(files[1].old_path, "foo.txt", "normal diff old path")
  assert_eq(#files[1].hunks, 1, "normal diff hunk count")
  assert_eq(files[1].patch_old_lines[2], "old", "normal diff old lines")
  assert_eq(files[1].patch_new_lines[2], "new", "normal diff new lines")
  assert_eq(T.file_status(files[1]), "M", "normal diff status")
end

local function test_plain_unified_patch()
  local files = T.parse_diff(table.concat({
    "--- a/a.txt",
    "+++ b/a.txt",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n"))
  assert_eq(#files, 1, "plain patch file count")
  assert_eq(files[1].path, "a.txt", "plain patch path")
  assert_eq(files[1].old_path, "a.txt", "plain patch old path")
  assert_eq(files[1].patch_old_lines[1], "old", "plain patch old line")
  assert_eq(files[1].patch_new_lines[1], "new", "plain patch new line")
end

local function test_deleted_file()
  local files = T.parse_diff(table.concat({
    "diff --git a/dead.txt b/dead.txt",
    "deleted file mode 100644",
    "index 1111111..0000000",
    "--- a/dead.txt",
    "+++ /dev/null",
    "@@ -1 +0,0 @@",
    "-gone",
  }, "\n"))
  assert_eq(#files, 1, "deleted file count")
  assert_true(files[1].new_null, "deleted file new_null")
  assert_eq(T.file_status(files[1]), "D", "deleted file status")
end

local function test_binary_file()
  local files = T.parse_diff(table.concat({
    "diff --git a/image.png b/image.png",
    "index 1111111..2222222 100644",
    "Binary files a/image.png and b/image.png differ",
  }, "\n"))
  assert_eq(#files, 1, "binary file count")
  assert_true(files[1].binary, "binary marker")
  assert_eq(T.file_status(files[1]), "B", "binary status")
  assert_eq(files[1].metadata[1], "Binary files a/image.png and b/image.png differ", "binary metadata")
end

local function test_rename_only_file()
  local files = T.parse_diff(table.concat({
    "diff --git a/old.txt b/new.txt",
    "similarity index 100%",
    "rename from old.txt",
    "rename to new.txt",
  }, "\n"))
  assert_eq(#files, 1, "rename file count")
  assert_true(files[1].renamed, "rename marker")
  assert_eq(files[1].old_path, "old.txt", "rename old path")
  assert_eq(files[1].path, "new.txt", "rename new path")
  assert_eq(T.file_status(files[1]), "R", "rename status")
end

local function test_mode_only_file()
  local files = T.parse_diff(table.concat({
    "diff --git a/script.sh b/script.sh",
    "old mode 100644",
    "new mode 100755",
  }, "\n"))
  assert_eq(#files, 1, "mode file count")
  assert_true(files[1].mode_only, "mode marker")
  assert_eq(T.file_status(files[1]), "T", "mode status")
  assert_eq(#files[1].metadata, 2, "mode metadata")
end

local function test_large_file_safeguard()
  local file = T.parse_diff(table.concat({
    "diff --git a/big.txt b/big.txt",
    "--- a/big.txt",
    "+++ b/big.txt",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n"))[1]
  local large_lines = {}
  for i = 1, T.omit_line_threshold do
    large_lines[i] = "line " .. i
  end
  local rendered = T.apply_large_safeguard(file, "new", large_lines)
  assert_true(file.omitted, "large file omitted")
  assert_true(file.large, "large file marked large")
  assert_eq(rendered[1], "Large file omitted from Pi review rendering", "large placeholder")
end

local function test_split_args_with_quotes()
  local args = T.split_args([[main...HEAD -- "path with spaces.lua" 'another path.ts']])
  assert_eq(args[1], "main...HEAD", "split first arg")
  assert_eq(args[2], "--", "split pathspec separator")
  assert_eq(args[3], "path with spaces.lua", "split double quoted path")
  assert_eq(args[4], "another path.ts", "split single quoted path")

  local ok, err = pcall(T.split_args, [[main...HEAD "unterminated]])
  assert_true(not ok and tostring(err):find("Unclosed quote", 1, true), "unclosed quote was not rejected")
end

local function test_pr_source()
  local source = T.pr_source("123")
  assert_eq(source.kind, "pr", "pr source kind")
  assert_eq(source.label, "PR #123", "pr source label")

  local parsed = T.source_from("pr 123", ".")
  assert_eq(parsed.kind, "pr", "pr input parsed as pr source")
  assert_eq(parsed.input, "123", "pr input number")
end

test_normal_diff()
test_plain_unified_patch()
test_deleted_file()
test_binary_file()
test_rename_only_file()
test_mode_only_file()
test_large_file_safeguard()
test_split_args_with_quotes()
test_pr_source()

print("review_diff_tests: ok")
