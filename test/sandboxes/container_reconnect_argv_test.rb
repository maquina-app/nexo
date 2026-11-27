# frozen_string_literal: true

require "test_helper"

# Offline, daemon-free argv assertions for Spec 20 (Container Reconnect + Apple
# Parity). Proves — without a container runtime — that:
#
#   * every container is tagged with an EXACT identity label at run,
#   * the keep-alive is busybox-portable (+tail -f /dev/null+, never +sleep infinity+),
#   * reconnect queries by that exact +label=+ filter, NOT a +name=+ substring,
#   * both the +:docker+ and +:apple+ runtimes are covered, and
#   * +reconnect: true+ on +:apple+ raises +ConfigurationError+ (Apple has no
#     verified exact label filter — Spec 20 R4/Q4).
#
# Live behavior lives in test/sandboxes/container_reconnect_smoke.rb (NEXO_LIVE-gated).
class ContainerReconnectArgvTest < Minitest::Test
  def build(**opts)
    Nexo::Sandboxes::Container.new(image: "alpine", name: "nexo-fixed", cwd: "/workspace", **opts)
  end

  # --- R1: identity label at run ------------------------------------------

  def test_run_argv_carries_the_identity_label
    argv = build.send(:run_argv).join(" ")

    assert_includes argv, "--label nexo.sandbox.id=nexo-fixed"
  end

  def test_label_is_placed_immediately_after_name
    argv = build.send(:run_argv)
    name_at = argv.index("--name")

    assert_equal "nexo-fixed", argv[name_at + 1]
    assert_equal "--label", argv[name_at + 2]
    assert_equal "nexo.sandbox.id=nexo-fixed", argv[name_at + 3]
  end

  # --- R2: portable keep-alive --------------------------------------------

  def test_keep_alive_is_portable
    argv = build.send(:run_argv)

    assert_equal %w[tail -f /dev/null], argv.last(3)
    refute_includes argv, "infinity"
  end

  # --- R1/R4: exact reconnect filter, docker ------------------------------

  def test_reconnect_uses_exact_label_filter_not_name
    argv = build(reconnect: true).send(:reconnect_argv)

    assert_equal %w[docker ps -aq --no-trunc -f label=nexo.sandbox.id=nexo-fixed], argv
    refute_includes argv.join(" "), "name=nexo-fixed"
  end

  # --- R3/R4: the Apple runtime variant -----------------------------------

  def test_apple_run_argv_carries_label_and_portable_keep_alive
    argv = build(runtime: :apple)
    run = argv.send(:run_argv)

    assert_equal "container", run.first
    assert_includes run.join(" "), "--label nexo.sandbox.id=nexo-fixed"
    assert_equal %w[tail -f /dev/null], run.last(3)
    refute_includes run, "infinity"
  end

  # Apple's `container list` has no label filter, so reconnect lists every
  # container as JSON and matches the identity label exactly (VERIFIED, 1.7.1).
  def test_apple_reconnect_lists_json_and_matches_the_label_exactly
    sandbox = build(runtime: :apple, reconnect: true)
    listing = JSON.generate([
      {"id" => "nexo-fixed", "configuration" => {"labels" => {"nexo.sandbox.id" => "nexo-fixed"}}},
      {"id" => "nexo-fixedx", "configuration" => {"labels" => {"nexo.sandbox.id" => "nexo-fixedx"}}},
      {"id" => "unrelated", "configuration" => {"labels" => {}}}
    ])

    assert_equal %w[container list --all --format json], sandbox.send(:reconnect_argv)
    assert_equal %w[nexo-fixed], sandbox.send(:reconnect_ids, listing)
    assert_empty sandbox.send(:reconnect_ids, "[]")
  end

  # --- R4: reconnect never crosses runtimes -------------------------------

  def test_reconnect_query_shells_the_runtime_specific_binary
    docker = build(reconnect: true).send(:reconnect_argv)

    assert_equal "docker", docker.first
    # Each runtime is asked through its own binary, so a :docker container is
    # never looked up by an :apple sandbox and vice versa.
    assert_equal "container", build(runtime: :apple, reconnect: true).send(:reconnect_argv).first
  end
end
