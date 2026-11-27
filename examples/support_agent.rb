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
require "nexo"
require_relative "support/model"

Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }

ORDERS = {
  "A-1001" => {item: "Mechanical keyboard", total: 129.00, delivered_days_ago: 6},
  "A-1002" => {item: "4K monitor", total: 449.00, delivered_days_ago: 12},
  "A-1003" => {item: "USB hub", total: 39.00, delivered_days_ago: 61}
}.freeze

LEDGER = {} # what actually happened, keyed so nothing can happen twice

class LookupOrder < RubyLLM::Tool
  description "Looks up an order by its number: the item, the total paid, and how many days ago it was delivered."
  parameter :order, type: :string, description: "The order number, such as A-1001"

  def execute(order:)
    ORDERS.fetch(order) { return {error: "no order #{order}"} }.merge(order: order)
  end
end

# Two rules for a tool that acts and waits for approval, both visible below.
#
# 1. Its arguments are facts, not prose. An approval is filed under what the call
#    does — the tool and its arguments — and a resume asks the model again. A
#    free-text `reason` would be worded differently the second time, which makes
#    it a different call, which asks the person again.
# 2. It is idempotent. Everything outside a checkpoint runs again on a resume,
#    tool calls included, so "refund this order" must be safe to hear twice.
class IssueRefund < RubyLLM::Tool
  description "Refunds an amount on an order to the customer's original payment method. An order is refunded at most once."
  parameter :order, type: :string, description: "The order number"
  parameter :amount, type: :number, description: "The amount to refund, in dollars"

  def execute(order:, amount:)
    return "#{order} was already refunded: #{LEDGER["refund:#{order}"]}." if LEDGER.key?("refund:#{order}")

    LEDGER["refund:#{order}"] = "$#{format("%.2f", amount)}"
    "Refunded $#{format("%.2f", amount)} on #{order}."
  end
end

class PageOnCall < RubyLLM::Tool
  REASONS = %w[large_refund suspected_fraud angry_customer].freeze

  description "Pages the on-call support lead about an order. One page per order and reason."
  parameter :order, type: :string, description: "The order number"
  parameter :reason, type: :string, description: "One of: #{REASONS.join(", ")}"

  def execute(order:, reason:)
    return {error: "reason must be one of #{REASONS.join(", ")}"} unless REASONS.include?(reason)

    LEDGER["page:#{order}:#{reason}"] ||= "paged"
    "The on-call lead was paged about #{order} (#{reason})."
  end
end

class SupportAgent < Nexo::Agent
  Examples.model(self)
  permissions :approve
  file_tools :none       # it works through its tools; it needs no files
  skills :refunds
  tools LookupOrder                              # reads: no gate
  tools IssueRefund, PageOnCall, capability: :write # acts: a person decides each call

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
