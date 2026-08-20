# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# An agent's declared output is copied out of the sandbox and recorded on the
# run as soon as the agent finishes — including when it suspended or raised,
# which are exactly the paths where an ephemeral sandbox dies with results
# still in it. Memory store, Virtual sandbox, no model.
class WorkflowCollectArtifactsTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  # Writes files into the shared sandbox the way a real agent's tools would.
  class WritingAgent < Nexo::Agent
    produces "dashboard.html", "digest.json"

    def initialize(sandbox: nil, **)
      @sandbox = sandbox
    end

    def prompt(_text, max_turns: 25)
      @sandbox.write("dashboard.html", "<h1>hi</h1>")
      @sandbox.write("digest.json", '{"ok":true}')
      @sandbox.write("scratch.tmp", "not declared")
      Struct.new(:content).new("done")
    end

    def close = nil
  end

  # Several artifacts from one agent, named by a glob.
  class GlobbingAgent < WritingAgent
    produces "out/*.json"

    def prompt(_text, max_turns: 25)
      @sandbox.write("out/a.json", "1")
      @sandbox.write("out/b.json", "2")
      @sandbox.write("out/notes.txt", "skip me")
      Struct.new(:content).new("done")
    end
  end

  # Declares an artifact it never writes.
  class ForgetfulAgent < WritingAgent
    produces "never-written.html"

    def prompt(_text, max_turns: 25) = Struct.new(:content).new("done")
  end

  # Produces binary bytes, which an AR json column cannot hold raw.
  class BinaryAgent < WritingAgent
    produces "logo.png"

    def prompt(_text, max_turns: 25)
      @sandbox.write("logo.png", (0..255).map(&:chr).join.b)
      Struct.new(:content).new("done")
    end
  end

  # Writes, then suspends for a human approval — the durable path, and the one
  # where an ephemeral sandbox loses the most.
  class ApprovalAgent < WritingAgent
    produces "pending.json"

    def prompt(_text, max_turns: 25)
      @sandbox.write("pending.json", %({"awaiting":"approval"}))
      raise Nexo::ApprovalRequired.new(:write, "publish.sh")
    end
  end

  # Writes, then raises — the sandbox would be torn down with the file in it.
  class ExplodingAgent < WritingAgent
    produces "partial.json"

    def prompt(_text, max_turns: 25)
      @sandbox.write("partial.json", '{"partial":true}')
      raise "boom"
    end
  end

  def self.workflow_for(agent_klass)
    Class.new(Nexo::Workflow) do
      agent agent_klass
      def call(_payload) = run_agent("go")
    end
  end

  WRITING = workflow_for(WritingAgent)
  GLOBBING = workflow_for(GlobbingAgent)
  FORGETFUL = workflow_for(ForgetfulAgent)
  BINARY = workflow_for(BinaryAgent)
  EXPLODING = workflow_for(ExplodingAgent)

  def names(run) = run.artifacts.map { |a| a["name"] }.sort

  def test_declared_output_is_recorded_and_undeclared_output_is_not
    run = WRITING.run({})

    assert_equal ["dashboard.html", "digest.json"], names(run)
    refute_includes names(run), "scratch.tmp"
  end

  def test_the_recorded_body_is_the_agents_bytes_verbatim
    art = WRITING.run({}).artifacts.find { |a| a["name"] == "dashboard.html" }

    assert_equal "<h1>hi</h1>", art["content"]
  end

  # produces accumulates, so the subclass keeps the parent's two and adds a glob.
  def test_one_agent_can_produce_many_artifacts_including_by_glob
    run = GLOBBING.run({})

    assert_includes names(run), "a.json"
    assert_includes names(run), "b.json"
    refute_includes names(run), "notes.txt"
  end

  # A run can legitimately not produce a declared artifact; that must not fail it.
  def test_a_declared_artifact_that_was_never_written_is_skipped_not_fatal
    run = FORGETFUL.run({})

    assert_equal "done", run.status
    assert_empty run.artifacts
  end

  def test_binary_output_is_base64_wrapped_and_round_trips
    art = BINARY.run({}).artifacts.first
    source = (0..255).map(&:chr).join.b

    assert_equal "base64", art["encoding"]
    assert_equal source, Nexo::Workflow.artifact_body(art).b
  end

  def test_text_output_carries_no_encoding_key
    art = WRITING.run({}).artifacts.first

    refute art.key?("encoding")
    assert_equal "<h1>hi</h1>", Nexo::Workflow.artifact_body(art)
  end

  # The failure path is where an ephemeral sandbox loses the most: the run is
  # over, the container is about to be rm -f'd, and the output is still inside.
  def test_output_is_collected_even_when_the_agent_raises
    assert_raises(RuntimeError) { EXPLODING.run({}) }
    run = Nexo::RunStore::Memory.runs.values.last

    assert_equal "failed", run.status
    assert_equal ["partial.json"], names(run)
  end

  # THE motivating case. Workflow.execute releases the sandbox on every terminal
  # path including "suspended", and Container#close is `rm -f` — so before this,
  # pausing for a human destroyed everything the run had produced, while the same
  # code on :local kept it.
  def test_output_is_collected_when_the_agent_suspends_for_approval
    klass = Class.new(Nexo::Workflow) do
      agent ApprovalAgent
      def call(_payload) = run_agent("go")
    end
    run = klass.run({})

    assert_equal "suspended", run.status
    assert_equal ["pending.json"], names(run)
    assert_equal %({"awaiting":"approval"}), Nexo::Workflow.artifact_body(run.artifacts.first)
  end

  # The hand-off half: what one stage produced is readable by the next, even
  # when the sandbox that held it is gone.
  def test_restore_puts_recorded_artifacts_back_into_the_sandbox
    klass = Class.new(Nexo::Workflow) do
      agent WritingAgent
      def call(_payload)
        run_agent("go")
        # Stand in for a fresh sandbox: wipe what the agent wrote, then restore.
        sandbox.write("dashboard.html", "")
        restored = restore_artifacts
        {restored: restored, back: sandbox.read("dashboard.html")}
      end
    end
    result = klass.run({}).result

    assert_equal "<h1>hi</h1>", result["back"]
    assert_includes result["restored"], "./dashboard.html"
  end

  def test_restore_can_select_a_subset
    klass = Class.new(Nexo::Workflow) do
      agent WritingAgent
      def call(_payload)
        run_agent("go")
        {restored: restore_artifacts(only: "digest.json")}
      end
    end

    assert_equal ["./digest.json"], klass.run({}).result["restored"]
  end

  def test_restore_decodes_a_binary_artifact
    klass = Class.new(Nexo::Workflow) do
      agent BinaryAgent
      def call(_payload)
        run_agent("go")
        sandbox.write("logo.png", "")
        restore_artifacts
        {size: sandbox.read("logo.png").bytesize}
      end
    end

    assert_equal 256, klass.run({}).result["size"]
  end

  # #artifact wrote an ABSOLUTE /artifacts/<name>, which every real sandbox
  # rejects as an escape — so it only ever worked on :virtual. Assert the path is
  # relative and lands inside a guarded root.
  def test_the_sandbox_copy_is_written_inside_the_sandbox_root
    Dir.mktmpdir do |dir|
      klass = Class.new(Nexo::Workflow) do
        sandbox :local
        cwd dir
        def call(_payload) = artifact("review.md", content: "body")
      end
      klass.run({})

      assert_equal "body", File.read(File.join(dir, "artifacts", "review.md"))
    end
  end

  # An agent declaring nothing is unchanged: no artifacts, no error.
  def test_an_agent_that_declares_nothing_records_nothing
    klass = Class.new(WritingAgent) { @produces = [] }
    run = self.class.workflow_for(klass).run({})

    assert_empty run.artifacts
  end
end
