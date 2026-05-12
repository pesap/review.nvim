local diff = require("review.diff")

describe("diff parser", function()
  it("returns empty table for empty input", function()
    assert.are.same({}, diff.parse(""))
    assert.are.same({}, diff.parse(nil))
  end)

  it("parses a single modified file", function()
    local input = [[
diff --git a/hello.lua b/hello.lua
index 1234567..abcdefg 100644
--- a/hello.lua
+++ b/hello.lua
@@ -1,3 +1,4 @@
 local M = {}
-M.greet = "hello"
+M.greet = "hi"
+M.farewell = "bye"
 return M]]

    local files = diff.parse(input)
    assert.are.equal(1, #files)
    assert.are.equal("hello.lua", files[1].path)
    assert.are.equal("M", files[1].status)
    assert.are.equal(1, #files[1].hunks)

    local hunk = files[1].hunks[1]
    assert.are.equal(1, hunk.old_start)
    assert.are.equal(3, hunk.old_count)
    assert.are.equal(1, hunk.new_start)
    assert.are.equal(4, hunk.new_count)
    assert.are.equal(5, #hunk.lines)

    -- Context line
    assert.are.equal("ctx", hunk.lines[1].type)
    assert.are.equal("local M = {}", hunk.lines[1].text)
    assert.are.equal(1, hunk.lines[1].old_lnum)
    assert.are.equal(1, hunk.lines[1].new_lnum)

    -- Deleted line
    assert.are.equal("del", hunk.lines[2].type)
    assert.are.equal('M.greet = "hello"', hunk.lines[2].text)
    assert.are.equal(2, hunk.lines[2].old_lnum)
    assert.is_nil(hunk.lines[2].new_lnum)

    -- Added lines
    assert.are.equal("add", hunk.lines[3].type)
    assert.are.equal('M.greet = "hi"', hunk.lines[3].text)
    assert.is_nil(hunk.lines[3].old_lnum)
    assert.are.equal(2, hunk.lines[3].new_lnum)

    assert.are.equal("add", hunk.lines[4].type)
    assert.are.equal('M.farewell = "bye"', hunk.lines[4].text)
    assert.are.equal(3, hunk.lines[4].new_lnum)

    -- Context line
    assert.are.equal("ctx", hunk.lines[5].type)
    assert.are.equal("return M", hunk.lines[5].text)
  end)

  it("parses a new file", function()
    local input = [[
diff --git a/new.lua b/new.lua
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/new.lua
@@ -0,0 +1,2 @@
+local M = {}
+return M]]

    local files = diff.parse(input)
    assert.are.equal(1, #files)
    assert.are.equal("new.lua", files[1].path)
    assert.are.equal("A", files[1].status)
    assert.are.equal(1, #files[1].hunks)
    assert.are.equal(2, #files[1].hunks[1].lines)
    assert.are.equal("add", files[1].hunks[1].lines[1].type)
  end)

  it("parses a deleted file", function()
    local input = [[
diff --git a/old.lua b/old.lua
deleted file mode 100644
index 1234567..0000000
--- a/old.lua
+++ /dev/null
@@ -1,2 +0,0 @@
-local M = {}
-return M]]

    local files = diff.parse(input)
    assert.are.equal(1, #files)
    assert.are.equal("old.lua", files[1].path)
    assert.are.equal("D", files[1].status)
    assert.are.equal(2, #files[1].hunks[1].lines)
    assert.are.equal("del", files[1].hunks[1].lines[1].type)
  end)

  it("parses multiple files", function()
    local input = [[
diff --git a/a.lua b/a.lua
index 1234567..abcdefg 100644
--- a/a.lua
+++ b/a.lua
@@ -1,1 +1,1 @@
-old
+new
diff --git a/b.lua b/b.lua
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/b.lua
@@ -0,0 +1,1 @@
+hello]]

    local files = diff.parse(input)
    assert.are.equal(2, #files)
    assert.are.equal("a.lua", files[1].path)
    assert.are.equal("M", files[1].status)
    assert.are.equal("b.lua", files[2].path)
    assert.are.equal("A", files[2].status)
  end)

  it("does not create a phantom context line for trailing newline", function()
    local input = "diff --git a/a.lua b/a.lua\n"
      .. "--- a/a.lua\n"
      .. "+++ b/a.lua\n"
      .. "@@ -1 +1 @@\n"
      .. "-old\n"
      .. "+new\n"

    local files = diff.parse(input)
    assert.are.equal(1, #files)
    assert.are.equal(2, #files[1].hunks[1].lines)
    assert.are.equal("del", files[1].hunks[1].lines[1].type)
    assert.are.equal("add", files[1].hunks[1].lines[2].type)
  end)

  it("parses multiple hunks in one file", function()
    local input = [[
diff --git a/multi.lua b/multi.lua
index 1234567..abcdefg 100644
--- a/multi.lua
+++ b/multi.lua
@@ -1,3 +1,3 @@
 line1
-line2
+line2_modified
 line3
@@ -10,3 +10,3 @@
 line10
-line11
+line11_modified
 line12]]

    local files = diff.parse(input)
    assert.are.equal(1, #files)
    assert.are.equal(2, #files[1].hunks)

    assert.are.equal(1, files[1].hunks[1].old_start)
    assert.are.equal(10, files[1].hunks[2].old_start)
  end)

  it("builds correct line maps", function()
    local input = [[
diff --git a/test.lua b/test.lua
index 1234567..abcdefg 100644
--- a/test.lua
+++ b/test.lua
@@ -1,3 +1,4 @@
 local M = {}
-M.old = true
+M.new = true
+M.extra = true
 return M]]

    local files = diff.parse(input)
    local dn, do_, ntd, otd = diff.build_line_map(files[1].hunks)

    -- Display line 1 = hunk header (no mapping)
    assert.is_nil(dn[1])
    assert.is_nil(do_[1])

    -- Display line 2 = context "local M = {}" -> old:1, new:1
    assert.are.equal(1, dn[2])
    assert.are.equal(1, do_[2])

    -- Display line 3 = del "M.old = true" -> old:2, no new
    assert.is_nil(dn[3])
    assert.are.equal(2, do_[3])

    -- Display line 4 = add "M.new = true" -> new:2, no old
    assert.are.equal(2, dn[4])
    assert.is_nil(do_[4])

    -- Display line 5 = add "M.extra = true" -> new:3, no old
    assert.are.equal(3, dn[5])

    -- Display line 6 = context "return M" -> old:3, new:4
    assert.are.equal(4, dn[6])
    assert.are.equal(3, do_[6])

    -- Reverse maps
    assert.are.equal(2, ntd[1]) -- new line 1 -> display 2
    assert.are.equal(4, ntd[2]) -- new line 2 -> display 4
    assert.are.equal(2, otd[1]) -- old line 1 -> display 2
    assert.are.equal(3, otd[2]) -- old line 2 -> display 3
  end)
end)

describe("word diff", function()
  it("finds changed portion in modified line", function()
    local old_r, new_r = diff.word_diff('M.greet = "hello"', 'M.greet = "hi"')
    -- "hello" vs "hi" — common prefix is 'M.greet = "h' (12 chars)
    -- common suffix is '"' (1 char)
    assert.are.equal(1, #old_r)
    assert.are.equal(12, old_r[1][1]) -- start after 'h'
    assert.are.equal(16, old_r[1][2]) -- end before closing quote
    assert.are.equal(1, #new_r)
    assert.are.equal(12, new_r[1][1])
    assert.are.equal(13, new_r[1][2])
  end)

  it("returns empty ranges for identical strings", function()
    local old_r, new_r = diff.word_diff("same", "same")
    assert.are.equal(0, #old_r)
    assert.are.equal(0, #new_r)
  end)

  it("handles completely different strings", function()
    local old_r, new_r = diff.word_diff("abc", "xyz")
    assert.are.equal(1, #old_r)
    assert.are.equal(0, old_r[1][1])
    assert.are.equal(3, old_r[1][2])
  end)

  it("skips word ranges when max_line_length is exceeded", function()
    local old_r, new_r = diff.word_diff(string.rep("a", 40), string.rep("b", 40), {
      max_line_length = 32,
    })
    assert.are.same({}, old_r)
    assert.are.same({}, new_r)
  end)

  it("pairs consecutive del/add lines", function()
    local hunk = {
      header = "@@ -1,3 +1,3 @@",
      old_start = 1,
      old_count = 3,
      new_start = 1,
      new_count = 3,
      lines = {
        { type = "ctx", text = "context", old_lnum = 1, new_lnum = 1 },
        { type = "del", text = "old1", old_lnum = 2 },
        { type = "del", text = "old2", old_lnum = 3 },
        { type = "add", text = "new1", new_lnum = 2 },
        { type = "add", text = "new2", new_lnum = 3 },
      },
    }
    local pairs_list = diff.pair_changed_lines(hunk)
    assert.are.equal(2, #pairs_list)
    assert.are.equal(2, pairs_list[1][1]) -- del idx
    assert.are.equal(4, pairs_list[1][2]) -- add idx
    assert.are.equal(3, pairs_list[2][1])
    assert.are.equal(5, pairs_list[2][2])
  end)
end)
