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

  # --- #never_allows? (attach-time gating) ---------------------------------
  #
  # The predicate exists so Agent#chat can leave a guaranteed-to-fail tool out of
  # the schema. Its contract is that it agrees with #authorize! — these tests pin
  # the agreement rather than the implementation, so the two cannot drift.

  def test_never_allows_privileged_capabilities_under_read_only
    perms = Nexo::Permissions.new(mode: :read_only)

    Nexo::Permissions::PRIVILEGED.each do |cap|
      assert perms.never_allows?(cap), "#{cap} should be statically denied"
      assert_raises(Nexo::Permissions::Denied) { perms.authorize!(cap) }
    end
  end

  def test_never_allows_is_false_for_read_and_glob
    perms = Nexo::Permissions.new(mode: :read_only)

    refute perms.never_allows?(:read)
    refute perms.never_allows?(:glob)
  end

  def test_allow_list_beats_read_only
    perms = Nexo::Permissions.new(mode: :read_only, allow: %i[read glob shell])

    refute perms.never_allows?(:shell)
    assert perms.authorize!(:shell, "ls")
    assert perms.never_allows?(:write)
  end

  # Every non-read_only mode decides per call, so nothing is knowable ahead of
  # time. :approve in particular must reach the gate to raise ApprovalRequired.
  def test_never_allows_is_false_for_per_call_modes
    %i[auto ask approve].each do |mode|
      perms = Nexo::Permissions.new(mode: mode)

      Nexo::Permissions::PRIVILEGED.each do |cap|
        refute perms.never_allows?(cap), "#{mode} decides #{cap} per call"
      end
    end
  end

  # The predicate reports the gate's behavior, so anything it calls statically
  # denied must in fact raise for every mode/capability pair.
  def test_never_allows_never_contradicts_authorize
    Nexo::Permissions::MODES.each do |mode|
      perms = Nexo::Permissions.new(mode: mode, on_ask: ->(*) { true }, decision: {approved: true})

      (Nexo::Permissions::PRIVILEGED + %i[read glob]).each do |cap|
        next unless perms.never_allows?(cap)

        assert_raises(Nexo::Permissions::Denied, "#{mode}/#{cap} claimed never-allowed") do
          perms.authorize!(cap, "detail")
        end
      end
    end
  end
end
