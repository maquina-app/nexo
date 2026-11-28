# frozen_string_literal: true

# A support agent: a policy in a skill, a lookup tool, and two tools that act on
# the world and so wait for a person. (After the "Acme support agent" that Vercel's
# Eve uses to introduce itself.)
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/support_agent.rb
#
#   * the refund policy is a skill (examples/skills/refunds/SKILL.md), not Ruby
#   * `LookupOrder` reads, so it has no gate
#   * `IssueRefund` and `PageOnCall` are declared `capability: :write`; under
#     `:approve` each call suspends the run until a person decides
#   * after the decision the paused call carries on: the model is not asked
#     again, so the refund is issued once (before 0.17 a resume re-ran the prompt,
#     and this example refunded the same order three times)
require "nexo"
require_relative "support/model"

Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

ORDERS = {
  "A-1001" => {item: "Mechanical keyboard", total: 129.00, delivered_days_ago: 6},
  "A-1002" => {item: "4K monitor", total: 449.00, delivered_days_ago: 12},
  "A-1003" => {item: "USB hub", total: 39.00, delivered_days_ago: 61}
}.freeze

LEDGER = [] # what actually happened, so the example can show it

class LookupOrder < RubyLLM::Tool
  description "Looks up an order by its number: the item, the total paid, and how many days ago it was delivered."
  parameter :order, type: :string, description: "The order number, such as A-1001"

  def execute(order:)
    ORDERS.fetch(order) { return {error: "no order #{order}"} }.merge(order: order)
  end
end

class IssueRefund < RubyLLM::Tool
  description "Refunds an amount on an order to the customer's original payment method."
  parameter :order, type: :string, description: "The order number"
  parameter :amount, type: :number, description: "The amount to refund, in dollars"
  parameter :reason, type: :string, description: "Why, in a few words"

  def execute(order:, amount:, reason:)
    LEDGER << "refunded $#{format("%.2f", amount)} on #{order} (#{reason})"
    "Refunded $#{format("%.2f", amount)} on #{order}."
  end
end

class PageOnCall < RubyLLM::Tool
  description "Pages the on-call support lead with a short message."
  parameter :message, type: :string, description: "What they need to know"

  def execute(message:)
    LEDGER << "paged on-call: #{message}"
    "The on-call lead was paged."
  end
end

class SupportAgent < Nexo::Agent
  Examples.model(self)
  permissions :approve
  file_tools :none       # it works through its tools; it needs no files
  skills :refunds
  tools LookupOrder                              # reads: no gate
  # These act, so a person decides each call. `detail:` says what identifies a
  # call: the order and the amount, not the free-text reason, which a model
  # words differently every time it is asked.
  tools IssueRefund, capability: :write, detail: ->(args) { "refund $#{args[:amount]} on #{args[:order]}" }
  tools PageOnCall, capability: :write, detail: ->(_args) { "page the on-call lead" }

  instructions "You are a support agent for an online shop. Follow the refunds skill. Use your tools; do not invent order details."
end

class SupportTicket < Nexo::Workflow
  agent SupportAgent

  def call(payload)
    {reply: run_agent(payload[:message]).content}
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  run = SupportTicket.run(message: "Order A-1002: the monitor arrived with a cracked panel. I want my money back.")

  # A person at a support console: approve refunds, and see every page.
  5.times do
    break unless run.status == "suspended"

    answers = run.state["__approvals_pending__"].to_h do |call|
      puts "needs a decision:  #{call["tool"]}"
      [call["key"], true]
    end
    run = Nexo::Workflow.resume(run.id, approvals: answers)
  end

  puts "status:            #{run.status}"
  puts "what happened:     #{LEDGER.inspect}"
  puts "reply to customer: #{run.result && run.result["reply"]}"
end
