# frozen_string_literal: true

# A small software factory: one agent writes the change, the tests run as plain
# code, and a second agent reviews. (After Eve's "Software factory" template.)
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/software_factory.rb
#
# What it shows:
#
#   * two agent classes with different authority in one workflow — the Coder may
#     write and run commands, the Reviewer can only read
#   * a deterministic step between them: the workflow runs the tests itself and
#     checkpoints the result, so the Reviewer is told facts, not the Coder's word
#   * `emit_agent_event`, for a workflow that prompts its agents itself: every
#     agent's events and token use land in one run log, tagged by who it was
#
# The shell here is the confined local one where the machine supports it. Set
# NEXO_FACTORY_SANDBOX=docker to run the commands in a throwaway container.
require "nexo"
require "tmpdir"
require_relative "support/model"

WORKSPACE = Dir.mktmpdir("nexo-factory")

class Coder < Nexo::Agent
  Examples.model(self)
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])
  instructions "You are a careful Ruby developer. Read the task and the tests, write the code, and run the tests " \
               "with the shell until they pass. Change only files under lib/. Finish with one line saying what you did."
end

class Reviewer < Nexo::Agent
  Examples.model(self)
  permissions :read_only # it can read the change; it cannot touch it
  instructions "You review a Ruby change. Read the files. Reply with a first line that is exactly APPROVE or " \
               "REQUEST CHANGES, then at most three short bullet points."
end

# Where the Coder's commands run: a container when asked for, the confined local
# shell where this machine supports it, the plain local shell otherwise.
def factory_sandbox
  if (runtime = ENV["NEXO_FACTORY_SANDBOX"])
    return {type: runtime.to_sym, image: "ruby:3.3-slim", cwd: "/workspace"}
  end

  confined = {type: :local, isolation: :confined, readable: :ruby}
  Nexo::Sandboxes.resolve(confined, cwd: WORKSPACE).shell("true")
  confined
rescue Nexo::ConfigurationError, Nexo::MissingDependencyError
  :local
end

class ShipFeature < Nexo::Workflow
  cwd WORKSPACE
  sandbox factory_sandbox

  def call(payload)
    stage(payload[:files])

    summary = checkpoint(:code) { work(Coder, "coder", "Do the task in TASK.md. The tests are in test/.") }

    # Not a model's opinion: the workflow runs the tests and records what happened.
    tests = checkpoint(:tests) do
      out = sandbox.shell("ruby test/slug_test.rb")
      {"passed" => out[:status].zero?, "output" => (out[:stdout] + out[:stderr]).lines.last(6).join}
    end

    review = checkpoint(:review) do
      work(Reviewer, "reviewer", "Review lib/slug.rb against TASK.md. The test run " \
        "#{tests["passed"] ? "passed" : "FAILED"}:\n#{tests["output"]}")
    end

    {coder: summary, tests_passed: tests["passed"], review: review}
  end

  private

  # Prompts one agent over the run's sandbox and logs its events on the run.
  def work(agent_class, who, text)
    agent = agent_class.new(sandbox: sandbox)
    agent.prompt(text, cancel: -> { cancel_requested? }) { |type, payload| emit_agent_event(type, payload, source: who) }.content
  ensure
    agent&.close
  end
end

FILES = {
  "TASK.md" => <<~MD,
    # Task

    Add `Slug.for(title)` in `lib/slug.rb`. It returns a URL slug: lower case,
    words joined by single hyphens, everything that is not a letter or a digit
    dropped, no hyphen at either end. An empty or blank title returns "untitled".
  MD
  "lib/slug.rb" => "# frozen_string_literal: true\n\nmodule Slug\nend\n",
  "test/slug_test.rb" => <<~RUBY
    # frozen_string_literal: true

    require "minitest/autorun"
    require_relative "../lib/slug"

    class SlugTest < Minitest::Test
      def test_words_are_joined_by_hyphens = assert_equal("hello-world", Slug.for("Hello World"))
      def test_punctuation_is_dropped = assert_equal("whats-new-in-016", Slug.for("What's new in 0.16?"))
      def test_no_hyphen_at_the_ends = assert_equal("spaced-out", Slug.for("  spaced   out  "))
      def test_blank_is_untitled = assert_equal("untitled", Slug.for("   "))
    end
  RUBY
}.freeze

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  run = ShipFeature.run(files: FILES)
  result = run.result
  puts "status:        #{run.status}"
  puts "coder:         #{result["coder"].to_s.lines.last.to_s.strip}"
  puts "tests passed:  #{result["tests_passed"]}"
  puts "review:        #{result["review"].to_s.lines.first.to_s.strip}"

  calls = run.events.select { |event| event["type"] == "agent_tool_call" }
  puts "tool calls:    #{calls.group_by { |event| event["data"]["source"] }.transform_values(&:size).inspect}"
  usage = Nexo::Workflow.usage(run)
  puts "tokens:        #{usage["tokens"].slice("input_tokens", "output_tokens").inspect} over #{usage["prompts"]} prompts"
  puts "sandbox:       #{ShipFeature.sandbox.inspect}"
  puts "the change:    #{File.join(WORKSPACE, "lib/slug.rb")}"
end
