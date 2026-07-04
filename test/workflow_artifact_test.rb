# frozen_string_literal: true

require "test_helper"

# Named artifacts recorded on a run (Spec 7 R3/R4), Memory store, Virtual
# sandbox — no DB, no model. Asserts outcomes on run.artifacts and the sandbox,
# never mocks the subject.
class WorkflowArtifactTest < Minitest::Test
  # Emits a content: artifact.
  class Digest < Nexo::Workflow
    def call(_payload)
      artifact("digest.md", content: "the digest body")
      {ok: true}
    end
  end

  # Renders an artifact from a staged, trusted ERB template.
  class Rendered < Nexo::Workflow
    def call(payload)
      stage(payload[:files])
      artifact("out.md", from: "/workspace/tmpl.md.erb", locals: {name: payload[:name]})
      {ok: true}
    end
  end

  # Emits neither content: nor from:, exercising the raise contract.
  class Empty < Nexo::Workflow
    def call(_payload)
      artifact("nothing")
    end
  end

  def test_content_artifact_is_recorded_string_keyed_on_the_run
    run = Digest.run({})
    art = run.artifacts.first

    assert_equal 1, run.artifacts.size
    assert_equal "digest.md", art["name"]
    assert_equal "the digest body", art["content"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, art["at"])
  end

  def test_content_artifact_is_written_to_the_sandbox_under_artifacts
    stub = Nexo::RunStore::Memory.new.create(workflow_class: "D", payload: {})
    wf = Digest.new(stub)
    wf.call({})

    assert_equal "the digest body", wf.sandbox.read("/artifacts/digest.md")
  end

  def test_from_renders_a_trusted_template_with_locals
    files = [{path: "tmpl.md.erb", content: "Hello <%= name %>!"}]
    run = Rendered.run(files: files, name: "Ada")

    assert_equal "Hello Ada!", run.artifacts.first["content"]
  end

  def test_artifact_without_content_or_from_raises
    error = assert_raises(Nexo::Error) { Empty.run({}) }

    assert_match(/artifact nothing needs content: or from:/, error.message)
  end

  def test_artifacts_preserve_emission_order
    klass = Class.new(Nexo::Workflow) do
      def call(_payload)
        artifact("first.md", content: "1")
        artifact("second.md", content: "2")
        {}
      end
    end
    run = klass.run({})

    assert_equal %w[first.md second.md], run.artifacts.map { |a| a["name"] }
  end
end
