# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Skills.materialize copies a skill's bundled files INTO a sandbox, through the
# sandbox's own #write, so the same call works on :local, :container and :remote.
#
# A skill lives under skills_path — outside every sandbox — so its scripts/ and
# assets/ are unreachable to the permission-gated tools until they are staged.
class SkillsMaterializeTest < Minitest::Test
  # Records writes instead of touching a filesystem; stands in for any tier.
  class RecordingSandbox < Nexo::Sandbox
    attr_reader :writes

    def initialize = @writes = {}

    def write(path, content)
      @writes[path] = content
      path
    end

    def read(path)
      @writes.fetch(path) { raise Errno::ENOENT, path }
    end
  end

  def with_skill(&)
    Dir.mktmpdir do |root|
      dir = File.join(root, "dashboard_designer")
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      FileUtils.mkdir_p(File.join(dir, "assets"))
      File.write(File.join(dir, "SKILL.md"), "---\nname: dashboard_designer\ndescription: d\n---\n\nBody\n")
      File.write(File.join(dir, "scripts", "render.rb"), "puts :rendered\n")
      File.write(File.join(dir, "assets", "template.html"), "<html>__DIGEST_JSON__</html>\n")

      previous = Nexo.config.skills_path
      Nexo.configure { |c| c.skills_path = root }
      yield
    ensure
      Nexo.configure { |c| c.skills_path = previous }
    end
  end

  def test_returns_sandbox_relative_paths_grouped_by_kind
    with_skill do
      staged = Nexo::Skills.materialize(:dashboard_designer, into: RecordingSandbox.new)

      assert_equal ["scripts/render.rb"], staged[:scripts]
      assert_equal ["assets/template.html"], staged[:assets]
    end
  end

  def test_writes_the_file_contents_through_the_sandbox
    with_skill do
      sandbox = RecordingSandbox.new
      Nexo::Skills.materialize(:dashboard_designer, into: sandbox)

      assert_equal "puts :rendered\n", sandbox.writes["scripts/render.rb"]
      assert_includes sandbox.writes["assets/template.html"], "__DIGEST_JSON__"
    end
  end

  def test_omits_kinds_the_skill_ships_nothing_for
    with_skill do
      staged = Nexo::Skills.materialize(:dashboard_designer, into: RecordingSandbox.new)

      refute_includes staged.keys, :references
    end
  end

  def test_kinds_narrows_what_is_copied
    with_skill do
      sandbox = RecordingSandbox.new
      staged = Nexo::Skills.materialize(:dashboard_designer, into: sandbox, kinds: [:scripts])

      assert_equal [:scripts], staged.keys
      refute_includes sandbox.writes.keys, "assets/template.html"
    end
  end

  def test_overwrite_false_skips_files_already_present
    with_skill do
      sandbox = RecordingSandbox.new
      sandbox.write("scripts/render.rb", "BAKED INTO THE IMAGE")
      Nexo::Skills.materialize(:dashboard_designer, into: sandbox, overwrite: false)

      assert_equal "BAKED INTO THE IMAGE", sandbox.writes["scripts/render.rb"]
    end
  end

  def test_overwrite_true_replaces_a_tampered_file
    with_skill do
      sandbox = RecordingSandbox.new
      sandbox.write("scripts/render.rb", "TAMPERED")
      Nexo::Skills.materialize(:dashboard_designer, into: sandbox)

      assert_equal "puts :rendered\n", sandbox.writes["scripts/render.rb"]
    end
  end

  def test_accepts_an_already_loaded_skill
    with_skill do
      skill = Nexo::Skills.find(:dashboard_designer)
      staged = Nexo::Skills.materialize(skill, into: RecordingSandbox.new)

      assert_equal ["scripts/render.rb"], staged[:scripts]
    end
  end

  def test_raises_for_a_skill_that_does_not_exist
    with_skill do
      assert_raises(Nexo::Error) { Nexo::Skills.materialize(:nope, into: RecordingSandbox.new) }
    end
  end
end
