# frozen_string_literal: true

require "test_helper"

class PermissionsTest < Minitest::Test
  def test_read_only_allows_read_and_glob
    perms = Nexo::Permissions.new(mode: :read_only)

    assert perms.authorize!(:read, "a.rb")
    assert perms.authorize!(:glob, "*.rb")
  end

  def test_read_only_denies_write_and_shell
    perms = Nexo::Permissions.new(mode: :read_only)

    assert_raises(Nexo::Permissions::Denied) { perms.authorize!(:write, "a.rb") }
    assert_raises(Nexo::Permissions::Denied) { perms.authorize!(:shell, "ls") }
  end

  def test_auto_allows_everything
    perms = Nexo::Permissions.new(mode: :auto, allow: [])

    assert perms.authorize!(:read)
    assert perms.authorize!(:write)
    assert perms.authorize!(:shell)
    assert perms.authorize!(:glob)
  end

  def test_ask_honors_callback_return
    granted = Nexo::Permissions.new(mode: :ask, allow: [], on_ask: ->(_cap, _detail) { true })
    denied = Nexo::Permissions.new(mode: :ask, allow: [], on_ask: ->(_cap, _detail) { false })

    assert granted.authorize!(:write, "a.rb")
    assert_raises(Nexo::Permissions::Denied) { denied.authorize!(:write, "a.rb") }
  end

  def test_ask_passes_capability_and_detail_to_callback
    seen = nil
    capture = ->(cap, detail) {
      seen = [cap, detail]
      true
    }
    perms = Nexo::Permissions.new(mode: :ask, allow: [], on_ask: capture)

    perms.authorize!(:shell, "rm -rf /")

    assert_equal [:shell, "rm -rf /"], seen
  end

  def test_ask_with_no_callback_denies
    perms = Nexo::Permissions.new(mode: :ask, allow: [])

    assert_raises(Nexo::Permissions::Denied) { perms.authorize!(:write, "a.rb") }
  end

  def test_unknown_mode_raises_argument_error
    assert_raises(ArgumentError) { Nexo::Permissions.new(mode: :bogus) }
  end
end
