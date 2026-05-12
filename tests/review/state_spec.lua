describe("review.state note indexes", function()
  local state
  local original_state_module
  local original_storage_module

  before_each(function()
    original_state_module = package.loaded["review.state"]
    original_storage_module = package.loaded["review.storage"]

    package.loaded["review.state"] = nil
    package.loaded["review.storage"] = {
      load = function()
        return {}
      end,
      save = function() end,
    }

    state = require("review.state")
    state.create("local", "HEAD", {})
  end)

  after_each(function()
    if state then
      state.destroy()
    end
    package.loaded["review.state"] = original_state_module
    package.loaded["review.storage"] = original_storage_module
  end)

  it("indexes notes by file, id, and location", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    state.add_note("lua/review.lua", 18, "second", nil, "old")
    state.add_note("README.md", 5, "third", nil, "new")

    local file_notes = state.get_notes("lua/review.lua")
    assert.are.equal(2, #file_notes)
    assert.are.equal("first", file_notes[1].body)
    assert.are.equal("second", file_notes[2].body)

    local note, idx = state.find_note_at("lua/review.lua", 18, "old")
    assert.are.equal("second", note.body)
    assert.are.equal(2, idx)

    local by_id, by_id_idx = state.get_note_by_id(file_notes[1].id)
    assert.are.equal("first", by_id.body)
    assert.are.equal(1, by_id_idx)
  end)

  it("rebuilds indexes after note removal", function()
    state.add_note("lua/review.lua", 12, "first", nil, "new")
    state.add_note("lua/review.lua", 18, "second", nil, "old")

    state.remove_note(1)

    local missing = state.find_note_at("lua/review.lua", 12, "new")
    assert.is_nil(missing)

    local note, idx = state.find_note_at("lua/review.lua", 18, "old")
    assert.are.equal("second", note.body)
    assert.are.equal(1, idx)
    assert.are.equal(1, #state.get_notes("lua/review.lua"))
  end)

  it("clears all local notes while preserving remote comments", function()
    state.add_note("lua/review.lua", 12, "draft", nil, "new")
    state.add_note("lua/review.lua", 18, "staged", nil, "new")
    local staged = state.get_notes("lua/review.lua")[2]
    state.toggle_staged(staged.id)
    state.load_remote_comments({
      {
        file_path = "lua/ui.lua",
        line = 4,
        side = "new",
        replies = {
          { body = "remote", author = "octocat" },
        },
        resolved = false,
      },
    })

    assert.are.equal(2, state.local_note_count())

    local cleared = state.clear_local_notes()
    assert.are.equal(2, cleared)
    assert.are.equal(0, state.local_note_count())
    assert.are.equal(1, #state.get_notes())
    assert.are.equal("remote", state.get_notes()[1].status)
  end)
end)
