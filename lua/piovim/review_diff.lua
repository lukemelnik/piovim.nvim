local PluginBuffer = require("piovim.plugin_buffer")

local M = {}

local state = {
  root = nil,
  comparison = nil,
  source = nil,
  files = {},
  file_index = 1,
  annotations = {},
  list_buf = nil,
  old_buf = nil,
  new_buf = nil,
  list_win = nil,
  old_win = nil,
  new_win = nil,
  previous_win = nil,
  previous_buf = nil,
  comments_expanded = true,
  next_annotation_id = 1,
  interaction_active = false,
  pending_refresh = false,
  watch_timer = nil,
  watch_signature = nil,
  watch_interval_ms = 1500,
}

local ns = vim.api.nvim_create_namespace("piovim-review-diff")
local state_version = 1
local large_line_threshold = 5000
local omit_line_threshold = 20000
local max_untracked_file_bytes = 512 * 1024
local default_base_override = nil

local function valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_piovim_buf(buf)
  return PluginBuffer.is_plugin_buffer(buf)
end

local function source_win()
  local best_win = nil
  local best_area = 0

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not is_piovim_buf(buf) then
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if area > best_area then
        best_win = win
        best_area = area
      end
    end
  end

  return best_win
end

local function state_dir()
  return vim.fn.stdpath("state") .. "/piovim/reviews"
end

local function repo_key(root)
  return vim.fn.sha256(root or "no-root"):sub(1, 16)
end

local function state_path(root)
  return state_dir() .. "/" .. repo_key(root) .. ".json"
end

local function ensure_state_dir()
  vim.fn.mkdir(state_dir(), "p")
end

