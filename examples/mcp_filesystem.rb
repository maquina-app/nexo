# frozen_string_literal: true

# Verification example — MCP seam + permission gate, NO AUTH REQUIRED.
#
# Uses the official filesystem MCP server (npx, no credentials) so you can watch the
# safe-by-default gate in action end to end:
#   * read tools are on the mcp_allow list  -> the model can use them
#   * write_file is NOT on the list          -> the gate returns { error: ... } (denied)
#
# Requires: ruby_llm-mcp installed, `npx` on PATH, and a model.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b ruby -Ilib examples/mcp_filesystem.rb /tmp
#
# Nothing here is provider-specific: set NEXO_MODEL to any ruby_llm-supported model.
require "nexo"

class FileExplorer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")          # provider-neutral; e.g. gemma3:12b via Ollama
  permissions :read_only                 # safe default

  # Reached through an MCP server — no vendor SDK. The server exposes read_file,
  # list_directory, search_files, write_file, etc.
  mcp :fs,
    transport: :stdio,
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", ENV.fetch("FS_ROOT", "/tmp")]

  # Opt IN to read tools only. write_file is deliberately absent -> denied by the gate.
  mcp_allow %w[read_file read_text_file list_directory search_files directory_tree]

  instructions "You explore a filesystem via MCP tools. Read and list only; never modify files."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  root = ARGV[0] || ENV.fetch("FS_ROOT", "/tmp")
  agent = FileExplorer.new
  begin
    puts "== Allowed path: listing + reading under #{root} =="
    puts agent.prompt("List the files in #{root} and summarize what the first text file contains.").content

    puts "\n== Denied path: ask it to write (the gate should refuse) =="
    puts agent.prompt("Create a file #{root}/nexo_probe.txt containing the word HELLO.").content
    # Expect the model to report it could not write: the write_file MCP call returns
    # { error: "mcp tool write_file denied in read_only mode (not in mcp_allow)" }.
  ensure
    agent.close   # tear down the stdio server subprocess
  end
end
