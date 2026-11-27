# frozen_string_literal: true

# Verification example — MCP seam + permission gate, NO AUTH REQUIRED.
#
# Uses the official filesystem MCP server (npx, no credentials) so you can watch the
# safe-by-default gate in action end to end:
#   * read tools are on the mcp_allow list  -> the model can use them
#   * write_file is NOT on the list          -> under :read_only it is not attached,
#                                               so the model has no tool to write with
#
# Requires: `npx` on PATH, and a model. MCP ships with ruby_llm — no extra gem.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b ruby -Ilib examples/mcp_filesystem.rb /tmp
#
# Nothing here is provider-specific: set NEXO_MODEL to any ruby_llm-supported model.
require "nexo"

class FileExplorer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")          # provider-neutral; e.g. gemma3:12b via Ollama
  permissions :read_only                 # safe default

  # The server names its tools like ruby_llm's file tools (read_file, search_files),
  # so this agent leaves the built-in ones out.
  file_tools :none

  # Reached through an MCP server — no vendor SDK. The server exposes read_file,
  # list_directory, search_files, write_file, etc.
  mcp :fs,
    transport: :stdio,
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", ENV.fetch("FS_ROOT", "/tmp")]

  # Opt IN to read tools only. write_file is deliberately absent, so it is never
  # offered to the model.
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

    puts "\n== Denied path: ask it to write (it has no tool to do it) =="
    puts agent.prompt("Create a file #{root}/nexo_probe.txt containing the word HELLO.").content
    # Expect the model to report it could not write. Under :read_only an MCP tool that
    # is not in mcp_allow is not attached (since 0.14), so there is no write_file to
    # call. The gate still refuses a call that reaches it another way, with
    # { error: "mcp tool write_file denied in read_only mode (not in mcp_allow)" }.
  ensure
    agent.close   # tear down the stdio server subprocess
  end
end
