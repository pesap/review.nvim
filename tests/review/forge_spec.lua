local forge = require("review.forge")

describe("review.forge remote summaries", function()
  it("extracts GitHub approvals and timeline events separately from comments", function()
    local raw = vim.fn.json_encode({
      data = {
        repository = {
          pullRequest = {
            reviewThreads = { nodes = {} },
            comments = { nodes = {} },
            reviews = {
              nodes = {
                {
                  databaseId = 11,
                  body = "looks good",
                  state = "APPROVED",
                  author = { login = "alice" },
                  url = "https://example.test/review/11",
                  createdAt = "2026-05-11T10:00:00Z",
                },
                {
                  databaseId = 12,
                  body = "",
                  state = "CHANGES_REQUESTED",
                  author = { login = "bob" },
                  url = "https://example.test/review/12",
                  createdAt = "2026-05-11T11:00:00Z",
                },
              },
            },
            timelineItems = {
              nodes = {
                {
                  __typename = "LabeledEvent",
                  createdAt = "2026-05-11T12:00:00Z",
                  actor = { login = "carol" },
                  label = { name = "needs-review" },
                },
                {
                  __typename = "ReviewRequestedEvent",
                  createdAt = "2026-05-11T13:00:00Z",
                  actor = { login = "dana" },
                  requestedReviewer = { login = "erin" },
                },
              },
            },
          },
        },
      },
    })

    local comments, err, summary = forge._parse_github_threads(raw)

    assert.is_nil(err)
    assert.are.equal(1, #comments)
    assert.are.equal("[approved] looks good", comments[1].replies[1].body)
    assert.are.equal(1, #summary.approvals)
    assert.are.equal("alice", summary.approvals[1].author)
    assert.are.equal(1, #summary.changes_requested)
    assert.are.equal("bob", summary.changes_requested[1].author)
    assert.are.equal("labeled needs-review", summary.timeline[1].label)
    assert.are.equal("requested review from erin", summary.timeline[2].label)
  end)

  it("extracts GitLab system notes as timeline context", function()
    local raw = vim.fn.json_encode({
      {
        id = "disc-1",
        notes = {
          {
            id = 1,
            body = "marked this merge request as ready",
            system = true,
            created_at = "2026-05-11T10:00:00Z",
            author = { username = "alice" },
          },
        },
      },
      {
        id = "disc-2",
        notes = {
          {
            id = 2,
            body = "general discussion",
            system = false,
            web_url = "https://example.test/mr/1#note_2",
            created_at = "2026-05-11T11:00:00Z",
            author = { username = "bob" },
          },
        },
      },
    })

    local comments, err, summary = forge._parse_gitlab_discussions(raw)

    assert.is_nil(err)
    assert.are.equal(1, #comments)
    assert.are.equal("general discussion", comments[1].replies[1].body)
    assert.are.equal(1, #summary.timeline)
    assert.are.equal("marked this merge request as ready", summary.timeline[1].label)
    assert.are.equal("alice", summary.timeline[1].actor)
  end)
end)
