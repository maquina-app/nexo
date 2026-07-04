# frozen_string_literal: true

# Verification example — Spec 9 (Web-Content Capability). Use case #3: news summary.
#
# The agent may fetch ONLY the allow-listed hosts (SSRF/egress guard). :fetch is a
# default-denied capability, so the agent runs with an explicit fetch grant.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b ruby -Ilib examples/news_summary.rb
#
# Nothing provider-specific: set NEXO_MODEL to any ruby_llm-supported model.
require "nexo"

class NewsSummary < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")

  # :fetch is default-denied (like :shell). Grant it explicitly + scope hosts tightly.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
  fetch_allow %w[hnrss.org lite.cnn.com text.npr.org]

  skills :news_summary # teaches WHICH sites + HOW to summarize (examples/skills/news_summary)

  instructions <<~TXT
    You summarize current news from the allow-listed sites using the fetch tool, following
    the attached skill. If a fetch is denied, do not retry it — summarize what you could read.
  TXT
end

Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  summary = NewsSummary.new.prompt("Summarize today's top stories from the allowed sites.")
  puts summary.content
  # In the full Task (Spec 8) this runs inside a Workflow that writes the summary as an
  # artifact from a template (Spec 7), scheduled from the host app.
end
