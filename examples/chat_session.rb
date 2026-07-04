# frozen_string_literal: true

# Verification example (Spec 10): a continuing, addressable Nexo::Session that
# remembers a prior turn across two separate `resume` calls.
#
#   NEXO_LIVE=1 NEXO_MODEL=... ruby -Ilib examples/chat_session.rb
#
# Run in plain Ruby like this, the thread lives in memory for the process only
# (Nexo::Session::MemoryStore) — the two prompts below still share it, so the
# agent recalls the name. In a Rails host with ruby_llm's acts_as_chat models
# (see the README "Sessions" section) the very same code is DURABLE: the thread
# is a `chats` row addressed by (agent_name, instance_id) and survives across
# processes. Nexo ships no migration for those models — the host owns them via
# `rails g ruby_llm:install`, plus the agent_name/instance_id columns + a unique
# composite index.
#
# A session adds only memory + addressability. The agent's sandbox, permissions
# (default :read_only), skills, MCP, and fetch_allow all apply unchanged.
require "nexo"

class Assistant < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  instructions "You are a helpful assistant. Remember what the user tells you."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  id = "user-42"

  # First invocation: tell the agent something worth remembering.
  first = Nexo::Session.resume(Assistant, id)
  begin
    puts first.prompt("My name is Mac.").content
  ensure
    first.close # releases any MCP/fetch resources the agent holds (none here)
  end

  # A LATER invocation — a fresh Session over the same (Assistant, "user-42")
  # thread. In Rails this could be a different process entirely; the persisted
  # thread carries the earlier turn forward.
  second = Nexo::Session.resume(Assistant, id)
  begin
    answer = second.prompt("What is my name?")
    puts answer.content # expect the reply to include "Mac"
  ensure
    second.close
  end
end
