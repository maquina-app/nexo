# frozen_string_literal: true

# Verification example (Spec 18) — the inbox-digest Task over an OAuth Gmail MCP
# server reached via HTTP, with the access token supplied by the host.
#
# Same shape as examples/inbox_digest.rb, but instead of a local `:stdio` server this
# points at a HOSTED Gmail MCP server over `transport: :http` and injects the OAuth
# access token as an `Authorization: Bearer` header. Nexo runs NO OAuth flow: your app
# (or an OAuth library) mints/refreshes the token; the `token:` provider just hands the
# current value to Nexo at connection time.
#
# The URL + tool names below are ILLUSTRATIVE — verify the actual OAuth Gmail MCP
# server you use and adjust `url`, `token`, and `mcp_allow` accordingly.
#
#   NEXO_LIVE=1 NEXO_MODEL=... GMAIL_MCP_URL=https://... GMAIL_TOKEN=ya29... \
#     ruby -Ilib examples/inbox_digest_http.rb
#
# Safe by default: only read tools are allow-listed, so send/trash/modify are denied by
# the unchanged gate even though the server exposes them.
require "nexo"

# Resolve skills from this examples dir so `skills :email_triage` finds
# examples/skills/email_triage/SKILL.md (shipped alongside this file). In a Rails app
# this defaults to app/skills and you would not set it here.
Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

class InboxTriageHTTP < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  permissions :read_only

  # Gmail reached through a HOSTED MCP server over HTTP — never a Gmail SDK
  # (provider-neutral). The host supplies the OAuth access token; Nexo injects it as
  # an `Authorization: Bearer` header and runs no OAuth flow of its own.
  #
  # `token:` is a callable so it is re-read at connection time. In a Rails host this
  # would close over your auth code, e.g. `-> { Current.user.gmail_access_token }`.
  # A rotated token needs `agent.close` + a fresh prompt (headers are snapshotted at
  # construction — see docs/mcp.md).
  mcp :gmail,
    transport: :http,
    url: ENV.fetch("GMAIL_MCP_URL"),
    token: -> { ENV.fetch("GMAIL_TOKEN") }

  # READ tools only. send_email / trash_message / modify_labels are intentionally
  # absent -> the unchanged gate denies them.
  mcp_allow %w[search_threads get_thread list_messages get_message list_labels]

  # The skill teaches the model HOW to classify + which threads warrant a summary.
  skills :email_triage

  instructions <<~TXT
    You triage a Gmail inbox using the attached skill. Classify recent threads and
    write a concise digest of the ones the skill flags as summary-worthy. Read only.
  TXT
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  agent = InboxTriageHTTP.new
  begin
    digest = agent.prompt(
      "Classify today's inbox and produce a markdown digest of the threads worth my attention."
    )
    puts digest.content
  ensure
    agent.close
  end
end
