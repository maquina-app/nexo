# frozen_string_literal: true

require "test_helper"

# The `sandbox :docker/:apple, **opts` DSL resolves to a hardened
# Sandboxes::Container without touching a daemon. The existing
# :virtual/:local/instance branches must stay byte-for-byte unchanged (covered in
# agent_test.rb); here we assert the new container branches only.
#
# Note the bare `:docker`/`:apple` shorthands build a Container with no image,
# which is a ConfigurationError (image is required) — the usable form is the
# options Hash `sandbox :docker, image: "..."`.
class AgentContainerTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  class DockerOptsAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :docker, image: "node:22-slim",
      binds: {"/host/repo" => {to: "/workspace/repo", mode: :ro}}
  end

  class AppleOptsAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :apple, image: "node:22-slim", network: :bridge
  end

  class BareDockerAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :docker
  end

  def setup
    skip "agent wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  def test_docker_opts_hash_resolves_to_hardened_container
    sandbox = DockerOptsAgent.new.sandbox

    assert_instance_of Nexo::Sandboxes::Container, sandbox
    assert_equal :docker, sandbox.runtime
    assert_equal "node:22-slim", sandbox.image
    assert_equal "/workspace", sandbox.cwd

    argv = sandbox.send(:run_argv).join(" ")
    assert_includes argv, "--network none"
    assert_includes argv, "--cap-drop ALL"
    assert_includes argv, "--read-only"
    assert_includes argv, "--security-opt no-new-privileges"
    assert_includes argv, "-v /host/repo:/workspace/repo:ro"
  end

  def test_apple_opts_hash_threads_runtime_and_network
    sandbox = AppleOptsAgent.new.sandbox
    argv = sandbox.send(:run_argv)

    assert_instance_of Nexo::Sandboxes::Container, sandbox
    assert_equal :apple, sandbox.runtime
    assert_equal "container", argv.first
    assert_includes argv.join(" "), "--network bridge"
  end

  def test_container_cwd_defaults_to_workspace_not_host_cwd
    Dir.mktmpdir do |dir|
      sandbox = DockerOptsAgent.new(cwd: dir).sandbox

      # Host cwd never leaks into the container cwd — the host dir enters only
      # through a binds: entry.
      assert_equal "/workspace", sandbox.cwd
      refute_equal File.expand_path(dir), sandbox.cwd
    end
  end

  def test_explicit_container_cwd_option_is_honored
    klass = Class.new(Nexo::Agent) do
      model TEST_MODEL
      sandbox :docker, image: "alpine", cwd: "/srv/app"
    end

    assert_equal "/srv/app", klass.new.sandbox.cwd
  end

  def test_bare_shorthand_without_image_raises_configuration_error
    assert_raises(Nexo::ConfigurationError) { BareDockerAgent.new }
  end

  def test_virtual_and_local_branches_are_unchanged
    virtual = Class.new(Nexo::Agent) do
      model TEST_MODEL
      sandbox :virtual
    end
    assert_instance_of Nexo::Sandboxes::Virtual, virtual.new.sandbox

    Dir.mktmpdir do |dir|
      local = Class.new(Nexo::Agent) do
        model TEST_MODEL
        sandbox :local
      end
      assert_instance_of Nexo::Sandboxes::Local, local.new(cwd: dir).sandbox
    end
  end

  def test_prebuilt_container_instance_passes_through_untouched
    container = Nexo::Sandboxes::Container.new(image: "alpine")
    agent = Class.new(Nexo::Agent) { model TEST_MODEL }.new(sandbox: container)

    assert_same container, agent.sandbox
  end
end
