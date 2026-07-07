# frozen_string_literal: true

require "test_helper"

# R5 — scoped :ask predicate. ask_when narrows which actions actually prompt;
# it never widens authority. Asserted with real recording procs, not mocks.
class PermissionsAskWhenTest < Minitest::Test
  def test_ask_when_false_auto_allows_without_asking
    asked = []
    perms = Nexo::Permissions.new(mode: :ask,
      on_ask: ->(c, d) {
        asked << [c, d]
        true
      },
      ask_when: ->(cap, detail) { detail.to_s.start_with?("/protected") })
    assert perms.authorize!(:write, "/tmp/ok.txt")   # scoped out -> auto-allow
    assert_empty asked                                # on_ask never called
  end

  def test_ask_when_true_consults_on_ask
    perms = Nexo::Permissions.new(mode: :ask,
      on_ask: ->(_c, _d) { false },
      ask_when: ->(_cap, detail) { detail.to_s.start_with?("/protected") })
    assert_raises(Nexo::Permissions::Denied) { perms.authorize!(:write, "/protected/secret") }
  end

  def test_ask_when_true_and_on_ask_true_allows
    asked = []
    perms = Nexo::Permissions.new(mode: :ask,
      on_ask: ->(c, d) {
        asked << [c, d]
        true
      },
      ask_when: ->(_cap, _detail) { true })
    assert perms.authorize!(:write, "/protected/secret")
    assert_equal [[:write, "/protected/secret"]], asked
  end

  def test_unset_ask_when_asks_for_everything
    asked = []
    perms = Nexo::Permissions.new(mode: :ask, on_ask: ->(c, d) {
      asked << [c, d]
      true
    })
    assert perms.authorize!(:write, "/anything")
    assert_equal [[:write, "/anything"]], asked   # backward-compatible: always asks
  end
end
