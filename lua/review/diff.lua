--- Pure unified diff parser — no I/O, fully testable.
local M = {}

--- Parse a unified diff header line like "@@ -1,3 +1,4 @@" or "@@ -0,0 +1,25 @@"
---@param header string
---@return number old_start, number old_count, number new_start, number new_count
local function parse_hunk_header(header)
  local old_start, old_count, new_start, new_count = header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then
    return 0, 0, 0, 0
  end
  old_start = tonumber(old_start)
  old_count = tonumber(old_count) or 1
  new_start = tonumber(new_start)
  new_count = tonumber(new_count) or 1
  return old_start, old_count, new_start, new_count
end

--- Parse unified diff text into structured file/hunk/line data.
---@param diff_text string  Raw output of `git diff` or `git diff --no-index`
---@return ReviewFile[]
function M.parse(diff_text)
  if not diff_text or diff_text == "" then
    return {}
  end

  ---@type ReviewFile[]
  local files = {}
  ---@type ReviewFile|nil
  local current_file = nil
  ---@type ReviewHunk|nil
  local current_hunk = nil
  local old_lnum = 0
  local new_lnum = 0

  for raw_line in (diff_text .. "\n"):gmatch("(.-)\n") do
    -- New file diff header: "diff --git a/foo b/foo"
    if raw_line:match("^diff %-%-git ") then
      current_file = {
        path = "",
        status = "M",
        hunks = {},
      }
      current_hunk = nil
      table.insert(files, current_file)

    -- Extract file path from +++ line (new file side)
    elseif raw_line:match("^%+%+%+ ") and current_file then
      local path = raw_line:match("^%+%+%+ b/(.+)") or raw_line:match("^%+%+%+ (.+)")
      if path and path ~= "/dev/null" then
        current_file.path = path
      end

    -- Extract file path from --- line (old file side, for deletions)
    elseif raw_line:match("^%-%-%- ") and current_file then
      -- Only use --- path if we don't have one yet (deleted files have +++ /dev/null)
      local path = raw_line:match("^%-%-%- a/(.+)") or raw_line:match("^%-%-%- (.+)")
      if path and path ~= "/dev/null" and current_file.path == "" then
        current_file.path = path
      end

    -- Detect new file
    elseif raw_line:match("^new file mode") and current_file then
      current_file.status = "A"

    -- Detect deleted file
    elseif raw_line:match("^deleted file mode") and current_file then
      current_file.status = "D"

    -- Detect rename
    elseif raw_line:match("^rename from ") and current_file then
      current_file.status = "R"

    -- Hunk header
    elseif raw_line:match("^@@") and current_file then
      local os, oc, ns, nc = parse_hunk_header(raw_line)
      current_hunk = {
        header = raw_line,
        old_start = os,
        old_count = oc,
        new_start = ns,
        new_count = nc,
        lines = {},
      }
      old_lnum = os
      new_lnum = ns
      table.insert(current_file.hunks, current_hunk)

    -- Diff content lines (only inside a hunk)
    elseif current_hunk then
      local prefix = raw_line:sub(1, 1)
      local text = raw_line:sub(2)

      if prefix == "+" then
        table.insert(current_hunk.lines, {
          type = "add",
          text = text,
          old_lnum = nil,
          new_lnum = new_lnum,
        })
        new_lnum = new_lnum + 1
      elseif prefix == "-" then
        table.insert(current_hunk.lines, {
          type = "del",
          text = text,
          old_lnum = old_lnum,
          new_lnum = nil,
        })
        old_lnum = old_lnum + 1
      elseif prefix == " " or prefix == "" then
        -- Context line
        table.insert(current_hunk.lines, {
          type = "ctx",
          text = text,
          old_lnum = old_lnum,
          new_lnum = new_lnum,
        })
        old_lnum = old_lnum + 1
        new_lnum = new_lnum + 1
      end
      -- Skip \ No newline at end of file and other noise
    end
  end

  -- Fix paths for deleted files (--- a/foo, +++ /dev/null)
  for _, file in ipairs(files) do
    if file.path == "" then
      -- Try to extract from the diff --git line stored nowhere...
      -- This shouldn't happen if the diff is well-formed, but as a safety net:
      file.path = "unknown"
    end
  end

  return files
