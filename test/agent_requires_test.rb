# frozen_string_literal: true

require "test_helper"

# The `requires` macro: checked once against Sandbox#environment before the
# first turn, reporting every unmet requirement at once. A scripted sandbox
# stands in for the far side — no daemon, no model.
class AgentRequiresTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  class ScriptedSandbox < Nexo::Sandbox
    attr_reader :probes

    def initialize(stdout)
      @stdout = stdout
      @probes = 0
    end

    def supports?(_cap) = true

    attr_reader :last_command

    def shell(command, timeout: 30)
      @probes += 1
      @last_command = command
      {stdout: @stdout, stderr: "", status: 0}
    end
  end

  PROVISIONED = "locale=C.UTF-8\ncmd=ruby\t/usr/bin/ruby\truby 4.0.0\n"
  NO_LOCALE = "locale=\ncmd=ruby\t/usr/bin/ruby\truby 4.0.0\n"
  BARE = "locale=\ncmd=sh\t/bin/sh\t\n"
  OLD_RUBY = "locale=C.UTF-8\ncmd=ruby\t/usr/bin/ruby\truby 2.7.8\n"

  class NeedsRuby < Nexo::Agent
    model TEST_MODEL
    requires commands: {"ruby" => ">= 3.1"}, locale: :utf8
  end

  class NeedsAnyRuby < Nexo::Agent
    model TEST_MODEL
    requires commands: {"ruby" => "*"}
  end

  class DeclaresNothing < Nexo::Agent
    model TEST_MODEL
  end

  # The case the default probe shortlist (ruby/python3/node/sh) cannot serve: a
  # command it has never heard of, and an absolute interpreter path — which is
  # exactly what you pin when the sandbox shell runs with a narrowed PATH.
  ABS_RUBY = "/opt/rubies/4.0.0/bin/ruby"

  class NeedsAbsoluteRuby < Nexo::Agent
    model TEST_MODEL
    requires commands: {ABS_RUBY => ">= 3.0"}
  end

  class NeedsCustomBinary < Nexo::Agent
    model TEST_MODEL
    requires commands: {"pandoc" => "*"}
  end

  def verify(klass, stdout)
    klass.new(sandbox: ScriptedSandbox.new(stdout)).verify_environment!
  end

  def test_a_provisioned_sandbox_passes
    assert_nil verify(NeedsRuby, PROVISIONED)
  end

  def test_an_agent_declaring_nothing_never_probes
    sandbox = ScriptedSandbox.new(BARE)
    DeclaresNothing.new(sandbox: sandbox).verify_environment!

    assert_equal 0, sandbox.probes, "declaring nothing must cost no probe at all"
  end

  # The container default: a full toolchain and no locale. Exactly the sandbox
  # that raised Encoding::InvalidByteSequenceError three frames into a JSON parse.
  def test_a_missing_locale_is_caught_even_when_the_interpreter_is_present
    e = assert_raises(Nexo::EnvironmentError) { verify(NeedsRuby, NO_LOCALE) }

    assert_includes e.message, "no locale set (needs a UTF-8 locale)"
    refute_includes e.message, "no ruby on PATH"
  end

  # One pass, not one round trip per missing thing.
  def test_every_unmet_requirement_is_reported_at_once
    e = assert_raises(Nexo::EnvironmentError) { verify(NeedsRuby, BARE) }

    assert_includes e.message, "no ruby on PATH"
    assert_includes e.message, "no locale set"
  end

  def test_a_version_below_the_constraint_is_reported_with_both_numbers
    e = assert_raises(Nexo::EnvironmentError) { verify(NeedsRuby, OLD_RUBY) }

    assert_includes e.message, "ruby 2.7.8 does not satisfy >= 3.1"
  end

  # Presence is the requirement when the version cannot be read: an unreadable
  # version is not evidence of a wrong one.
  def test_a_command_with_no_readable_version_satisfies_a_constraint
    assert_nil verify(NeedsAnyRuby, "locale=\ncmd=ruby\t/bin/ruby\t\n")
  end

  def test_star_accepts_any_version
    assert_nil verify(NeedsAnyRuby, OLD_RUBY)
  end

  # "no ruby" and "I never got to look" are different problems.
  def test_a_sandbox_that_cannot_be_probed_says_so_rather_than_blaming_the_command
    e = assert_raises(Nexo::EnvironmentError) do
      NeedsRuby.new(sandbox: Nexo::Sandboxes::Virtual.new).verify_environment!
    end

    assert_includes e.message, "could not inspect the sandbox"
    refute_includes e.message, "no ruby on PATH"
  end

  def test_an_exact_locale_requirement_rejects_a_different_utf8_locale
    klass = Class.new(Nexo::Agent) do
      model TEST_MODEL
      requires locale: "en_US.UTF-8"
    end
    e = assert_raises(Nexo::EnvironmentError) { verify(klass, PROVISIONED) }

    assert_includes e.message, "locale C.UTF-8 is not locale en_US.UTF-8"
  end

  def test_the_check_runs_once_per_agent
    sandbox = ScriptedSandbox.new(PROVISIONED)
    agent = NeedsRuby.new(sandbox: sandbox)
    3.times { agent.verify_environment! }

    assert_equal 1, sandbox.probes
  end

  def test_requires_is_inherited_by_a_subclass
    child = Class.new(NeedsRuby)

    assert_equal({commands: {"ruby" => ">= 3.1"}, locale: :utf8}, child.requires)
  end

  def test_requires_defaults_to_nil
    assert_nil DeclaresNothing.requires
  end

  # Regression (0.9.0): #verify_environment! probed Sandbox#environment with its
  # DEFAULT command shortlist, so any declared name outside ruby/python3/node/sh
  # was never looked for and always reported as missing — including the absolute
  # interpreter path that is the whole reason to pin one.
  def test_a_declared_absolute_path_is_the_thing_probed_for
    sandbox = ScriptedSandbox.new("locale=C.UTF-8\ncmd=#{ABS_RUBY}\t#{ABS_RUBY}\truby 4.0.0\n")
    NeedsAbsoluteRuby.new(sandbox: sandbox).verify_environment!

    assert_includes sandbox.last_command, ABS_RUBY,
      "the probe must look for the declared name, not the default shortlist"
  end

  def test_a_declared_command_outside_the_default_shortlist_is_probed_for
    sandbox = ScriptedSandbox.new("locale=C.UTF-8\ncmd=pandoc\t/usr/bin/pandoc\tpandoc 3.1\n")
    NeedsCustomBinary.new(sandbox: sandbox).verify_environment!

    assert_includes sandbox.last_command, "pandoc"
  end

  def test_an_absolute_path_that_is_genuinely_absent_still_raises
    error = assert_raises(Nexo::EnvironmentError) do
      NeedsAbsoluteRuby.new(sandbox: ScriptedSandbox.new(BARE)).verify_environment!
    end

    assert_includes error.message, "no #{ABS_RUBY} on PATH"
  end
end
