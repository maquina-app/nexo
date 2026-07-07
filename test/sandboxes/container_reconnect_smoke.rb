# frozen_string_literal: true

require "test_helper"

# Optional, manual, env-gated live smoke for Spec 20 reconnect against a REAL
# docker daemon. Skipped unless NEXO_LIVE=1 and docker is on PATH, so it is never
# part of the offline core suite.
#
#   NEXO_LIVE=1 bundle exec rake test TEST=test/sandboxes/container_reconnect_smoke.rb
#
# It proves the EXACT-identity reconnect guarantee end to end:
#   1. create a labeled container under a fixed name,
#   2. build a second sandbox with the same name: + reconnect: true and assert it
#      reattaches the SAME id (not a fresh container),
#   3. create a DECOY whose name is a superstring (<name>x) and assert reconnect
#      still attaches the original — the decoy is excluded by the exact label filter,
#   4. exec inside the reattached container, then close both.
class ContainerReconnectSmokeTest < Minitest::Test
  def setup
    skip "set NEXO_LIVE=1 to run live container smoke tests" unless ENV["NEXO_LIVE"] == "1"
    skip "docker binary not on PATH" unless system("command -v docker > /dev/null 2>&1")

    @image = ENV["NEXO_CONTAINER_IMAGE"] || "alpine"
    @name = "nexo-reconnect-#{Nexo.generate_run_id}"
    @decoy_cid = nil
  end

  def teardown
    # reconnect: true means close leaves the shared container in place, so force-
    # remove the real container (by its name) plus the decoy explicitly.
    system("docker", "rm", "-f", @decoy_cid, out: File::NULL, err: File::NULL) if @decoy_cid
    system("docker", "rm", "-f", @name, out: File::NULL, err: File::NULL)
    @reattached&.close
    @origin&.close
  end

  def test_reconnect_attaches_the_same_container_and_excludes_a_superstring_decoy
    @origin = build(reconnect: true)
    @origin.write("marker.txt", "origin") # forces ensure_started!
    origin_cid = @origin.instance_variable_get(:@cid)
    refute_nil origin_cid

    # A decoy whose name CONTAINS the real name but carries a different identity
    # label. A substring (name=) match would wrongly find it; the exact label
    # filter must not.
    @decoy_cid = `docker run -d --name #{@name}x --label nexo.sandbox.id=#{@name}x #{@image} tail -f /dev/null`.strip
    refute_empty @decoy_cid

    @reattached = build(reconnect: true)
    @reattached.write("marker2.txt", "reattached") # forces reconnect
    reattached_cid = @reattached.instance_variable_get(:@cid)

    assert_equal origin_cid, reattached_cid, "reconnect must attach the same container id"
    refute_equal @decoy_cid, reattached_cid, "reconnect must NOT attach the superstring decoy"

    # The reattached handle sees the original container's filesystem.
    assert_equal "origin", @reattached.read("marker.txt")
    assert_equal 0, @reattached.shell("true")[:status]
  end

  private

  def build(**opts)
    Nexo::Sandboxes::Container.new(image: @image, name: @name, cwd: "/workspace", **opts)
  end
end
