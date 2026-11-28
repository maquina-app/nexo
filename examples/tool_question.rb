# frozen_string_literal: true

# A tool that stops to ask the person something. The run suspends with the
# question, and resumes with the answer.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/tool_question.rb
#
# The tool calls `ask` (a `RubyLLM::Tool` method). ruby_llm pauses the call; Nexo
# raises `Nexo::InputRequired` from `prompt`, and `run_agent` turns that into a
# suspended run a host can answer later, from another request or another process.
# An MCP server's question (elicitation) travels the same way.
require "nexo"
require_relative "support/model"

class BookSeat < RubyLLM::Tool
  description "Books a seat on a flight. Asks the traveller which kind of seat they want."
  parameter :flight, type: :string, description: "The flight number, such as NX204"

  def execute(flight:)
    seat = ask("Window or aisle on #{flight}?", choices: %w[window aisle])
    return "The traveller declined to choose; nothing was booked." if seat.nil?

    "Booked a #{seat} seat on #{flight}."
  end
end

class TravelDesk < Nexo::Agent
  Examples.model(self)
  tools BookSeat
  instructions "You book travel with the tools you have. Do not ask the user questions yourself; the tools do."
end

class BookTrip < Nexo::Workflow
  agent TravelDesk

  def call(payload)
    {reply: run_agent("Book a seat on flight #{payload[:flight]}.").content}
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  # 1) The tool asks. The run suspends and records what to put to the person.
  run = BookTrip.run(flight: "NX204")
  puts "status:    #{run.status}"
  abort "the model did not call the tool; try a stronger model" unless run.status == "suspended"

  question = run.state["__input__"].first
  puts "question:  #{question["message"]}"
  puts "choices:   #{question["fields"].flat_map { |field| field["choices"] }.compact.inspect}"
  puts "answer as: #{question["key"]}"

  # 2) Later, the person answers. Resume with the answer filed under the key.
  #    (`false` in place of an answer declines the question.)
  done = BookTrip.resume(run.id, answers: {question["key"] => "aisle"})
  puts "status:    #{done.status}"
  puts "reply:     #{done.result["reply"]}"
end
