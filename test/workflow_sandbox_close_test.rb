# frozen_string_literal: true

require "test_helper"

# Workflow.execute releases the run's sandbox on every terminal path so a
# container/remote-backed run doesn't leak — but only if a sandbox was actually
# built (a data-only workflow never resolves one). Memory store, no DB, no model.
class WorkflowSandboxCloseTest < Minitest::Test
  # A sandbox that records its teardown and can serve staged reads.
  class RecordingSandbox < Nexo::Sandbox
    attr_reader :closed_count

    def initialize
      @closed_count = 0
      @files = {}
    end

    def write(path, content) = @files[path] = content

    def read(path) = @files.fetch(path)

    def close = @closed_count += 1
  end

  def test_execute_closes_a_built_sandbox_on_success
    sandbox = RecordingSandbox.new
    klass = Class.new(Nexo::Workflow) do
      sandbox sandbox
      def call(_payload)
        artifact("out.md", content: "x") # touches the sandbox => it is built
        {ok: true}
      end
    end

    run = klass.run({})

    assert_equal "done", run.status
    assert_equal 1, sandbox.closed_count
  end

  def test_execute_closes_a_built_sandbox_on_failure
    sandbox = RecordingSandbox.new
    klass = Class.new(Nexo::Workflow) do
      sandbox sandbox
      def call(_payload)
        artifact("out.md", content: "x")
        raise "boom"
      end
    end

    assert_raises(RuntimeError) { klass.run({}) }
    assert_equal 1, sandbox.closed_count
  end

  def test_data_only_workflow_never_builds_or_closes_a_sandbox
    sandbox = RecordingSandbox.new
    klass = Class.new(Nexo::Workflow) do
      sandbox sandbox
      def call(_payload) = {ok: true} # never touches the sandbox
    end

    run = klass.run({})

    assert_equal "done", run.status
    assert_equal 0, sandbox.closed_count # never built => never closed
  end
end
