# frozen_string_literal: true

require "test_helper"

# Staging inputs into a run's sandbox (Spec 7 R2), Memory store, Virtual sandbox
# — no DB, no model. Asserts outcomes (files readable in the sandbox), never
# mocks the subject.
class WorkflowStagingTest < Minitest::Test
  # Stages whatever files it is given, then reads the first back out of the
  # sandbox into the result so the test can assert on the staged content.
  class Stager < Nexo::Workflow
    def call(payload)
      stage(payload[:files])
      {read_back: sandbox.read("/workspace/#{payload[:read]}")}
    end
  end

  def test_stage_writes_array_of_hashes_into_the_sandbox
    files = [
      {path: "baseline.md", content: "hello"},
      {path: "extra.md", content: "world"}
    ]
    run = Stager.run(files: files, read: "extra.md")

    assert_equal "done", run.status
    assert_equal "world", run.result["read_back"]
  end

  def test_stage_accepts_a_path_to_content_hash
    stager = Stager.new(Nexo::RunStore::Memory.new.create(workflow_class: "S", payload: {}))
    count = stager.stage({"a.md" => "aaa", "b.md" => "bbb"})

    assert_equal 2, count
    assert_equal "aaa", stager.sandbox.read("a.md")
    assert_equal "bbb", stager.sandbox.read("b.md")
  end

  # Stages only, no read-back — for asserting the emitted event.
  class StageOnly < Nexo::Workflow
    def call(payload)
      stage(payload[:files])
      {}
    end
  end

  def test_stage_emits_a_staged_event_with_the_count
    files = [{path: "x.md", content: "1"}, {path: "y.md", content: "2"}]
    run = StageOnly.run(files: files)
    ev = run.events.find { |e| e["type"] == "staged" }

    refute_nil ev
    assert_equal({count: 2}, ev["data"])
  end

  def test_stage_returns_the_count_staged
    stager = Stager.new(Nexo::RunStore::Memory.new.create(workflow_class: "S", payload: {}))

    assert_equal 1, stager.stage([{path: "only.md", content: "x"}])
  end
end
