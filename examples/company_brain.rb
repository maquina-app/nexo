# frozen_string_literal: true

# A company assistant that answers from the company's own documents, says which
# one it used, and remembers the conversation. (After Eve's "Company Brain"
# template, without the Slack channel: a channel is your application's job.)
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/company_brain.rb
#
# What it shows:
#
#   * MCP RESOURCES — a server offering things to read, not only tools to call.
#     `resources: true` attaches `list_mcp_resources` and `read_mcp_resource`,
#     which the agent must be allowed (`mcp_allow`) like any MCP tool.
#   * `Nexo::Session` — a continuing conversation addressed by an id, so a later
#     question can lean on an earlier one.
#
# The server is a 50-line script in examples/support/, serving the three pages in
# examples/support/handbook/. Point `command:` at a real MCP server to use yours.
require "nexo"
require_relative "support/model"

class CompanyBrain < Nexo::Agent
  Examples.model(self)
  file_tools :none # everything it knows comes from the server

  mcp :handbook, transport: :stdio, command: RbConfig.ruby,
    args: [File.expand_path("support/handbook_server.rb", __dir__), File.expand_path("support/handbook", __dir__)],
    resources: true
  mcp_allow "list_mcp_resources", "read_mcp_resource"

  instructions "You answer questions about company policy from the handbook resources. List them, read the one " \
               "that applies, and answer in two sentences. End with the resource you used, as (source: <uri>). " \
               "If the handbook does not say, say so."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  def ask(question)
    session = Nexo::Session.resume(CompanyBrain, "team-platform") # the same thread each time
    calls = []
    answer = session.prompt(question) { |type, payload| calls << payload.name.to_s if type == :tool_call }
    puts "Q: #{question}"
    puts "A: #{answer.content}"
    puts "   (tools: #{calls.join(", ")})"
    puts
  ensure
    session&.close
  end

  ask "How many days of paid leave do I get?"
  ask "And how many of those can I carry over?" # "those" needs the first turn
  ask "What is the budget for a team offsite?"   # not in the handbook
end
