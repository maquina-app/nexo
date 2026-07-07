# frozen_string_literal: true

require "test_helper"

# Spec 15: Agent and Workflow share one resolver, so a Workflow now resolves the
# same sandbox forms an Agent already does. These tests assert that parity by
# building the real resolver output from each side and comparing.
class AgentWorkflowSandboxParityTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  def setup
    skip "agent wiring uses the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  def test_workflow_now_resolves_docker_like_agent
    wf = Class.new(Nexo::Workflow) do
      sandbox :docker, image: "node:22-slim"
      def call(_p) = {}
    end
    instance = wf.new(Nexo::RunStore::Memory.new.create(workflow_class: "X", payload: {}))
    assert_instance_of Nexo::Sandboxes::Container, instance.sandbox
    assert_equal :docker, instance.sandbox.runtime
  end

  def test_parity_across_every_form
    [
      [:virtual, Nexo::Sandboxes::Virtual, {}],
      [:local, Nexo::Sandboxes::Local, {cwd: Dir.pwd}],
      [{type: :docker, image: "node:22-slim"}, Nexo::Sandboxes::Container, {runtime: :docker}],
      [{type: :apple, image: "img"}, Nexo::Sandboxes::Container, {runtime: :apple}]
    ].each do |decl, klass, attrs|
      a = agent_sandbox(decl)
      w = workflow_sandbox(decl)
      assert_instance_of klass, a, "agent for #{decl.inspect}"
      assert_equal a.class, w.class, "class parity for #{decl.inspect}"
      attrs.each do |attr, expected|
        expected = File.expand_path(expected) if attr == :cwd
        assert_equal expected, a.public_send(attr), "agent #{attr} for #{decl.inspect}"
        assert_equal expected, w.public_send(attr), "workflow #{attr} for #{decl.inspect}"
      end
    end
  end

  def test_prebuilt_instance_passes_through_on_both
    inst = Nexo::Sandboxes::Virtual.new
    assert_same inst, agent_sandbox(inst)
    assert_same inst, workflow_sandbox(inst)
  end

  def test_bare_docker_without_image_raises_on_both
    assert_raises(Nexo::ConfigurationError) { agent_sandbox(:docker) }
    assert_raises(Nexo::ConfigurationError) { workflow_sandbox(:docker) }
  end

  private

  # Both callers exercise the identical DSL path: a bare value stays a value, a
  # Hash form replays through the widened macro as +sandbox type, **opts+.
  def agent_sandbox(decl)
    val, opts = decl_parts(decl)
    Class.new(Nexo::Agent) { model TEST_MODEL }.tap { |k| k.sandbox(*val, **opts) }.new.sandbox
  end

  def workflow_sandbox(decl)
    val, opts = decl_parts(decl)
    wf = Class.new(Nexo::Workflow) { def call(_p) = {} }
    wf.sandbox(*val, **opts)
    wf.new(Nexo::RunStore::Memory.new.create(workflow_class: "X", payload: {})).sandbox
  end

  def decl_parts(decl)
    if decl.is_a?(Hash)
      [[decl[:type]], decl.except(:type)]
    else
      [[decl], {}]
    end
  end
end
