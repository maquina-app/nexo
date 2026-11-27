# frozen_string_literal: true

# A Task: a workflow that drives an agent (`agent` macro + `run_agent`) over
# files staged into the run's sandbox, and keeps the result as a named artifact.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/inbox_digest_task.rb
#
# The mail here is three files, so the example runs with nothing but a model.
# The same shape holds when the mail comes from an MCP server: declare `mcp` and
# `mcp_allow` on the agent and drop the staging.
require "nexo"
require_relative "support/model"

Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

class InboxTriage < Nexo::Agent
  Examples.model(self)
  permissions :read_only # it can list and read the staged mail, and nothing else
  skills "email-triage" # the rules live in examples/skills/email-triage/SKILL.md

  instructions "You triage the mail in the inbox/ folder of your workspace, following the email-triage skill."
end

class InboxDigestTask < Nexo::Workflow
  agent InboxTriage # this workflow drives that agent, which shares the run's sandbox

  def call(payload)
    stage(payload[:mail]) # the workflow puts the mail in the sandbox; the agent only reads
    response = run_agent("Read every file under inbox/ and produce the markdown digest per the skill.")
    artifact("inbox-digest.md", content: response.content)
    {messages: payload[:mail].size}
  end
end

MAIL = {
  "inbox/01-landlord.txt" => <<~MAIL,
    From: Building Management <office@riverside.example>
    Subject: Water shut-off Thursday 9-11am
    The water will be off on Thursday morning for valve work. Reply by Wednesday if
    you need access to the basement storage that day.
  MAIL
  "inbox/02-newsletter.txt" => <<~MAIL,
    From: Ruby Weekly <news@rubyweekly.example>
    Subject: Issue 742
    This week: a new minor release, three conference talks, and a gem of the week.
  MAIL
  "inbox/03-invoice.txt" => <<~MAIL
    From: Acme Hosting <billing@acme.example>
    Subject: Invoice 2291 is due on the 30th
    Your invoice for November ($48.00) is due on November 30. No action is needed if
    autopay is on; it is currently OFF on this account.
  MAIL
}.freeze

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  run = InboxDigestTask.run(mail: MAIL)
  puts "run #{run.id} -> #{run.status}"
  digest = run.artifacts.find { |artifact| artifact["name"] == "inbox-digest.md" }
  puts Nexo::Workflow.artifact_body(digest)

  # As a scheduled Task, a host app runs the same line from a job:
  #   InboxDigestTask.run(mail: fetch_mail)
  # Scheduling itself lives in the host (cron, Solid Queue, GoodJob).
end
