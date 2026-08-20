# frozen_string_literal: true

require "test_helper"

# Offline, daemon-free: asserts the exact Open3 argv the Container sandbox would
# run for a given config. No container runtime is touched. Live runs live in
# test/sandboxes/container_live_test.rb (NEXO_LIVE-gated).
class ContainerArgvTest < Minitest::Test
  def build(**opts)
    Nexo::Sandboxes::Container.new(image: "node:22-slim", cwd: "/workspace", **opts)
  end

  def test_run_argv_is_hardened_by_default
    argv = build.send(:run_argv)
    joined = argv.join(" ")

    assert_equal "docker", argv.first
    assert_includes joined, "--network none"
    assert_includes joined, "--cap-drop ALL"
    assert_includes joined, "--read-only"
    assert_includes joined, "--security-opt no-new-privileges"
    assert_includes joined, "--tmpfs /workspace:rw"
    assert_includes joined, "--pids-limit 512"
    assert_includes joined, "-w /workspace"
    assert_equal %w[tail -f /dev/null], argv.last(3)
    assert_equal "node:22-slim", argv[-4]
  end

  def test_binds_default_to_read_only
    argv = build(binds: {"/host/proj" => "/workspace/proj"}).send(:run_argv).join(" ")

    assert_includes argv, "-v /host/proj:/workspace/proj:ro"
  end

  def test_bind_can_be_made_writable_explicitly
    argv = build(binds: {"/host/proj" => {to: "/workspace/proj", mode: :rw}}).send(:run_argv).join(" ")

    assert_includes argv, "-v /host/proj:/workspace/proj:rw"
  end

  # --- runtime capability differences -------------------------------------------
  #
  # Apple's `container` CLI rejects --security-opt and --pids-limit outright, and its
  # --network takes the name of an existing network (there is no `none`). Passing
  # docker's spelling made `container run` exit before the sandbox ever started, so
  # `runtime: :apple` could not start a container at all.

  def test_apple_runtime_omits_flags_its_cli_rejects
    argv = build(runtime: :apple).send(:run_argv).join(" ")

    assert_equal "container", build(runtime: :apple).send(:run_argv).first
    refute_includes argv, "--security-opt"
    refute_includes argv, "--pids-limit"
  end

  # Verified live: Apple's CLI DOES accept `--network none` and the container runs.
  def test_apple_runtime_keeps_the_none_network
    argv = build(runtime: :apple, network: :none).send(:run_argv).join(" ")

    assert_includes argv, "--network none"
  end

  def test_apple_runtime_keeps_every_flag_its_cli_does_support
    argv = build(runtime: :apple, memory: "512m", cpus: 2,
      binds: {"/host/proj" => "/workspace/proj"}).send(:run_argv).join(" ")

    assert_includes argv, "--cap-drop ALL"
    assert_includes argv, "--read-only"
    assert_includes argv, "--tmpfs /workspace:rw"
    assert_includes argv, "--memory 512m"
    assert_includes argv, "--cpus 2"
    assert_includes argv, "-v /host/proj:/workspace/proj:ro"
  end

  def test_docker_runtime_is_unchanged
    argv = build(runtime: :docker, network: :none).send(:run_argv).join(" ")

    assert_includes argv, "--security-opt no-new-privileges"
    assert_includes argv, "--pids-limit 512"
    assert_includes argv, "--network none"
  end

  # Hardening that a runtime cannot express is REPORTED, never dropped silently —
  # running with weaker isolation than the caller asked for must be visible.
  def test_hardening_gaps_are_reported_for_apple
    gaps = build(runtime: :apple, network: :none).hardening_gaps.join(" ")

    assert_includes gaps, "--security-opt"
    assert_includes gaps, "--pids-limit"
  end

  # Apple accepts --tmpfs but the mount is NOT writable under --read-only, so a
  # read-only rootfs leaves the agent with no writable workspace at all. Verified live.
  def test_apple_reports_that_a_read_only_rootfs_has_no_writable_scratch
    gaps = build(runtime: :apple, readonly_rootfs: true).hardening_gaps.join(" ")

    assert_includes gaps, "--tmpfs is not writable"
    assert_includes gaps, "readonly_rootfs: false"
  end

  def test_apple_reports_no_scratch_gap_when_the_rootfs_is_writable
    gaps = build(runtime: :apple, readonly_rootfs: false).hardening_gaps.join(" ")

    refute_includes gaps, "--tmpfs"
  end

  def test_hardening_gaps_are_empty_for_docker
    assert_empty build(runtime: :docker, network: :none).hardening_gaps
  end

  def test_network_and_runtime_are_overridable
    argv = build(runtime: :apple, network: :bridge).send(:run_argv)

    assert_equal "container", argv.first
    assert_includes argv.join(" "), "--network bridge"
  end

  def test_env_vars_become_one_e_flag_each
    argv = build(env: {"FOO" => "bar", "BAZ" => "qux"}).send(:run_argv).join(" ")

    assert_includes argv, "-e FOO=bar"
    assert_includes argv, "-e BAZ=qux"
  end

  def test_cap_add_restores_individual_capabilities
    argv = build(cap_add: %w[NET_BIND_SERVICE]).send(:run_argv).join(" ")

    assert_includes argv, "--cap-drop ALL"
    assert_includes argv, "--cap-add NET_BIND_SERVICE"
  end

  def test_readonly_rootfs_false_omits_read_only_and_tmpfs
    argv = build(readonly_rootfs: false).send(:run_argv).join(" ")

    refute_includes argv, "--read-only"
    refute_includes argv, "--tmpfs"
  end

  def test_resource_and_user_knobs_are_opt_in
    argv = build(memory: "512m", cpus: "1.5", user: "1000:1000").send(:run_argv).join(" ")

    assert_includes argv, "--memory 512m"
    assert_includes argv, "--cpus 1.5"
    assert_includes argv, "--user 1000:1000"
  end

  def test_pids_limit_nil_omits_the_flag
    argv = build(pids_limit: nil).send(:run_argv).join(" ")

    refute_includes argv, "--pids-limit"
  end

  def test_image_is_required
    assert_raises(Nexo::ConfigurationError) do
      Nexo::Sandboxes::Container.new(cwd: "/workspace")
    end
  end

  def test_unknown_runtime_raises_configuration_error
    assert_raises(Nexo::ConfigurationError) do
      Nexo::Sandboxes::Container.new(image: "x", runtime: :podman)
    end
  end

  def test_path_escape_is_blocked
    assert_raises(SecurityError) { build.send(:guard_path, "/etc/passwd") }
    assert_raises(SecurityError) { build.send(:guard_path, "../escape") }
  end

  def test_guard_path_allows_paths_within_cwd
    assert_equal "/workspace/sub/file.txt", build.send(:guard_path, "sub/file.txt")
    assert_equal "/workspace", build.send(:guard_path, ".")
  end

  def test_exec_argv_shape
    sandbox = build
    sandbox.instance_variable_set(:@cid, "abc123")

    assert_equal %w[docker exec abc123 cat -- /workspace/x], sandbox.send(:exec_argv, "cat", "--", "/workspace/x")
    assert_equal %w[docker exec -i abc123 sh], sandbox.send(:exec_argv, "sh", interactive: true)
  end

  def test_supports_shell_unlike_virtual
    sandbox = build

    assert sandbox.supports?(:shell)
    assert sandbox.supports?(:read)
    refute sandbox.supports?(:network)
  end

  def test_instructions_describes_the_environment
    text = build.instructions

    assert_includes text, "docker container"
    assert_includes text, "node:22-slim"
    assert_includes text, "/workspace"
    assert_includes text, "network none"
  end

  def test_default_name_is_generated
    sandbox = build
    name = sandbox.instance_variable_get(:@name)

    assert_match(/\Anexo-/, name)
  end
end
