# frozen_string_literal: true

# Verification example — Spec 8 (Workflow↔Agent glue). The inbox digest as a TASK.
#
# Wraps the Spec 6 InboxTriage agent (Gmail MCP + email_triage skill, read-only + gated)
# in a Workflow that runs it and captures the digest as a named artifact. The SAME workflow
# is a scheduled Task (call it from ActiveJob/cron) or an interactive Action (call it from a
# controller after staging uploads) — no code difference.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b ruby -Ilib examples/inbox_digest_task.rb
#
# Requires the Spec 6 InboxTriage agent (examples/inbox_digest.rb) and its email_triage skill.
require "nexo"
require_relative "inbox_digest" # defines InboxTriage (Gmail MCP + skill, read-only)

class InboxDigestTask < Nexo::Workflow
  agent InboxTriage # Spec 8: this workflow drives that agent, sharing the run sandbox

  def call(payload)
    window = payload[:window] || "newer_than:1d"
    response = run_agent("Triage #{window} and produce the markdown digest per the skill.")
    # Spec 7: capture the agent's output as a retrievable artifact.
    artifact("inbox-digest.md", content: response.content)
    {window: window}
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  run = InboxDigestTask.run(window: "newer_than:1d")
  puts "run #{run.id} -> #{run.status}"
  art = run.artifacts.find { |a| (a["name"] || a[:name]) == "inbox-digest.md" }
  puts(art && (art["content"] || art[:content]))

  # As a scheduled Task, a host app would do (in an ActiveJob):
  #   InboxDigestTask.run(window: "newer_than:1d")
  # As an interactive Action, a controller would stage uploads first, then the same run.
  # Scheduling itself lives in the host (cron / GoodJob / whenever) — Nexo stays schedulable.
end
