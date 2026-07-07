# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# R4 — read-before-write + stale guard, exercised against a real temp-dir Local
# sandbox (real File.mtime).
class ToolsReadBeforeWriteTest < Minitest::Test
  def with_local
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)
      perms = Nexo::Permissions.new(mode: :auto, allow: %i[read glob write shell])
      tracker = Nexo::ReadTracker.new
      reader = Nexo::Tools::ReadFile.new(sandbox: sandbox, permissions: perms, tracker: tracker)
      writer = Nexo::Tools::WriteFile.new(sandbox: sandbox, permissions: perms, tracker: tracker)
      yield dir, sandbox, reader, writer
    end
  end

  def test_new_file_writes_freely
    with_local { |_d, _s, _r, w| assert w.execute(path: "new.txt", content: "hi")[:ok] }
  end

  def test_overwrite_without_read_is_blocked
    with_local do |_d, s, _r, w|
      s.write("exists.txt", "old")
      result = w.execute(path: "exists.txt", content: "new")
      assert result[:error]
      assert_includes result[:error], "read"
      assert_equal "old", s.read("exists.txt") # nothing written
    end
  end

  def test_overwrite_after_read_succeeds
    with_local do |_d, s, r, w|
      s.write("exists.txt", "old")
      r.execute(path: "exists.txt")
      assert w.execute(path: "exists.txt", content: "new")[:ok]
      assert_equal "new", s.read("exists.txt")
    end
  end

  def test_stale_write_is_blocked_when_file_changed_since_read
    with_local do |dir, s, r, w|
      path = File.join(dir, "exists.txt")
      s.write("exists.txt", "old")
      r.execute(path: "exists.txt")
      # Simulate an external mutation after the read. Force a distinguishable
      # mtime (mtime granularity is best-effort; bump it explicitly so the test
      # is robust regardless of filesystem clock resolution — see spec R4).
      File.write(path, "changed underneath")
      File.utime(Time.now + 5, Time.now + 5, path)

      result = w.execute(path: "exists.txt", content: "mine")
      assert result[:error]
      assert_includes result[:error], "stale"
      assert_equal "changed underneath", s.read("exists.txt") # nothing written
    end
  end

  def test_guard_is_off_without_a_tracker
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)
      perms = Nexo::Permissions.new(mode: :auto, allow: %i[read glob write shell])
      writer = Nexo::Tools::WriteFile.new(sandbox: sandbox, permissions: perms) # no tracker
      sandbox.write("exists.txt", "old")
      # Without a tracker the guard is off — direct-construction behavior.
      assert writer.execute(path: "exists.txt", content: "new")[:ok]
    end
  end

  def test_virtual_sandbox_guard_is_skipped
    sandbox = Nexo::Sandboxes::Virtual.new
    perms = Nexo::Permissions.new(mode: :auto, allow: %i[read glob write shell])
    tracker = Nexo::ReadTracker.new
    writer = Nexo::Tools::WriteFile.new(sandbox: sandbox, permissions: perms, tracker: tracker)
    sandbox.write("f.txt", "old")
    # Virtual#mtime is nil, so the guard is skipped even with a tracker present.
    assert writer.execute(path: "f.txt", content: "new")[:ok]
  end
end
