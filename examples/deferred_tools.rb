# frozen_string_literal: true

# Deferred tools: a long catalogue kept out of the model's context until the
# model looks for the tool it needs.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/deferred_tools.rb
#
# Every tool definition sent with a request costs context. With `defer: true`
# a tool's definition is held back; the model finds it through tool search (the
# provider's own where it has one, ruby_llm's `tool_search` tool otherwise) and
# only then is it sent. Deferring changes what the model is told up front, not
# what it may do: a deferred tool is gated like any other.
require "nexo"
require_relative "support/model"

module Catalog
  # Six small lookups standing in for a catalogue of dozens.
  FACTS = {
    "StockLevel" => ["Returns how many units of a SKU are in the warehouse", :sku, ->(v) { "#{v}: 42 units" }],
    "ShippingQuote" => ["Returns the cost to ship a parcel to a country", :country, ->(v) { "#{v}: $18.50" }],
    "ExchangeRate" => ["Returns today's exchange rate for a currency against USD", :currency, ->(v) { "1 USD = 17.2 #{v}" }],
    "Holiday" => ["Returns the next public holiday in a country", :country, ->(v) { "#{v}: December 25" }],
    "Weather" => ["Returns the weather in a city", :city, ->(v) { "#{v}: sunny, 24C" }],
    "OfficeHours" => ["Returns the opening hours of an office", :office, ->(v) { "#{v}: 9:00 to 18:00" }]
  }.freeze

  FACTS.each do |name, (text, argument, answer)|
    const_set(name, Class.new(RubyLLM::Tool) do
      description text
      parameter argument, type: :string, description: "The #{argument}"
      define_method(:execute) { |**arguments| answer.call(arguments.fetch(argument)) }
    end)
  end

  def self.tools = FACTS.keys.map { |name| const_get(name) }
end

class Operations < Nexo::Agent
  Examples.model(self)
  tools(*Catalog.tools, defer: true)
  instructions "Answer from your tools. If you do not see a tool for the job, search for one."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  agent = Operations.new
  chat = agent.chat
  puts "deferred (held back): #{chat.deferred_tools.keys.size} tools"

  calls = []
  response = agent.prompt("How many units of SKU A-17 are in the warehouse?") do |type, payload|
    calls << payload.name.to_s if type == :tool_call
  end
  puts "calls:   #{calls.inspect}"
  puts "answer:  #{response.content}"
end
