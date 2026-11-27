# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.15 — Sandboxes::ContainerRunner answers ruby_llm's sandbox contract with a
# throwaway container per command. The argv is asserted offline; the live half
# needs NEXO_LIVE=1 and a running Docker daemon.
class ContainerRunnerTest < Minitest::Test
  def runner(**opts) = Nexo::Sandboxes::ContainerRunner.new(image: "alpine", **opts)

  def argv(runner, *command, **opts)
    defaults = {readable: [], writable: [], denied: [], directory: nil, env: {}}
    runner.send(:run_argv, "nexo-run-x", command, **defaults.merge(opts))
  end

  def test_requires_an_image_and_a_known_runtime
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes::ContainerRunner.new(image: nil) }
    assert_raises(Nexo::ConfigurationError) { runner(runtime: :podman) }
  end

  def test_every_run_is_hardened_and_removed
    args = argv(runner, "echo", "hi")

    assert_equal %w[docker run --rm --name nexo-run-x --network none --cap-drop ALL], args.first(9)
    assert_includes args.each_cons(2).to_a, %w[--security-opt no-new-privileges]
    assert_includes args, "--read-only"
    assert_includes args.each_cons(2).to_a, %w[--pids-limit 512]
    assert_equal %w[alpine echo hi], args.last(3)
  end

  # VERIFIED live on Apple `container` 1.7.1: it rejects --security-opt and
  # --pids-limit, and writes progress to stderr unless told not to.
  def test_the_apple_runtime_gets_only_the_flags_its_cli_accepts
    args = argv(runner(runtime: :apple), "echo", "hi")

    assert_equal %w[container run --rm --name nexo-run-x --network none --cap-drop ALL --progress none], args.first(11)
    refute_includes args, "--security-opt"
    refute_includes args, "--pids-limit"
    assert_includes args, "--read-only"
  end

  def test_one_string_is_a_shell_command
    assert_equal ["alpine", "sh", "-c", "echo hi | wc -c"], argv(runner, "echo hi | wc -c").last(4)
  end

  def test_grants_are_bound_at_their_own_paths
    args = argv(runner, "true", readable: ["/data", "/work"], writable: ["/work"], directory: "/work",
      env: {"LANG" => "C"})
    pairs = args.each_cons(2).to_a

    assert_includes pairs, ["-v", "/data:/data:ro"]
    assert_includes pairs, ["-v", "/work:/work:rw"]
    refute_includes pairs, ["-v", "/work:/work:ro"], "a writable path is not also bound read-only"
    assert_includes pairs, ["-w", "/work"]
    assert_includes pairs, ["-e", "LANG=C"]
  end

  def test_a_denied_path_is_covered
    Dir.mktmpdir do |dir|
      file = File.join(dir, "secret.txt")
      File.write(file, "x")
      pairs = argv(runner, "true", readable: [dir], denied: [dir, file]).each_cons(2).to_a

      assert_includes pairs, ["--tmpfs", "#{dir}:ro"]
      assert_includes pairs, ["-v", "/dev/null:#{file}:ro"]
    end
  end

  def test_an_argument_with_shell_metacharacters_stays_one_argument
    assert_equal ["alpine", "echo", "a; rm -rf /"], argv(runner, "echo", "a; rm -rf /").last(3)
  end

  def test_the_network_is_the_runners_own
    assert_includes argv(runner(network: :bridge), "true").each_cons(2).to_a, %w[--network bridge]
  end

  # --- live ------------------------------------------------------------------

  def live_runner
    skip "set NEXO_LIVE=1 to run live container smoke tests" unless ENV["NEXO_LIVE"] == "1"
    built = runner(image: ENV["NEXO_CONTAINER_IMAGE"] || "alpine")
    skip "docker is not available" unless built.supported?
    built
  end

  def test_live_a_command_runs_and_reports_its_exit_code
    result = live_runner.run("echo out; echo err >&2; exit 3", timeout: 30)

    assert_equal ["out\n", "err\n", 3, false], [result.stdout, result.stderr, result.exit_code, result.timed_out?]
  end

  def test_live_as_the_isolation_of_the_local_shell
    built = live_runner
    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.txt"), "TOP SECRET")
        sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: built)

        inside = sandbox.shell("echo made > made.txt && cat made.txt")
        peek = sandbox.shell("cat #{File.realpath(outside)}/secret.txt 2>&1; ls /Users 2>&1 | head -1")
        net = sandbox.shell("wget -q -T 3 -O - http://example.com >/dev/null 2>&1 && echo NET_OK; true")

        assert_equal "made\n", inside[:stdout]
        assert_equal "made\n", File.read(File.join(dir, "made.txt"))
        refute_includes peek[:stdout], "TOP SECRET"
        refute_includes net[:stdout], "NET_OK"
        assert_empty sandbox.hardening_gaps
      end
    end
  end

  def test_live_a_timeout_kills_the_container
    result = live_runner.run("sleep 30", timeout: 2)

    assert_predicate result, :timed_out?
    assert_empty `docker ps -q --filter name=nexo-run-`.strip
  end
end
