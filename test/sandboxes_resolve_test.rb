# frozen_string_literal: true

require "test_helper"

class SandboxesResolveTest < Minitest::Test
  def test_symbols_and_instance
    assert_instance_of Nexo::Sandboxes::Virtual, Nexo::Sandboxes.resolve(:virtual, cwd: "/x")
    assert_instance_of Nexo::Sandboxes::Local, Nexo::Sandboxes.resolve(:local, cwd: "/x")
    inst = Nexo::Sandboxes::Virtual.new
    assert_same inst, Nexo::Sandboxes.resolve(inst, cwd: "/x")
  end

  def test_local_uses_the_given_cwd
    sb = Nexo::Sandboxes.resolve(:local, cwd: "/repo")
    assert_equal File.expand_path("/repo"), sb.cwd
  end

  def test_container_shorthands_require_image
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes.resolve(:docker, cwd: "/x") }
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes.resolve(:apple, cwd: "/x") }
  end

  def test_container_hash_builds_hardened_container
    sb = Nexo::Sandboxes.resolve({type: :docker, image: "node:22-slim"}, cwd: "/x")
    assert_instance_of Nexo::Sandboxes::Container, sb
    assert_equal :docker, sb.runtime
    assert_equal "/workspace", sb.cwd # host cwd NOT applied to a container
  end

  def test_container_hash_honors_explicit_cwd
    sb = Nexo::Sandboxes.resolve({type: :apple, image: "img", cwd: "/srv"}, cwd: "/x")
    assert_instance_of Nexo::Sandboxes::Container, sb
    assert_equal :apple, sb.runtime
    assert_equal "/srv", sb.cwd
  end

  def test_local_hash_prefers_explicit_cwd_then_falls_back
    assert_equal File.expand_path("/here"),
      Nexo::Sandboxes.resolve({type: :local, cwd: "/here"}, cwd: "/x").cwd
    assert_equal File.expand_path("/x"),
      Nexo::Sandboxes.resolve({type: :local}, cwd: "/x").cwd
  end

  def test_unknown_value_raises
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes.resolve(:nope, cwd: "/x") }
  end

  def test_unknown_hash_type_raises
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes.resolve({type: :nope}, cwd: "/x") }
  end
end