end

--- Build bidirectional line mappings for a file's hunks.
--- Maps display line numbers to source (old/new) line numbers and back.
---@param hunks ReviewHunk[]
---@return table display_to_new  Map from display line -> new file line number
---@return table display_to_old  Map from display line -> old file line number
---@return table new_to_display  Map from new file line -> display line
---@return table old_to_display  Map from old file line -> display line
function M.build_line_map(hunks)
  local display_to_new = {}
  local display_to_old = {}
  local new_to_display = {}
  local old_to_display = {}
  local display_line = 0

  for _, hunk in ipairs(hunks) do
    -- Hunk header takes a display line
    display_line = display_line + 1
    -- Don't map the header line to source

    for _, line in ipairs(hunk.lines) do
      display_line = display_line + 1
      if line.new_lnum then
        display_to_new[display_line] = line.new_lnum
        new_to_display[line.new_lnum] = display_line
      end
      if line.old_lnum then
        display_to_old[display_line] = line.old_lnum
        old_to_display[line.old_lnum] = display_line
      end
    end
  end

  return display_to_new, display_to_old, new_to_display, old_to_display
end

--- Compute word-level diff between two strings.
--- Returns highlight ranges for the changed portions.
---@param old_str string
---@param new_str string
---@return table[] old_ranges  Each: {col_start, col_end} (0-indexed, exclusive end)
---@return table[] new_ranges  Each: {col_start, col_end}
function M.word_diff(old_str, new_str)
  if not old_str or not new_str then
    return {}, {}
  end

  -- Safety: skip very long lines
  if #old_str > 500 or #new_str > 500 then
    return { { 0, #old_str } }, { { 0, #new_str } }
  end

  -- Find common prefix
  local prefix_len = 0
  local min_len = math.min(#old_str, #new_str)
  for i = 1, min_len do
    if old_str:byte(i) == new_str:byte(i) then
      prefix_len = i
    else
      break
    end
  end

  -- Find common suffix (don't overlap with prefix)
  local suffix_len = 0
  for i = 0, min_len - prefix_len - 1 do
    if old_str:byte(#old_str - i) == new_str:byte(#new_str - i) then
      suffix_len = i + 1
    else
      break
    end
  end

  local old_start = prefix_len
  local old_end = #old_str - suffix_len
  local new_start = prefix_len
  local new_end = #new_str - suffix_len

  local old_ranges = {}
  local new_ranges = {}

  if old_end > old_start then
    table.insert(old_ranges, { old_start, old_end })
  end
  if new_end > new_start then
    table.insert(new_ranges, { new_start, new_end })
  end

  return old_ranges, new_ranges
end

--- Pair up consecutive del/add lines in a hunk for word-level diffing.
--- Returns a list of {del_idx, add_idx} pairs (1-indexed into hunk.lines).
---@param hunk ReviewHunk
---@return table[] pairs  Each: {del_idx, add_idx}
function M.pair_changed_lines(hunk)
  local pairs_list = {}
  local i = 1
  while i <= #hunk.lines do
    if hunk.lines[i].type == "del" then
      -- Collect consecutive deletions
      local del_start = i
      while i <= #hunk.lines and hunk.lines[i].type == "del" do
        i = i + 1
      end
      local del_end = i - 1

      -- Collect consecutive additions
      local add_start = i
      while i <= #hunk.lines and hunk.lines[i].type == "add" do
        i = i + 1
      end
      local add_end = i - 1

      -- Pair them up 1:1 as far as possible
      local num_pairs = math.min(del_end - del_start + 1, add_end - add_start + 1)
      for j = 0, num_pairs - 1 do
        table.insert(pairs_list, { del_start + j, add_start + j })
      end
    else
      i = i + 1
    end
  end
  return pairs_list
end

return M
