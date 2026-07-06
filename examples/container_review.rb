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

  # Run inside a disposable container. The host repo enters ONLY as a read-only
  # bind at /workspace/repo — the model can read it but can't modify your host.
  sandbox (ENV["NEXO_CONTAINER_RUNTIME"] || "docker").to_sym,
    image: ENV.fetch("NEXO_CONTAINER_IMAGE", "node:22-slim"),
    binds: {Dir.pwd => {to: "/workspace/repo", mode: :ro}}

  instructions <<~PROMPT
    You run inside a locked-down container. Read files under /workspace/repo and
    report issues. You have no network and cannot modify the host.
  PROMPT
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  repo = ARGV[0] || Dir.pwd
  Dir.chdir(repo) do
    agent = ContainerReviewer.new
    begin
      response = agent.prompt("Review the code under /workspace/repo and summarize any issues.")
      puts response.content
    ensure
      agent.close # force-removes the ephemeral container
    end
  end
end
