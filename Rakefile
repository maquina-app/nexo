# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "standard/rake"

# Documentation build + coverage gate (Spec 17). RDoc is a Ruby default gem, so
# neither `rake doc` nor `rake doc:coverage` adds a runtime or dev dependency.
require "rdoc/task"

# RDoc renders the README/guides (which carry UTF-8 glyphs) by reading them with
# Encoding.default_external; some CI environments start US-ASCII, under which the
# HTML generation raises Encoding::InvalidByteSequenceError. Pin UTF-8 so the doc
# build is environment-independent (the test suite pins the same in test_helper).
Encoding.default_external = Encoding::UTF_8 if Encoding.default_external == Encoding::US_ASCII

# Naming the task :doc gives us `rake doc` (generate the API site into doc/,
# gitignored) plus, for free, `rake doc:coverage` — RDoc's own coverage report.
# Verified against rdoc 8.0.0: the coverage run exits non-zero (SystemExit) unless
# every public API is documented, so `rake doc:coverage` is a real CI gate with no
# bespoke parser to maintain. The generated site includes the README landing page,
# the docs/*.md guides, and the lib/**/*.rb API.
RDoc::Task.new(:doc) do |rd|
  rd.main = "README.md"
  rd.rdoc_files.include("README.md", "docs/*.md", "lib/**/*.rb")
  # Generator template files are boilerplate copied verbatim into a host app
  # (migrations land in the host's db/migrate, the initializer in config/) — they
  # are not part of the gem's Ruby API, so they belong in neither the generated
  # API site nor the coverage denominator.
  rd.rdoc_files.exclude("lib/generators/**/templates/*.rb")
  rd.rdoc_dir = "doc"
end

# NOTE: `default` intentionally stays test + standard — `rake doc`/`doc:coverage`
# are not part of the default run, so `bundle exec rake test` is untouched.
task default: %i[test standard]
