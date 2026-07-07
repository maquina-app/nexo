# frozen_string_literal: true

require "test_helper"

class ToolsWebSearchTest < Minitest::Test
  # A real stub backend (not a mock): returns canned rows, records calls.
  class StubBackend
    attr_reader :queries

    def initialize(rows) = (@rows = rows
                            @queries = [])

    def search(query, **_) = (@queries << query
                              @rows)
  end

  def tool(mode: :auto, allow: %i[read glob search], rows: [])
    Nexo::Tools::WebSearch.new(
      sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: Nexo::Permissions.new(mode: mode, allow: allow),
      backend: StubBackend.new(rows)
    )
  end

  def test_denied_under_read_only_without_calling_backend
    backend = StubBackend.new([])
    t = Nexo::Tools::WebSearch.new(sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: Nexo::Permissions.new(mode: :read_only, allow: %i[read glob]), backend: backend)
    assert t.execute(query: "x")[:error]
    assert_empty backend.queries # gate ran before the backend
  end

  def test_allowed_returns_normalized_capped_results
    rows = (1..20).map { |i| {title: "T#{i}", url: "https://e/#{i}", snippet: "s" * 500} }
    r = tool(rows: rows).execute(query: "news")
    assert_equal 8, r[:results].size # MAX_RESULTS
    assert_equal 300, r[:results].first[:snippet].length # MAX_SNIPPET
    assert_equal "T1", r[:results].first[:title]
  end

  def test_raising_backend_returns_error
    bad = Object.new.tap { |o| def o.search(*) = raise("boom") }
    t = Nexo::Tools::WebSearch.new(sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: Nexo::Permissions.new(mode: :auto), backend: bad)
    assert_match(/search failed/, t.execute(query: "x")[:error])
  end
end
