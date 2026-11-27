# frozen_string_literal: true

# Verification example — Spec 19 (WebSearch). Search for stories, fetch the top
# hits, summarize.
#
# :search and :fetch are BOTH default-denied capabilities, so the agent runs with
# an explicit grant of each. WebSearch discovers URLs through a host-injected
# backend; Fetch reads the allow-listed hosts. Nexo ships NO search backend — the
# host injects one where marked below.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/news_search.rb
#
# Nothing provider-specific: set NEXO_MODEL to any ruby_llm-supported model.
require "nexo"
require_relative "support/model"

# A stand-in search backend: it answers every query with the same three pages.
class StaticIndex
  PAGES = [
    {title: "Hacker News front page", url: "https://hnrss.org/frontpage", snippet: "Today's most discussed technology stories."},
    {title: "NPR text-only", url: "https://text.npr.org/", snippet: "Top US and world news, text only."},
    {title: "CNN Lite", url: "https://lite.cnn.com/", snippet: "Latest headlines, text only."}
  ].freeze

  def search(_query) = PAGES
end

class NewsSearch < Nexo::Agent
  Examples.model(self)

  # :search + :fetch are default-denied (like :shell). Grant both explicitly.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch search])

  # Nexo ships NO backend: a search provider is yours to choose. A backend is any
  # object responding to `search(query) -> [{title:, url:, snippet:}]`. This one
  # is a stand-in so the example runs; replace it with an adapter for a real
  # provider, e.g. `search_backend YourAdapter.new(ENV.fetch("SEARCH_API_KEY"))`.
  search_backend StaticIndex.new

  fetch_allow %w[lite.cnn.com text.npr.org hnrss.org]

  skills "news-summary" # teaches WHICH sites + HOW to summarize (examples/skills/news-summary)

  instructions <<~TXT
    Use the search tool to discover today's top stories, then fetch the most relevant
    allow-listed URLs and summarize them, following the attached skill. If a search or
    fetch is denied, do not retry it — summarize what you could read.
  TXT
end

Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  summary = NewsSearch.new.prompt("Search for and summarize today's top stories.")
  puts summary.content
end
