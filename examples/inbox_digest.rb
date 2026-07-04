# frozen_string_literal: true

# Verification example — Use case #1: a Gmail MCP server + an email-triage skill.
#
# This is the real target shape for the scheduled "inbox digest" Task. Gmail needs
# OAuth set up for whatever MCP server you use, so this is heavier to run than
# examples/mcp_filesystem.rb — start there to verify the seam itself.
#
# The package name below is ILLUSTRATIVE — verify the actual Gmail MCP server you use
# and its tool names, then adjust `mcp` and `mcp_allow` accordingly.
#
#   NEXO_LIVE=1 NEXO_MODEL=... ruby -Ilib examples/inbox_digest.rb
#
# Safe by default: only read tools are allow-listed, so send/delete/modify are denied
# by the gate even though the server exposes them.
require "nexo"

# Resolve skills from this examples dir so `skills :email_triage` finds
# examples/skills/email_triage/SKILL.md (shipped alongside this file). In a Rails
# app this defaults to app/skills and you would not set it here.
Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

class InboxTriage < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  permissions :read_only

  # Gmail is reached through an MCP server — never a Gmail SDK (provider-neutral).
  mcp :gmail,
    transport: :stdio,
    command: "npx",
    args: ["-y", ENV.fetch("GMAIL_MCP_PACKAGE", "@your-org/mcp-server-gmail")]

  # READ tools only. send_email / trash_message / modify_labels are intentionally
  # absent -> the gate denies them.
  mcp_allow %w[search_threads get_thread list_messages get_message list_labels]

  # The skill teaches the model HOW to classify + which threads warrant a summary.
  # Shipped with this example at examples/skills/email_triage/SKILL.md (read-only,
  # with concrete tool-call examples baked in for small local models).
  skills :email_triage

  instructions <<~TXT
    You triage a Gmail inbox using the attached skill. Classify recent threads and
    write a concise digest of the ones the skill flags as summary-worthy. Read only.
  TXT
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  agent = InboxTriage.new
  begin
    digest = agent.prompt(
      "Classify today's inbox and produce a markdown digest of the threads worth my attention."
    )
    puts digest.content
    # In the full Task (Spec 8) this runs inside a Workflow that writes the digest as a
    # named artifact from a template (Spec 7), scheduled from ActiveJob/cron in the host app.
  ensure
    agent.close
  end
end
