# frozen_string_literal: true

# Verification example — the Container sandbox running an agent's tools inside a
# throwaway, hardened OCI container via the `docker` (default) or Apple
# `container` CLI. No vendor gem: shell-out only.
#
# The agent reads the mounted repo but never touches your host directly — the
# container has no network, dropped capabilities, a read-only rootfs with an
# ephemeral writable scratch at /workspace, and the host repo bind-mounted
# READ-ONLY. When the run ends, `agent.close` tears the container down.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b ruby -Ilib examples/container_review.rb /path/to/repo
#
# Point at Apple's runtime on a Mac by setting NEXO_CONTAINER_RUNTIME=apple.
# Nothing here is provider-specific: NEXO_MODEL takes any ruby_llm-supported model.
require "nexo"

class ContainerReviewer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL") # provider-neutral; e.g. gemma3:12b via Ollama
  permissions :read_only        # safe default

  instructions <<~PROMPT
    You run inside a locked-down container. Read files under /workspace/repo and
    report issues. You have no network and cannot modify the host.
  PROMPT
end

# Builds the container sandbox declaration for a given host repo path. The repo
# enters ONLY as a read-only bind at /workspace/repo — the model can read it but
# can't modify your host. (Built per-run, not in the class body, so the repo
# argument is honored: a class-level `binds: {Dir.pwd => ...}` would freeze the
# load-time CWD into the mount.)
def container_sandbox_for(repo)
  {
    type: (ENV["NEXO_CONTAINER_RUNTIME"] || "docker").to_sym,
    image: ENV.fetch("NEXO_CONTAINER_IMAGE", "node:22-slim"),
    binds: {repo => {to: "/workspace/repo", mode: :ro}}
  }
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  repo = File.expand_path(ARGV[0] || Dir.pwd)
  agent = ContainerReviewer.new(sandbox: container_sandbox_for(repo))
  begin
    response = agent.prompt("Review the code under /workspace/repo and summarize any issues.")
    puts response.content
  ensure
    agent.close         # releases MCP clients (none here)
    agent.sandbox.close # force-removes the ephemeral container — Agent#close does NOT do this
  end
end
