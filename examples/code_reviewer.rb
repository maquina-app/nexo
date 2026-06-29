# frozen_string_literal: true

# The five-line agent — Nexo's success criterion. Run it against any
# ruby_llm-supported model by setting NEXO_MODEL (e.g. a local gemma3:12b via
# Ollama, or a hosted model). Nothing here is vendor-specific.
#
#   NEXO_MODEL=gemma3:12b ruby -Ilib examples/code_reviewer.rb /path/to/repo
require "nexo"

class CodeReviewer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL") # any ruby_llm-supported model; locally gemma3:12b via Ollama
  sandbox :local
  permissions :read_only

  instructions "You are a careful code reviewer. Read files and report issues. Do not write files."
end

if __FILE__ == $PROGRAM_NAME
  repo = ARGV[0] || Dir.pwd
  response = CodeReviewer.new(cwd: repo).prompt("Review the auth module")
  puts response.content
end