local function prune_old_state_files()
  ensure_state_dir()
  local now = os.time()
  for _, path in ipairs(vim.fn.glob(state_dir() .. "/*.json", false, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.mtime and now - stat.mtime.sec > 30 * 24 * 60 * 60 then
      pcall(vim.fn.delete, path)
    end
  end
end

local function save_state()
  if not state.root then
    return
  end
  ensure_state_dir()
  local payload = {
    version = state_version,
    root = state.root,
    comparison_input = state.source and state.source.input or (state.comparison and state.comparison.input) or nil,
    source = state.source,
    annotations = state.annotations,
    next_annotation_id = state.next_annotation_id,
    updated_at = os.time(),
  }
  vim.fn.writefile({ vim.json.encode(payload) }, state_path(state.root))
end

local function load_state(root)
  state.annotations = {}
  state.next_annotation_id = 1

  local path = state_path(root)
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  local ok, payload = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(payload) ~= "table" or payload.root ~= root then
    return
  end
  if type(payload.annotations) == "table" then
    state.annotations = payload.annotations
  end
  if type(payload.next_annotation_id) == "number" then
    state.next_annotation_id = payload.next_annotation_id
  end
end

local function system(args, opts)
  opts = opts or {}
  local result = vim.system(args, { cwd = opts.cwd, text = true }):wait()
  if result.code ~= 0 then
    error(vim.trim(result.stderr ~= "" and result.stderr or result.stdout))
  end
  return result.stdout or ""
end

local function git_output(args, root)
  return system(vim.list_extend({ "git" }, args), { cwd = root })
end

local function git_root()
  return vim.trim(system({ "git", "rev-parse", "--show-toplevel" }))
end

local function git_ref_exists(root, ref)
  local result = vim.system({ "git", "rev-parse", "--verify", "--quiet", ref }, { cwd = root, text = true }):wait()
  return result.code == 0
end

local function split_args(text)
  local args = {}
  local current = {}
  local quote = nil
  local escaped = false

  for index = 1, #(text or "") do
    local char = text:sub(index, index)
    if escaped then
      table.insert(current, char)
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        table.insert(current, char)
      end
    elseif char == "'" or char == '"' then
      quote = char
    elseif char:match("%s") then
      if #current > 0 then
        table.insert(args, table.concat(current))
        current = {}
      end
    else
      table.insert(current, char)
    end
  end

  if escaped then
    table.insert(current, "\\")
  end
  if quote then
    error("Unclosed quote in git diff args")
  end
  if #current > 0 then
    table.insert(args, table.concat(current))
  end
  return args
end

local function tracked_input(opts, callback)
  state.interaction_active = true
  vim.ui.input(opts, function(input)
    state.interaction_active = false
    callback(input)
    if state.pending_refresh then
      state.pending_refresh = false
      M.refresh()
    end
  end)
end

local function default_base_ref(root)
  if default_base_override and git_ref_exists(root, default_base_override) then
    return default_base_override
  end
  if git_ref_exists(root, "origin/main") then
    return "origin/main"
  elseif git_ref_exists(root, "main") then
    return "main"
  elseif git_ref_exists(root, "origin/master") then
    return "origin/master"
  elseif git_ref_exists(root, "master") then
    return "master"
  end
  return "HEAD~1"
end

local function git_rev_parse(root, rev)
  local result = vim.system({ "git", "rev-parse", "--verify", rev }, { cwd = root, text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout or "")
end

local pr_source

local function source_from(input, root)
  input = vim.trim(input or "")
  local pr_number = input:match("^pr%s+(%S+)$")
  if pr_number or input == "pr" then
    return pr_source(pr_number or "")
  end
  if input == "" or input == "working" or input == "worktree" or input == "working-tree" then
    return {
      kind = "working-tree",
      label = "working tree",
      input = input,
      args = { "diff", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" },
      old_source = "HEAD",
      new_source = "worktree",
      include_untracked = true,
      watch = true,
    }
  end

  if input == "staged" or input == "cached" or input == "index" then
    return {
      kind = "staged",
      label = "staged",
      input = input,
      args = { "diff", "--cached", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" },
      old_source = "HEAD",
      new_source = "index",
      watch = true,
    }
  end

  if input == "main" or input == "origin" or input == "origin/main" or input == "branch" then
    local ref = input == "origin" and "origin/main" or input
    if input == "main" and not git_ref_exists(root, "main") and git_ref_exists(root, "origin/main") then
      ref = "origin/main"
    elseif input == "branch" then
      ref = default_base_ref(root)
    end
    return {
      kind = "branch",
      label = ref .. "...HEAD",
      input = input,
      args = { "diff", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", ref .. "...HEAD" },
      old_source = ref,
      new_source = "HEAD",
      watch = true,
    }
  end

  local args = { "diff", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/" }
  vim.list_extend(args, split_args(input))
  return { kind = "custom-diff", label = input, input = input, args = args, old_source = nil, new_source = "worktree", watch = true }
end

local function commit_source(rev, root)
  rev = vim.trim(rev or "HEAD")
  local sha = git_rev_parse(root, rev) or rev
  return {
    kind = "commit",
    label = "commit " .. rev,
    input = rev,
    args = { "show", "--format=short", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", rev },
    old_source = rev .. "^",
    new_source = rev,
    watch = sha ~= rev,
  }
end

local function range_source(range, root)
  range = vim.trim(range or "")
  if range == "" then
    range = default_base_ref(root) .. "...HEAD"
  end
  local old_source, new_source = range:match("^(.+)%.%.%.(.+)$")
  if not old_source then
    old_source, new_source = range:match("^(.+)%.%.(.+)$")
  end
  return {
    kind = "range",
    label = range,
    input = range,
    args = { "diff", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", range },
    old_source = old_source,
    new_source = new_source or "HEAD",
    watch = true,
  }
end

local function patch_source(path)
  path = vim.trim(path or "")
  return {
    kind = "patch",
    label = path == "" and "patch" or ("patch " .. path),
    input = path,
    path = path,
    old_source = "patch",
    new_source = "patch",
    watch = path ~= "",
  }
end

pr_source = function(number)
  number = vim.trim(number or "")
  return {
    kind = "pr",
    label = number == "" and "current branch PR" or ("PR #" .. number),
    input = number,
    old_source = "PR base",
    new_source = "PR head",
    watch = false,
  }
end

local function new_file(path)
  return {
    path = path,
    old_path = path,
    old_null = false,
    new_null = false,
    hunks = {},
    patch_old_lines = nil,
    patch_new_lines = nil,
    metadata = {},
    binary = false,
    renamed = false,
    mode_only = false,
    large = false,
    omitted = false,
    omitted_reason = nil,
  }
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return nil
  end
  return {
    header = line,
    old_start = tonumber(old_start),
    old_count = old_count ~= "" and tonumber(old_count) or 1,
    new_start = tonumber(new_start),
    new_count = new_count ~= "" and tonumber(new_count) or 1,
  }
end

local function untracked_diff(root)
  local output = git_output({ "ls-files", "--others", "--exclude-standard" }, root)
  local chunks = {}

  for _, path in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    local full_path = root .. "/" .. path
    local stat = vim.uv.fs_stat(full_path)
    if vim.fn.filereadable(full_path) == 1 and stat and stat.size <= max_untracked_file_bytes then
      local lines = vim.fn.readfile(full_path)
      table.insert(chunks, "diff --git a/" .. path .. " b/" .. path)
      table.insert(chunks, "new file mode 100644")
      table.insert(chunks, "index 0000000..0000000")
      table.insert(chunks, "--- /dev/null")
      table.insert(chunks, "+++ b/" .. path)
      table.insert(chunks, "@@ -0,0 +1," .. tostring(#lines) .. " @@")
      for _, line in ipairs(lines) do
        table.insert(chunks, "+" .. line)
      end
    elseif stat and stat.size > max_untracked_file_bytes then
      table.insert(chunks, "diff --git a/" .. path .. " b/" .. path)
      table.insert(chunks, "new file mode 100644")
      table.insert(chunks, "--- /dev/null")
      table.insert(chunks, "+++ b/" .. path)
      table.insert(chunks, "@@ -0,0 +1,5 @@")
      table.insert(chunks, "+Large untracked file omitted from Pi review rendering")
      table.insert(chunks, "+file: " .. path)
      table.insert(chunks, "+bytes: " .. tostring(stat.size))
      table.insert(chunks, "+threshold: " .. tostring(max_untracked_file_bytes))
      table.insert(chunks, "+Open the source file directly or narrow the review source to inspect this file.")
    end
  end

  return table.concat(chunks, "\n")
end

local function clean_patch_path(path)
  path = (path or ""):gsub("\t.*$", "")
  if path == "/dev/null" then
    return path
  end
  return path:gsub("^[ab]/", "")
end

local function parse_diff(text)
  local files = {}
  local file = nil
  local in_hunk = false
  local pending_old_path = nil

  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local old_diff_path, new_diff_path = line:match("^diff %-%-git a/(.-) b/(.+)")
    local plain_old_path = line:match("^%-%-%- (.+)")
    local plain_new_path = line:match("^%+%+%+ (.+)")
    if old_diff_path then
      file = new_file(new_diff_path)
      file.old_path = old_diff_path
      file.patch_old_lines = {}
      file.patch_new_lines = {}
      in_hunk = false
      pending_old_path = nil
      table.insert(files, file)
    elseif not file and plain_old_path then
      pending_old_path = clean_patch_path(plain_old_path)
    elseif not file and pending_old_path and plain_new_path then
      local new_path = clean_patch_path(plain_new_path)
      file = new_file(new_path ~= "/dev/null" and new_path or pending_old_path)
      file.old_path = pending_old_path
      file.old_null = pending_old_path == "/dev/null"
      file.new_null = new_path == "/dev/null"
      file.patch_old_lines = {}
      file.patch_new_lines = {}
      in_hunk = false
      pending_old_path = nil
      table.insert(files, file)
    elseif file then
      if line == "--- /dev/null" then
        file.old_null = true
      elseif line == "+++ /dev/null" then
        file.new_null = true
      else
        local old_path = line:match("^%-%-%- a/(.+)")
        local new_path = line:match("^%+%+%+ b/(.+)")
        if old_path then
          file.old_path = old_path
        elseif new_path then
          file.path = new_path
        end
      end

      local rename_from = line:match("^rename from (.+)")
      local rename_to = line:match("^rename to (.+)")
      if rename_from then
        file.old_path = rename_from
        file.renamed = true
      elseif rename_to then
        file.path = rename_to
        file.renamed = true
      elseif line:match("^Binary files .+ differ") or line:match("^GIT binary patch") then
        file.binary = true
      elseif line:match("^old mode ") or line:match("^new mode ") then
        file.mode_only = true
      end

      if line:match("^old mode ")
        or line:match("^new mode ")
        or line:match("^new file mode ")
        or line:match("^deleted file mode ")
        or line:match("^similarity index ")
        or line:match("^dissimilarity index ")
        or line:match("^rename from ")
        or line:match("^rename to ")
        or line:match("^copy from ")
        or line:match("^copy to ")
        or line:match("^Binary files .+ differ")
        or line:match("^GIT binary patch") then
        table.insert(file.metadata, line)
      end

      local hunk = parse_hunk_header(line)
      if hunk then
        table.insert(file.hunks, hunk)
        in_hunk = true
      elseif in_hunk then
        local marker = line:sub(1, 1)
        local body = line:sub(2)
        if marker == " " then
          if #file.patch_old_lines < omit_line_threshold then
            table.insert(file.patch_old_lines, body)
          end
          if #file.patch_new_lines < omit_line_threshold then
            table.insert(file.patch_new_lines, body)
          end
        elseif marker == "-" then
          if #file.patch_old_lines < omit_line_threshold then
            table.insert(file.patch_old_lines, body)
          end
        elseif marker == "+" then
          if #file.patch_new_lines < omit_line_threshold then
            table.insert(file.patch_new_lines, body)
          end
        elseif line:match("^\\ No newline") then
          -- metadata line; ignore
        elseif line:match("^diff %-%-git ") then
          in_hunk = false
        end
        if #file.patch_old_lines >= omit_line_threshold or #file.patch_new_lines >= omit_line_threshold then
          file.omitted = true
          file.large = true
          file.omitted_reason = "patch exceeds " .. tostring(omit_line_threshold) .. " rendered lines"
        elseif #file.patch_old_lines >= large_line_threshold or #file.patch_new_lines >= large_line_threshold then
          file.large = true
        end
      end
    end
  end

  return files
end

local function current_file()
  return state.files[state.file_index]
end

local function file_status(file)
  if file.binary then
    return "B"
  elseif file.renamed then
    return "R"
  elseif file.old_null then
    return "A"
  elseif file.new_null then
    return "D"
  elseif file.mode_only and #file.hunks == 0 then
    return "T"
  end
  return "M"
end

local function file_icon(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", ""
  end

  local ext = vim.fn.fnamemodify(path, ":e")
  local icon, hl = devicons.get_icon(path, ext, { default = true })
  return icon or "", hl or ""
end

local side_lines

local function annotation_key(path, line)
  return path .. ":" .. tostring(line)
end

local function annotations_for(path, line)
  return state.annotations[annotation_key(path, line)] or {}
end

local function current_new_lines()
  if valid_buf(state.new_buf) then
    return vim.api.nvim_buf_get_lines(state.new_buf, 0, -1, false)
  end
  local file = current_file()
  return file and side_lines(file, "new") or {}
end

local function line_text_at(lines, line)
  return lines[math.max(1, line)] or ""
end

local function normalize_snippet(text)
  return vim.trim((text or ""):gsub("%s+", " "))
end

local function find_unique_snippet(lines, snippet)
  snippet = normalize_snippet(snippet)
  if snippet == "" then
    return nil
  end

  local match = nil
  for i, line in ipairs(lines) do
    if normalize_snippet(line) == snippet then
      if match then
        return nil
      end
      match = i
    end
  end
  return match
end

local function reanchor_annotation(note, lines)
  if not note or not note.line then
    return
  end
  local current = line_text_at(lines, note.line)
  if note.anchor_text and normalize_snippet(current) == normalize_snippet(note.anchor_text) then
    note.stale = false
    return
  end

  local start_line = math.max(1, note.line - 20)
  local end_line = math.min(#lines, note.line + 20)
  local anchor = normalize_snippet(note.anchor_text or note.text)
  if anchor ~= "" then
    local found = nil
    for line = start_line, end_line do
      if normalize_snippet(lines[line]) == anchor then
        found = line
        break
      end
    end
    if found then
      local delta = found - note.line
      note.line = found
      note.new_line = found
      if note.end_line then
        note.end_line = math.max(found, note.end_line + delta)
      end
      note.stale = false
      return
    end

    local unique = find_unique_snippet(lines, anchor)
    if unique then
      local delta = unique - note.line
      note.line = unique
      note.new_line = unique
      if note.end_line then
        note.end_line = math.max(unique, note.end_line + delta)
      end
      note.stale = false
      return
    end
  end

  note.stale = true
end

local function reanchor_annotations_for_file(file)
  if not file then
    return
  end

  local lines = side_lines(file, "new")
  local moved = {}
  local keys_to_clear = {}
  for key, notes in pairs(state.annotations) do
    if key:sub(1, #file.path + 1) == file.path .. ":" then
      for _, note in ipairs(notes) do
        reanchor_annotation(note, lines)
        local new_key = annotation_key(note.path, note.line)
        moved[new_key] = moved[new_key] or {}
        table.insert(moved[new_key], note)
      end
      table.insert(keys_to_clear, key)
    end
  end
  for _, key in ipairs(keys_to_clear) do
    state.annotations[key] = nil
  end
  for key, notes in pairs(moved) do
    state.annotations[key] = state.annotations[key] or {}
    vim.list_extend(state.annotations[key], notes)
  end
end

local function setup_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local border = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
  local hint = vim.api.nvim_get_hl(0, { name = "DiagnosticHint", link = false })
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  local bg = float.bg or normal.bg

  vim.api.nvim_set_hl(0, "PiovimReviewComment", { default = true, fg = normal.fg, bg = bg })
  vim.api.nvim_set_hl(0, "PiovimReviewCommentBorder", { default = true, fg = border.fg or hint.fg or comment.fg, bg = bg })
  vim.api.nvim_set_hl(0, "PiovimReviewCommentHeader", { default = true, fg = hint.fg or normal.fg, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, "PiovimReviewCommentMuted", { default = true, fg = comment.fg, bg = bg })
  vim.api.nvim_set_hl(0, "PiovimReviewCommentSpacer", { default = true, fg = bg, bg = bg })
end

local function lock_review_buf(buf)
  if valid_buf(buf) and vim.api.nvim_buf_get_name(buf):match("Pi Review") then
    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
end

local function set_buf_lines(buf, lines)
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  lock_review_buf(buf)
end

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  return ft or ""
end

local function read_git_file(root, ref, path)
  if not ref or not path then
    return {}
  end
  local result = vim.system({ "git", "show", ref .. ":" .. path }, { cwd = root, text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  return vim.split(result.stdout or "", "\n", { plain = true })
end

local function read_index_file(root, path)
  local result = vim.system({ "git", "show", ":" .. path }, { cwd = root, text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  return vim.split(result.stdout or "", "\n", { plain = true })
end

local function read_loaded_file(root, path)
  local full_path = vim.fn.fnamemodify(root .. "/" .. path, ":p")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p") == full_path then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  return nil
end

local function read_worktree_file(root, path)
  local loaded = read_loaded_file(root, path)
  if loaded then
    return loaded
  end

  local full_path = root .. "/" .. path
  if vim.fn.filereadable(full_path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(full_path)
end

local function metadata_lines(file, side)
  local lines = {}
  local status = file_status(file)
  table.insert(lines, "metadata-only change: " .. status)
  if file.renamed then
    table.insert(lines, (side == "old" and "from: " or "to: ") .. (side == "old" and file.old_path or file.path))
  else
    table.insert(lines, file.path)
  end
  for _, line in ipairs(file.metadata or {}) do
    table.insert(lines, line)
  end
  return lines
end

local function omitted_lines(file, side, line_count)
  file.omitted = true
  file.large = true
  file.omitted_reason = file.omitted_reason or ("file side has " .. tostring(line_count) .. " lines")
  return {
    "Large file omitted from Pi review rendering",
    "file: " .. file.path,
    "side: " .. side,
    "lines: " .. tostring(line_count),
    "threshold: " .. tostring(omit_line_threshold),
    "Open the source file directly or narrow the review source to inspect this file.",
  }
end

local function apply_large_safeguard(file, side, lines)
  local count = #lines
  if count >= omit_line_threshold then
    return omitted_lines(file, side, count)
  end
  if count >= large_line_threshold then
    file.large = true
  end
  return lines
end

side_lines = function(file, side)
  local comparison = state.comparison or {}
  if file.binary then
    return metadata_lines(file, side)
  end
  if #file.hunks == 0 and file.metadata and #file.metadata > 0 then
    return metadata_lines(file, side)
  end
  if comparison.kind == "patch" then
    return apply_large_safeguard(file, side, side == "old" and (file.patch_old_lines or {}) or (file.patch_new_lines or {}))
  end

  if side == "old" then
    if file.old_null then
      return {}
    end
    local lines = read_git_file(state.root, comparison.old_source, file.old_path)
    if #lines > 0 then
      return apply_large_safeguard(file, side, lines)
    end
    return apply_large_safeguard(file, side, file.patch_old_lines or {})
  end

  if file.new_null then
    return {}
  end
  if comparison.new_source == "index" then
    return apply_large_safeguard(file, side, read_index_file(state.root, file.path))
  elseif comparison.new_source == "HEAD" then
    return apply_large_safeguard(file, side, read_git_file(state.root, "HEAD", file.path))
  elseif comparison.new_source and comparison.new_source ~= "worktree" and comparison.new_source ~= "patch" then
    local lines = read_git_file(state.root, comparison.new_source, file.path)
    if #lines > 0 then
      return apply_large_safeguard(file, side, lines)
    end
  end
  if comparison.new_source == "patch" then
    return apply_large_safeguard(file, side, file.patch_new_lines or {})
  end
  return apply_large_safeguard(file, side, read_worktree_file(state.root, file.path))
end

local function clear_diff_windows()
  local current_win = vim.api.nvim_get_current_win()
  for _, win in ipairs({ state.old_win, state.new_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_set_current_win, win)
      pcall(vim.cmd, "diffoff")
      pcall(vim.wo, win, "foldenable", false)
    end
  end
  if valid_win(current_win) then
    pcall(vim.api.nvim_set_current_win, current_win)
  end
end

local function render_list()
  if not valid_buf(state.list_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
  local lines = { "Changes (" .. tostring(#state.files) .. ")" }
  for i, file in ipairs(state.files) do
    local prefix = i == state.file_index and "▸ " or "  "
    local icon = file_icon(file.path)
    local note_count = 0
    for key, notes in pairs(state.annotations) do
      if key:sub(1, #file.path + 1) == file.path .. ":" then
        note_count = note_count + #notes
      end
    end
    local suffix = note_count > 0 and ("  (" .. note_count .. ")") or ""
    local badge = file.omitted and " !" or (file.large and " ~" or "")
    table.insert(lines, prefix .. icon .. " " .. file.path .. "  " .. file_status(file) .. badge .. suffix)
  end
  if #state.files == 0 then
    table.insert(lines, "No changes")
  end
  set_buf_lines(state.list_buf, lines)

  for i, file in ipairs(state.files) do
    local icon, icon_hl = file_icon(file.path)
    local row = i
    if icon_hl ~= "" then
      local col = (i == state.file_index) and 2 or 2
      vim.api.nvim_buf_set_extmark(state.list_buf, ns, row, col, {
        end_col = col + #icon,
        hl_group = icon_hl,
      })
    end
  end
end

local function wrap_text(text, width)
  width = math.max(24, width or 72)
  local wrapped = {}
  for _, raw_line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = raw_line
    if line == "" then
      table.insert(wrapped, "")
    end
    while #line > width do
      local chunk = line:sub(1, width)
      local break_at = chunk:match("^.*()%s+")
      if break_at and break_at > 8 then
        table.insert(wrapped, vim.trim(line:sub(1, break_at - 1)))
        line = vim.trim(line:sub(break_at + 1))
      else
        table.insert(wrapped, chunk)
        line = line:sub(width + 1)
      end
    end
    if line ~= "" then
      table.insert(wrapped, line)
    end
  end
  return wrapped
end

local function note_header(note)
  local line_label = tostring(note.line)
  if note.end_line and note.end_line ~= note.line then
    line_label = line_label .. "–" .. tostring(note.end_line)
  end
  local suffix = note.stale and "  (stale anchor)" or ""
  return "Review note ▸ new " .. line_label .. suffix
end

local function pad_line(text, width)
  text = text or ""
  if #text >= width then
    return text:sub(1, width)
  end
  return text .. string.rep(" ", width - #text)
end

local function card_width()
  local win_width = valid_win(state.new_win) and vim.api.nvim_win_get_width(state.new_win) or 88
  return math.max(32, win_width - 8)
end

local function comment_virtual_lines(notes)
  local width = card_width()
  local content_width = width - 4
  local lines = {}

  for index, note in ipairs(notes) do
    if index > 1 then
      table.insert(lines, { { "  " .. pad_line("", width), "PiovimReviewCommentSpacer" } })
    end

    table.insert(lines, { { "  ╭" .. string.rep("─", width - 2) .. "╮", "PiovimReviewCommentBorder" } })
    table.insert(lines, { { "  │ " .. pad_line(note_header(note), content_width), "PiovimReviewCommentHeader" }, { " │", "PiovimReviewCommentBorder" } })
    for _, body_line in ipairs(wrap_text(note.note, content_width)) do
      table.insert(lines, { { "  │ " .. pad_line(body_line, content_width), "PiovimReviewComment" }, { " │", "PiovimReviewCommentBorder" } })
    end
    table.insert(lines, { { "  ╰" .. string.rep("─", width - 2) .. "╯", "PiovimReviewCommentBorder" } })
  end

  return lines
end

local function old_line_for_new_line(file, new_line)
  if file.old_null then
    return 1
  end

  for _, hunk in ipairs(file.hunks) do
    local new_end = hunk.new_start + math.max(0, hunk.new_count - 1)
    if new_line >= hunk.new_start and new_line <= new_end then
      if hunk.old_count == 0 then
        return math.max(1, hunk.old_start)
      end
      local delta = new_line - hunk.new_start
      return math.max(1, math.min(hunk.old_start + delta, hunk.old_start + hunk.old_count - 1))
    end
  end

  return new_line
end

local function empty_virtual_lines(count)
  local width = card_width() + 2
  local lines = {}
  for _ = 1, count do
    table.insert(lines, { { string.rep(" ", width), "PiovimReviewCommentSpacer" } })
  end
  return lines
end

local function render_annotations()
  if not valid_buf(state.new_buf) then
    return
  end
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(state.new_buf, ns, 0, -1)
  if valid_buf(state.old_buf) then
    vim.api.nvim_buf_clear_namespace(state.old_buf, ns, 0, -1)
  end
  local file = current_file()
  if not file then
    return
  end

  for key, notes in pairs(state.annotations) do
    if key:sub(1, #file.path + 1) == file.path .. ":" then
      local line = tonumber(key:match(":(%d+)$"))
      if line and line > 0 and line <= vim.api.nvim_buf_line_count(state.new_buf) then
        if state.comments_expanded then
          local virt_lines = comment_virtual_lines(notes)
          vim.api.nvim_buf_set_extmark(state.new_buf, ns, line - 1, 0, {
            virt_lines = virt_lines,
            virt_lines_above = false,
          })

          if valid_buf(state.old_buf) then
            local old_line = old_line_for_new_line(file, line)
            local old_line_count = vim.api.nvim_buf_line_count(state.old_buf)
            old_line = math.max(1, math.min(old_line_count, old_line))
            vim.api.nvim_buf_set_extmark(state.old_buf, ns, old_line - 1, 0, {
              virt_lines = empty_virtual_lines(#virt_lines),
              virt_lines_above = false,
            })
          end
        else
          vim.api.nvim_buf_set_extmark(state.new_buf, ns, line - 1, 0, {
            virt_text = { { " 󰍩 " .. tostring(#notes) .. " note" .. (#notes == 1 and "" or "s"), "DiagnosticWarn" } },
            virt_text_pos = "eol",
          })
        end
      end
    end
  end
end

function M.resize_if_open()
  if not (valid_win(state.old_win) and valid_win(state.new_win)) then
    return false
  end

  if valid_win(state.list_win) then
    pcall(vim.api.nvim_win_set_width, state.list_win, 28)
  end
  local old_width = vim.api.nvim_win_get_width(state.old_win)
  local new_width = vim.api.nvim_win_get_width(state.new_win)
  local total = old_width + new_width
  if total > 20 then
    pcall(vim.api.nvim_win_set_width, state.old_win, math.floor(total / 2))
    pcall(vim.api.nvim_win_set_width, state.new_win, math.ceil(total / 2))
  end
  render_annotations()
  return true
end

local function render_file()
  local restore_win = vim.api.nvim_get_current_win()
  local file = current_file()
  if not file or not valid_buf(state.old_buf) or not valid_buf(state.new_buf) then
    if valid_buf(state.old_buf) then
      set_buf_lines(state.old_buf, { "No diff to show." })
    end
    if valid_buf(state.new_buf) then
      set_buf_lines(state.new_buf, { "No diff to show." })
    end
    return
  end

  clear_diff_windows()
  set_buf_lines(state.old_buf, side_lines(file, "old"))
  set_buf_lines(state.new_buf, side_lines(file, "new"))
  reanchor_annotations_for_file(file)
  save_state()

  local ft = filetype_for(file.path)
  vim.bo[state.old_buf].filetype = ft
  vim.bo[state.new_buf].filetype = ft
  vim.api.nvim_buf_set_name(state.old_buf, "Pi Review OLD: " .. file.old_path)
  vim.api.nvim_buf_set_name(state.new_buf, "Pi Review NEW: " .. file.path)

  if valid_win(state.old_win) and valid_win(state.new_win) then
    vim.wo[state.old_win].foldenable = false
    vim.wo[state.new_win].foldenable = false
    if not file.old_null and not file.new_null then
      vim.api.nvim_set_current_win(state.old_win)
      vim.cmd("diffthis")
      vim.api.nvim_set_current_win(state.new_win)
      vim.cmd("diffthis")
    end
  end

  local first_hunk = file.hunks[1]
  if first_hunk and valid_win(state.new_win) then
    pcall(vim.api.nvim_win_set_cursor, state.new_win, { math.max(1, first_hunk.new_start), 0 })
    if valid_win(state.old_win) then
      pcall(vim.api.nvim_win_set_cursor, state.old_win, { math.max(1, first_hunk.old_start), 0 })
    end
  end

  render_annotations()
  if valid_win(restore_win) then
    pcall(vim.api.nvim_set_current_win, restore_win)
  end
end

local function select_file(index)
  if #state.files == 0 then
    return
  end
  state.file_index = math.max(1, math.min(index, #state.files))
  render_list()
  render_file()
end

local function current_range()
  local file = current_file()
  if not file then
    return nil
  end

  local win = valid_win(state.new_win) and state.new_win or vim.api.nvim_get_current_win()
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local buffer_lines = valid_buf(state.new_buf) and vim.api.nvim_buf_get_lines(state.new_buf, 0, -1, false) or {}
  return {
    path = file.path,
    line = line,
    new_line = line,
    text = buffer_lines[line] or "",
    context_before = buffer_lines[math.max(1, line - 1)],
    context_after = buffer_lines[math.min(#buffer_lines, line + 1)],
  }
end

local function visual_range()
  local file = current_file()
  if not file or not valid_buf(state.new_buf) then
    return nil
  end
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local buffer_lines = vim.api.nvim_buf_get_lines(state.new_buf, 0, -1, false)
  local lines = {}
  for line = start_line, end_line do
    lines[#lines + 1] = buffer_lines[line] or ""
  end
  return {
    path = file.path,
    line = start_line,
    end_line = end_line,
    new_line = start_line,
    text = table.concat(lines, "\n"),
    context_before = buffer_lines[math.max(1, start_line - 1)],
    context_after = buffer_lines[math.min(#buffer_lines, end_line + 1)],
  }
end

local function add_annotation(note, range)
  range = range or current_range()
  if not range or not range.path or not range.line then
    vim.notify("Move onto a file line before annotating", vim.log.levels.WARN)
    return nil
  end
  if not note or note == "" then
    return nil
  end

  local key = annotation_key(range.path, range.line)
  state.annotations[key] = state.annotations[key] or {}
  local annotation = {
    id = state.next_annotation_id,
    path = range.path,
    line = range.line,
    end_line = range.end_line,
    new_line = range.new_line,
    text = range.text,
    note = note,
  }
  if not annotation.anchor_text or annotation.anchor_text == "" then
    annotation.anchor_text = range.text
  end
  annotation.anchor_context_before = range.context_before
  annotation.anchor_context_after = range.context_after
  state.next_annotation_id = state.next_annotation_id + 1
  table.insert(state.annotations[key], annotation)
  save_state()
  render_list()
  render_annotations()
  return annotation
end

local function notes_for_current_line()
  local range = current_range()
  if not range then
    return nil, nil
  end

  local exact_key = annotation_key(range.path, range.line)
  if state.annotations[exact_key] and #state.annotations[exact_key] > 0 then
    return exact_key, state.annotations[exact_key]
  end

  local best_key = nil
  local best_line = nil
  for key, notes in pairs(state.annotations) do
    if #notes > 0 and key:sub(1, #range.path + 1) == range.path .. ":" then
      local line = tonumber(key:match(":(%d+)$"))
      if line and line <= range.line and (not best_line or line > best_line) then
        best_key = key
        best_line = line
      end
    end
  end

  if best_key then
    return best_key, state.annotations[best_key]
  end

  return exact_key, nil
end

local function edit_current_annotation()
  local _, notes = notes_for_current_line()
  if not notes or #notes == 0 then
    vim.notify("No review note on this line", vim.log.levels.WARN)
    return
  end
  local note = notes[#notes]
  tracked_input({ prompt = "Edit review note: ", default = note.note }, function(input)
    if not input or input == "" then
      return
    end
    note.note = input
    save_state()
    render_list()
    render_annotations()
  end)
end

local function delete_current_annotation()
  local key, notes = notes_for_current_line()
  if not key or not notes or #notes == 0 then
    vim.notify("No review note on this line", vim.log.levels.WARN)
    return
  end
  table.remove(notes, #notes)
  if #notes == 0 then
    state.annotations[key] = nil
  end
  save_state()
  render_list()
  render_annotations()
end

local function jump_annotation(direction)
  local file = current_file()
  if not file or not valid_win(state.new_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.new_win)[1]
  local lines = {}
  for key, notes in pairs(state.annotations) do
    if #notes > 0 and key:sub(1, #file.path + 1) == file.path .. ":" then
      local line = tonumber(key:match(":(%d+)$"))
      if line then
        table.insert(lines, line)
      end
    end
  end
  table.sort(lines)

  local target = nil
  for _, line in ipairs(lines) do
    if direction > 0 and line > cursor then
      target = line
      break
    elseif direction < 0 and line < cursor then
      target = line
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(state.new_win, { target, 0 })
  end
end

local function toggle_comments()
  state.comments_expanded = not state.comments_expanded
  render_annotations()
end

local function set_quickfix()
  local items = {}
  for _, notes in pairs(state.annotations) do
    for _, note in ipairs(notes) do
      table.insert(items, {
        filename = state.root .. "/" .. note.path,
        lnum = note.line,
        col = 1,
        text = note.note,
      })
    end
  end
  vim.fn.setqflist({}, "r", { title = "Pi review notes", items = items })
  vim.cmd("copen")
end

local function jump_hunk(direction)
  local file = current_file()
  if not file or not valid_win(state.new_win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.new_win)[1]
  local target = nil
  for _, hunk in ipairs(file.hunks) do
    local row = math.max(1, hunk.new_start)
    if direction > 0 and row > cursor then
      target = row
      break
    elseif direction < 0 and row < cursor then
      target = row
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(state.new_win, { target, 0 })
  end
end

local create_scratch
local map_list_buffer

local function prompt_annotation(range)
  tracked_input({ prompt = "Review note: " }, function(input)
    add_annotation(input, range)
  end)
end

local function note_count_for_file(path)
  local count = 0
  for key, notes in pairs(state.annotations) do
    if key:sub(1, #path + 1) == path .. ":" then
      count = count + #notes
    end
  end
  return count
end

local function pick_file()
  local choices = {}
  for index, file in ipairs(state.files) do
    local note_count = note_count_for_file(file.path)
    local suffix = note_count > 0 and ("  (" .. note_count .. ")") or ""
    local badge = file.omitted and " !" or (file.large and " ~" or "")
    table.insert(choices, {
      index = index,
      label = file.path .. "  " .. file_status(file) .. badge .. suffix,
    })
  end
  if #choices == 0 then
    vim.notify("No files in current review", vim.log.levels.INFO)
    return
  end
  vim.ui.select(choices, { prompt = "Pi review file", format_item = function(item) return item.label end }, function(choice)
    if not choice then
      return
    end
    select_file(choice.index)
    if valid_win(state.new_win) then
      vim.api.nvim_set_current_win(state.new_win)
    end
  end)
end

local function toggle_file_list()
  if valid_win(state.list_win) then
    pcall(vim.api.nvim_win_close, state.list_win, true)
    state.list_win = nil
    state.list_buf = nil
    M.resize_if_open()
    if valid_win(state.new_win) then
      vim.api.nvim_set_current_win(state.new_win)
    end
    return
  end

  if not valid_win(state.old_win) then
    return
  end
  local return_win = valid_win(state.new_win) and state.new_win or state.old_win
  vim.api.nvim_set_current_win(state.old_win)
  vim.cmd("leftabove 28vsplit")
  state.list_buf = create_scratch("Pi Review Files", "piovim-review-files")
  vim.api.nvim_win_set_buf(0, state.list_buf)
  state.list_win = vim.api.nvim_get_current_win()
  map_list_buffer(state.list_buf)
  render_list()
  if valid_win(return_win) then
    vim.api.nvim_set_current_win(return_win)
  end
end

local function map_review_buffer(buf)
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "]f", function() select_file(state.file_index + 1) end, vim.tbl_extend("force", opts, { desc = "Next diff file" }))
  vim.keymap.set("n", "[f", function() select_file(state.file_index - 1) end, vim.tbl_extend("force", opts, { desc = "Previous diff file" }))
  vim.keymap.set("n", "]h", function() jump_hunk(1) end, vim.tbl_extend("force", opts, { desc = "Next diff hunk" }))
  vim.keymap.set("n", "[h", function() jump_hunk(-1) end, vim.tbl_extend("force", opts, { desc = "Previous diff hunk" }))
  vim.keymap.set("n", "a", function() prompt_annotation(current_range()) end, vim.tbl_extend("force", opts, { desc = "Annotate current line" }))
  vim.keymap.set("n", "]c", function() jump_annotation(1) end, vim.tbl_extend("force", opts, { desc = "Next review note" }))
  vim.keymap.set("n", "[c", function() jump_annotation(-1) end, vim.tbl_extend("force", opts, { desc = "Previous review note" }))
  vim.keymap.set("n", "e", edit_current_annotation, vim.tbl_extend("force", opts, { desc = "Edit review note" }))
  vim.keymap.set("n", "x", delete_current_annotation, vim.tbl_extend("force", opts, { desc = "Delete review note" }))
  vim.keymap.set("n", "z", toggle_comments, vim.tbl_extend("force", opts, { desc = "Toggle review note cards" }))
  vim.keymap.set("v", "a", function()
    local range = visual_range()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    prompt_annotation(range)
  end, vim.tbl_extend("force", opts, { desc = "Annotate selected lines" }))
  vim.keymap.set("n", "f", pick_file, vim.tbl_extend("force", opts, { desc = "Pick diff file" }))
  vim.keymap.set("n", "b", toggle_file_list, vim.tbl_extend("force", opts, { desc = "Toggle file list" }))
  vim.keymap.set("n", "c", M.pick, vim.tbl_extend("force", opts, { desc = "Change diff comparison" }))
  vim.keymap.set("n", "Q", set_quickfix, vim.tbl_extend("force", opts, { desc = "Open review notes quickfix" }))
  vim.keymap.set("n", "r", function() M.refresh() end, vim.tbl_extend("force", opts, { desc = "Refresh review diff" }))
end

map_list_buffer = function(buf)
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    select_file(row - 1)
    if valid_win(state.new_win) then
      vim.api.nvim_set_current_win(state.new_win)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open diff file" }))
  vim.keymap.set("n", "j", function()
    vim.cmd("normal! j")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row > 1 then
      select_file(row - 1)
    end
  end, opts)
  vim.keymap.set("n", "k", function()
    vim.cmd("normal! k")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row > 1 then
      select_file(row - 1)
    end
  end, opts)
  vim.keymap.set("n", "f", pick_file, vim.tbl_extend("force", opts, { desc = "Pick diff file" }))
  vim.keymap.set({ "n", "v" }, "b", toggle_file_list, vim.tbl_extend("force", opts, { desc = "Toggle file list" }))
  vim.keymap.set("n", "q", toggle_file_list, vim.tbl_extend("force", opts, { desc = "Hide file list" }))
end

create_scratch = function(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = filetype or ""
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

local function empty_source_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].bufhidden = ""
  vim.bo[buf].buftype = ""
  vim.bo[buf].modifiable = true
  return buf
end

local function close_stale_review_windows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if valid_win(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("Pi Review") then
        if #vim.api.nvim_list_wins() > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        else
          vim.api.nvim_win_set_buf(win, empty_source_buf())
        end
      end
    end
  end
end

local function restore_previous_source()
  if valid_win(state.previous_win) then
    if valid_buf(state.previous_buf) then
      vim.api.nvim_win_set_buf(state.previous_win, state.previous_buf)
    end
    vim.api.nvim_set_current_win(state.previous_win)
    return true
  end
  return false
end

local function close_extra_empty_buffers()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == "" and not vim.bo[buf].modified and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function reset_review_windows()
  clear_diff_windows()
  close_stale_review_windows()
  restore_previous_source()
  close_extra_empty_buffers()
  state.list_buf = nil
  state.old_buf = nil
  state.new_buf = nil
  state.list_win = nil
  state.old_win = nil
  state.new_win = nil
end

local function ensure_editor_space(_width)
  local win = source_win()
  if win then
    vim.api.nvim_set_current_win(win)
    return
  end

  vim.cmd("topleft vnew")
  local editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(editor_win, empty_source_buf())
end

local function ensure_windows()
  local previous = source_win()
  state.previous_win = previous
  state.previous_buf = previous and vim.api.nvim_win_get_buf(previous) or nil
  reset_review_windows()
  ensure_editor_space()

  state.old_buf = create_scratch("Pi Review OLD", "")
  vim.api.nvim_win_set_buf(0, state.old_buf)
  state.old_win = vim.api.nvim_get_current_win()

  vim.cmd("rightbelow vsplit")
  state.new_buf = create_scratch("Pi Review NEW", "")
  vim.api.nvim_win_set_buf(0, state.new_buf)
  state.new_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(state.old_win)
  vim.cmd("leftabove 28vsplit")
  state.list_buf = create_scratch("Pi Review Files", "piovim-review-files")
  vim.api.nvim_win_set_buf(0, state.list_buf)
  state.list_win = vim.api.nvim_get_current_win()

  map_list_buffer(state.list_buf)
  map_review_buffer(state.old_buf)
  map_review_buffer(state.new_buf)
  vim.api.nvim_set_current_win(state.new_win)
end

local function source_diff(source, root)
  if source.kind == "patch" then
    if not source.path or source.path == "" then
      return ""
    end
    return table.concat(vim.fn.readfile(vim.fn.fnamemodify(source.path, ":p")), "\n")
  end

  if source.kind == "pr" then
    if vim.fn.executable("gh") ~= 1 then
      error("gh CLI is required to review PRs")
    end
    local args = { "gh", "pr", "diff" }
    if source.input and source.input ~= "" then
      table.insert(args, source.input)
    end
    return system(args, { cwd = root })
  end

  local diff = git_output(source.args, root)
  if source.include_untracked then
    local extra = untracked_diff(root)
    if extra ~= "" then
      diff = diff ~= "" and (diff .. "\n" .. extra) or extra
    end
  end
  return diff
end

local function worktree_signature(root)
  local parts = { git_output({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }, root) }
  local files = git_output({ "ls-files", "-m", "-o", "--exclude-standard", "-z" }, root)
  for _, path in ipairs(vim.split(files, "\0", { plain = true, trimempty = true })) do
    local stat = vim.uv.fs_stat(root .. "/" .. path)
    if stat then
      table.insert(parts, path .. ":" .. tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size))
    end
  end
  return table.concat(parts, "\0")
end

local function source_signature(source, root)
  if not source or not source.watch then
    return nil
  end
  if source.kind == "patch" then
    local stat = source.path and vim.uv.fs_stat(vim.fn.fnamemodify(source.path, ":p"))
    return stat and (tostring(stat.mtime.sec) .. ":" .. tostring(stat.size)) or "missing"
  elseif source.kind == "working-tree" then
    return worktree_signature(root)
  elseif source.kind == "staged" then
    return git_output({ "diff", "--cached", "--raw" }, root)
  elseif source.kind == "commit" then
    return git_output({ "rev-parse", source.input }, root)
  elseif source.kind == "range" or source.kind == "branch" then
    return git_output({ "rev-parse", source.old_source or "HEAD" }, root) .. ":" .. git_output({ "rev-parse", source.new_source or "HEAD" }, root)
  end
  return source_diff(source, root)
end

local function stop_watch()
  if state.watch_timer then
    state.watch_timer:stop()
    state.watch_timer:close()
    state.watch_timer = nil
  end
  state.watch_signature = nil
end

local function start_watch()
  stop_watch()
  if not state.source or not state.source.watch then
    return
  end
  state.watch_signature = source_signature(state.source, state.root)
  state.watch_timer = vim.uv.new_timer()
  state.watch_timer:start(state.watch_interval_ms, state.watch_interval_ms, function()
    vim.schedule(function()
      if not state.source or not valid_win(state.new_win) then
        stop_watch()
        return
      end
      local ok, signature = pcall(source_signature, state.source, state.root)
      if not ok or signature == state.watch_signature then
        return
      end
      state.watch_signature = signature
      if state.interaction_active then
        state.pending_refresh = true
        return
      end
      M.refresh()
    end)
  end)
end

function M.open_source(source)
  state.root = state.root or git_root()
  prune_old_state_files()
  load_state(state.root)
  source = source or source_from("", state.root)
  local diff = source_diff(source, state.root)

  state.source = source
  state.comparison = source
  state.files = parse_diff(diff)
  if state.file_index > #state.files then
    state.file_index = 1
  end

  ensure_windows()
  render_list()
  render_file()
  M.resize_if_open()
  start_watch()
end

local function open_with_notice(label, callback)
  local ok, err = pcall(callback)
  if not ok then
    vim.notify("Pi review " .. label .. " failed: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

function M.open(input)
  return open_with_notice("diff", function()
    state.root = git_root()
    M.open_source(source_from(input or "", state.root))
  end)
end

function M.close()
  stop_watch()
  reset_review_windows()
  if not source_win() then
    ensure_editor_space()
  end
end

function M.refresh()
  if not state.source then
    return false
  end

  if state.interaction_active then
    state.pending_refresh = true
    return false
  end

  local selected_file = current_file()
  local selected_path = selected_file and selected_file.path or nil

  pcall(vim.cmd, "checktime")

  state.root = state.root or git_root()
  local diff = source_diff(state.source, state.root)

  state.comparison = state.source
  state.files = parse_diff(diff)
  state.file_index = 1
  if selected_path then
    for index, file in ipairs(state.files) do
      if file.path == selected_path then
        state.file_index = index
        break
      end
    end
  end

  render_list()
  render_file()
  if state.source and state.source.watch then
    local ok, signature = pcall(source_signature, state.source, state.root)
    if ok then
      state.watch_signature = signature
    end
  end
  return true
end

function M.refresh_if_open(path)
  if not state.comparison or not valid_win(state.new_win) then
    return false
  end

  if path then
    local abs = vim.fn.fnamemodify(path, ":p")
    local relevant = false
    for _, file in ipairs(state.files) do
      if vim.fn.fnamemodify(state.root .. "/" .. file.path, ":p") == abs then
        relevant = true
        break
      end
    end
    if not relevant then
      return false
    end
  end

  return M.refresh()
end

function M.open_commit(rev)
  return open_with_notice("commit", function()
    state.root = git_root()
    M.open_source(commit_source(rev or "HEAD", state.root))
  end)
end

function M.open_range(range)
  return open_with_notice("range", function()
    state.root = git_root()
    M.open_source(range_source(range, state.root))
  end)
end

function M.open_patch(path)
  return open_with_notice("patch", function()
    state.root = git_root()
    M.open_source(patch_source(path))
  end)
end

function M.open_pr(number)
  return open_with_notice("PR", function()
    state.root = git_root()
    M.open_source(pr_source(number))
  end)
end

local function pick_recent_commit()
  state.root = git_root()
  local output = git_output({ "log", "--oneline", "--decorate", "-n", "30" }, state.root)
  local choices = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    local sha = line:match("^(%S+)")
    if sha then
      table.insert(choices, { label = line, sha = sha })
    end
  end
  vim.ui.select(choices, { prompt = "Pi review commit", format_item = function(item) return item.label end }, function(choice)
    if choice then
      M.open_commit(choice.sha)
    end
  end)
end

local function open_last_commits()
  tracked_input({ prompt = "last N commits: ", default = "1" }, function(input)
    local count = tonumber(input)
    if count and count > 0 then
      M.open_range("HEAD~" .. tostring(math.floor(count)) .. "..HEAD")
    end
  end)
end

local function pick_two_refs()
  tracked_input({ prompt = "base ref: ", default = default_base_ref(state.root or git_root()) }, function(base)
    if not base or base == "" then
      return
    end
    tracked_input({ prompt = "head ref: ", default = "HEAD" }, function(head)
      if head and head ~= "" then
        M.open_range(base .. "..." .. head)
      end
    end)
  end)
end

local function pick_pr()
  if vim.fn.executable("gh") ~= 1 then
    tracked_input({ prompt = "PR number: " }, function(input)
      if input then
        M.open_pr(input)
      end
    end)
    return
  end

  state.root = git_root()
  local choices = {}
  local seen_prs = {}
  local current_ok, current_output = pcall(system, { "gh", "pr", "view", "--json", "number,title,headRefName" }, { cwd = state.root })
  if current_ok then
    local decoded_ok, pr = pcall(vim.json.decode, current_output)
    if decoded_ok and type(pr) == "table" and pr.number then
      local number = tostring(pr.number)
      seen_prs[number] = true
      table.insert(choices, {
        label = "Current branch PR: #" .. number .. " " .. tostring(pr.title or "") .. "  (" .. tostring(pr.headRefName or "") .. ")",
        number = number,
      })
    end
  end

  local ok, output = pcall(system, { "gh", "pr", "list", "--limit", "30", "--json", "number,title,headRefName" }, { cwd = state.root })
  if ok then
    local decoded_ok, prs = pcall(vim.json.decode, output)
    if decoded_ok and type(prs) == "table" then
      for _, pr in ipairs(prs) do
        local number = tostring(pr.number)
        if not seen_prs[number] then
          seen_prs[number] = true
          table.insert(choices, {
            label = "#" .. number .. " " .. tostring(pr.title or "") .. "  (" .. tostring(pr.headRefName or "") .. ")",
            number = number,
          })
        end
      end
    end
  end
  table.insert(choices, { label = "Enter PR number…", number = nil })

  vim.ui.select(choices, { prompt = "Pi review PR", format_item = function(item) return item.label end }, function(choice)
    if not choice then
      return
    end
    if choice.number == nil then
      tracked_input({ prompt = "PR number: " }, function(input)
        if input then
          M.open_pr(input)
        end
      end)
    else
      M.open_pr(choice.number)
    end
  end)
end

function M.pick()
  state.root = state.root or git_root()
  local choices = {
    { label = "Working tree", value = "working-tree" },
    { label = "Staged changes", value = "staged" },
    { label = "Current branch vs " .. default_base_ref(state.root), value = "branch" },
    { label = "GitHub PR", value = "pr" },
    { label = "Last N commits", value = "last" },
    { label = "Recent commit", value = "commit" },
    { label = "Commit range", value = "range" },
    { label = "Pick base/head refs", value = "refs" },
    { label = "Patch file", value = "patch" },
    { label = "Custom git diff args", value = "custom" },
  }
  vim.ui.select(choices, { prompt = "Pi review source", format_item = function(item) return item.label end }, function(choice)
    if not choice then
      return
    end
    if choice.value == "custom" then
      tracked_input({ prompt = "git diff args: " }, function(input)
        if input then
          M.open(input)
        end
      end)
    elseif choice.value == "commit" then
      pick_recent_commit()
    elseif choice.value == "last" then
      open_last_commits()
    elseif choice.value == "refs" then
      pick_two_refs()
    elseif choice.value == "pr" then
      pick_pr()
    elseif choice.value == "range" then
      tracked_input({ prompt = "commit range: ", default = default_base_ref(state.root or git_root()) .. "...HEAD" }, function(input)
        if input then
          M.open_range(input)
        end
      end)
    elseif choice.value == "patch" then
      tracked_input({ prompt = "patch file: ", completion = "file" }, function(input)
        if input and input ~= "" then
          M.open_patch(input)
        end
      end)
    elseif choice.value == "branch" then
      M.open_range(default_base_ref(state.root or git_root()) .. "...HEAD")
    else
      M.open(choice.value)
    end
  end)
end

function M.add_annotation(params)
  params = params or {}
  return add_annotation(params.note, params.range)
end

function M.resolve_annotation(params)
  params = params or {}
  local id = tonumber(params.id)
  local path = params.path
  local line = tonumber(params.line)
  local removed = nil

  for key, notes in pairs(state.annotations) do
    for index = #notes, 1, -1 do
      local note = notes[index]
      local matches_id = id and note.id == id
      local matches_location = not id and path and line and note.path == path and note.line == line
      if matches_id or matches_location then
        removed = table.remove(notes, index)
        if #notes == 0 then
          state.annotations[key] = nil
        end
        save_state()
        render_list()
        render_annotations()
        return { resolved = true, annotation = removed }
      end
    end
  end

  return { resolved = false }
end

function M.summary()
  local lines = {
    "Please apply the active Pi review diff notes.",
    "",
    "Instructions:",
    "- Read the active review diff and annotations.",
    "- Fix each annotation with minimal code changes.",
    "- Prefer nvim_edit_buffer for files open in Neovim so the review diff refreshes live.",
    "- Save edited buffers when the user explicitly asked for /apply from the review flow.",
    "- After fixing a note, call nvim_resolve_review_annotation with its id.",
    "- Refresh/check the diff when done and report any unresolved notes.",
    "",
    "Review context:",
    vim.json.encode(M.get_context()),
  }
  return table.concat(lines, "\n")
end

function M.get_context()
  local file = current_file()
  local range = current_range()
  local annotations = {}
  for _, notes in pairs(state.annotations) do
    for _, note in ipairs(notes) do
      table.insert(annotations, note)
    end
  end

  local current_hunk = nil
  if range and file then
    for _, hunk in ipairs(file.hunks) do
      local hunk_end = hunk.new_start + math.max(0, hunk.new_count - 1)
      if range.line >= hunk.new_start and range.line <= hunk_end then
        current_hunk = hunk
        break
      end
    end
  end

  return {
    root = state.root,
    comparison = state.comparison and state.comparison.label or nil,
    source = state.source and { kind = state.source.kind, label = state.source.label, input = state.source.input } or nil,
    files = vim.tbl_map(function(item)
      return {
        path = item.path,
        old_path = item.old_path,
        status = file_status(item),
        hunks = #item.hunks,
        large = item.large == true,
        omitted = item.omitted == true,
        omitted_reason = item.omitted_reason,
      }
    end, state.files),
    current_file = file and file.path or nil,
    current_range = range,
    current_hunk = current_hunk,
    annotations = annotations,
  }
end

local autocmds_ready = false
local refresh_timer = nil

local function schedule_refresh_for_path(path)
  if not path or path == "" or not state.comparison or not valid_win(state.new_win) then
    return
  end

  local abs = vim.fn.fnamemodify(path, ":p")
  local relevant = false
  for _, file in ipairs(state.files) do
    if vim.fn.fnamemodify(state.root .. "/" .. file.path, ":p") == abs then
      relevant = true
      break
    end
  end
  if not relevant then
    return
  end

  if refresh_timer then
    refresh_timer:stop()
  else
    refresh_timer = vim.uv.new_timer()
  end

  refresh_timer:start(80, 0, function()
    vim.schedule(function()
      if state.comparison and valid_win(state.new_win) then
        M.refresh()
      end
    end)
  end)
end

local function setup_autocmds()
  if autocmds_ready then
    return
  end
  autocmds_ready = true

  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("piovim-review-diff", { clear = true }),
    callback = function(event)
      local ft = vim.bo[event.buf].filetype
      if ft:match("^piovim%-") then
        return
      end
      schedule_refresh_for_path(vim.api.nvim_buf_get_name(event.buf))
    end,
  })
end

function M.setup(opts)
  opts = opts or {}
  if opts.default_base ~= nil then
    default_base_override = opts.default_base
  end
  if opts.watch_interval_ms ~= nil then
    state.watch_interval_ms = tonumber(opts.watch_interval_ms) or state.watch_interval_ms
  end
  if opts.large_line_threshold ~= nil then
    large_line_threshold = tonumber(opts.large_line_threshold) or large_line_threshold
  end
  if opts.omit_line_threshold ~= nil then
    omit_line_threshold = tonumber(opts.omit_line_threshold) or omit_line_threshold
  end
  if opts.max_untracked_file_bytes ~= nil then
    max_untracked_file_bytes = tonumber(opts.max_untracked_file_bytes) or max_untracked_file_bytes
  end
end

M._test = {
  parse_diff = parse_diff,
  file_status = file_status,
  source_from = source_from,
  commit_source = commit_source,
  range_source = range_source,
  patch_source = patch_source,
  pr_source = pr_source,
  split_args = split_args,
  apply_large_safeguard = apply_large_safeguard,
  large_line_threshold = large_line_threshold,
  omit_line_threshold = omit_line_threshold,
}

function M.setup_commands()
  setup_autocmds()
  vim.api.nvim_create_user_command("PiovimReviewDiff", function(opts)
    if opts.args == "" then
      M.pick()
    else
      M.open(opts.args)
    end
  end, {
    desc = "Open Pi review diff",
    nargs = "*",
    force = true,
    complete = function()
      return { "working-tree", "staged", "main", "origin/main", "branch", "pr", "pr ", "HEAD~1..HEAD", "origin/main...HEAD" }
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufModifiedSet" }, {
    group = vim.api.nvim_create_augroup("piovim-review-locks", { clear = true }),
    pattern = "Pi Review*",
    callback = function(event)
      lock_review_buf(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = vim.api.nvim_create_augroup("piovim-review-write-guard", { clear = true }),
    pattern = "Pi Review*",
    callback = function()
      vim.notify("Pi review buffers are read-only; edit the source file and refresh the diff", vim.log.levels.WARN)
    end,
  })

  vim.api.nvim_create_user_command("PiovimReviewCommit", function(opts)
    if opts.args == "" then
      pick_recent_commit()
    else
      M.open_commit(opts.args)
    end
  end, { desc = "Open Pi review for a commit", nargs = "?", force = true })

  vim.api.nvim_create_user_command("PiovimReviewRange", function(opts)
    if opts.args == "" then
      M.open_range()
    else
      M.open_range(opts.args)
    end
  end, { desc = "Open Pi review for a commit range", nargs = "?", force = true })

  vim.api.nvim_create_user_command("PiovimReviewPatch", function(opts)
    if opts.args == "" then
      M.pick()
    else
      M.open_patch(opts.args)
    end
  end, { desc = "Open Pi review for a patch file", nargs = "?", complete = "file", force = true })

  vim.api.nvim_create_user_command("PiovimReviewPR", function(opts)
    M.open_pr(opts.args)
  end, { desc = "Open Pi review for a GitHub PR via gh", nargs = "?", force = true })

  vim.api.nvim_create_user_command("PiovimReviewFiles", pick_file, { desc = "Pick Pi review file", force = true })
  vim.api.nvim_create_user_command("PiovimReviewToggleFiles", toggle_file_list, { desc = "Toggle Pi review file list", force = true })
  vim.api.nvim_create_user_command("PiovimReviewClose", M.close, { desc = "Close Pi review diff", force = true })
  vim.api.nvim_create_user_command("PiovimReviewRefresh", M.refresh, { desc = "Refresh Pi review diff", force = true })
  vim.api.nvim_create_user_command("PiovimReviewEditNote", edit_current_annotation, { desc = "Edit current Pi review note", force = true })
  vim.api.nvim_create_user_command("PiovimReviewDeleteNote", delete_current_annotation, { desc = "Delete current Pi review note", force = true })
  vim.api.nvim_create_user_command("PiovimReviewNotes", set_quickfix, { desc = "Open Pi review notes quickfix", force = true })
end

return M
