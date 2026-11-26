# frozen_string_literal: true

# Exercises the Rails-only Nexo::Session persistence path against an in-memory
# SQLite database with ruby_llm's acts_as_chat host models and a STUBBED model
# (ruby_llm's own test helper). Run in a SEPARATE process (see
# test/session_test.rb): loading ActiveRecord into the main offline suite would
# flip Nexo's backend selection (Session#hydrate / RunStore.default) to the AR
# path for every other test.
#
# The host app owns the acts_as_chat schema (via `rails g ruby_llm:install`) plus
# the two addressing columns and their unique composite index — reproduced inline
# here. Prints OK markers the parent asserts on; aborts (non-zero exit) on any
# mismatch.

# ruby_llm reads its bundled models.json (UTF-8) during model resolution; force
# UTF-8 so this child is environment-independent like the core suite.
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

require "active_record"

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "nexo_ai"

# Stub the model so this is offline and deterministic — no API keys, no network.
require "ruby_llm/test_helper"
include RubyLLM::TestHelper # rubocop:disable Style/MixinUsage

RubyLLM.configure { |c| c.openai_api_key = "test" }

# ruby_llm's persistence layer. In a full Rails host the ruby_llm railtie requires
# these and mixes ActsAs into ActiveRecord::Base on load; with no railtie here the
# same list is required directly, in the railtie's order (VERIFIED ruby_llm 2.2.3).
# ruby_llm 2.x owns the model-registry and tool-call records itself
# (`RubyLLM::ActiveRecord::Model` / `ToolCall`), so the host defines only Chat and
# Message.
%w[
  record payload_helpers model tool_call usage batch mcp_credential provider_file
  queued_message chat_file file_store chat_methods chat_files chat_column_guard
  message_methods message_broadcasting chunk_methods acts_as
].each { |file| require "ruby_llm/active_record/#{file}" }
ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs
RubyLLM::Accounting::Usage.ledger ||= RubyLLM::ActiveRecord::Usage

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

# The host schema: the SQLite shape of what `rails g ruby_llm:install` generates
# for ruby_llm 2.2 (chats, messages, and the `ruby_llm_*` records the chat path
# touches), PLUS the two addressing columns and their unique composite index that
# docs/sessions.md documents as the one host-side addition beyond the installer.
ActiveRecord::Schema.define do
  create_table :ruby_llm_models do |t|
    t.string :model_id, null: false
    t.string :name, null: false
    t.string :provider, null: false
    t.string :family
    t.datetime :model_created_at
    t.integer :context_window
    t.integer :max_output_tokens
    t.date :knowledge_cutoff
    t.datetime :unlisted_at
    t.json :modalities, default: {}
    t.json :capabilities, default: []
    t.json :pricing, default: {}
    t.json :metadata, default: {}
    t.timestamps
    t.index [:provider, :model_id], unique: true
  end

  create_table :chats do |t|
    t.string :agent_name
    t.string :instance_id
    t.references :ruby_llm_model, null: false, foreign_key: {to_table: :ruby_llm_models}
    t.boolean :cancelled, null: false, default: false
    t.string :claim_token
    t.datetime :claimed_until
    t.timestamps
    t.index [:agent_name, :instance_id], unique: true # host-added addressing
  end

  create_table :messages do |t|
    t.references :chat, null: false, foreign_key: true
    t.string :role, null: false
    t.text :content
    t.boolean :cache_until_here, null: false, default: false
    t.string :cache_ttl
    t.text :thinking_text
    t.text :thinking_signature
    t.json :citations
    t.json :server_tool_calls
    t.json :raw_content
    t.json :raw_reasoning
    t.string :phase
    t.text :continuation
    t.string :finish_reason
    t.timestamps
  end

  create_table :ruby_llm_tool_calls do |t|
    t.references :message, polymorphic: true, null: false, index: false
    t.references :result, polymorphic: true, index: false
    t.string :tool_call_id, null: false
    t.string :provider_call_id
    t.string :namespace
    t.string :name, null: false
    t.text :thought_signature
    t.string :approval
    t.boolean :remote, default: false, null: false
    t.datetime :claimed_until
    t.json :arguments, default: {}
    t.json :mcp_state
    t.json :mcp_result
    t.timestamps
    t.index :tool_call_id, unique: true
  end

  create_table :ruby_llm_usages do |t|
    t.references :chat, polymorphic: true, index: false
    t.references :message, polymorphic: true, index: false
    t.references :owner, polymorphic: true, index: false
    t.string :operation, null: false
    t.string :provider, null: false
    t.string :model, null: false
    t.string :status, null: false
    t.integer :input_tokens
    t.integer :output_tokens
    t.integer :cache_read_tokens
    t.integer :cache_write_tokens
    t.integer :thinking_tokens
    t.integer :characters
    t.decimal :audio_seconds, precision: 16, scale: 6
    t.integer :search_units
    t.json :server_tool_use
    %i[input output cache_read cache_write thinking characters audio_seconds search_units].each do |kind|
      t.decimal :"#{kind}_cost", precision: 16, scale: 10
    end
    t.decimal :total_cost, precision: 16, scale: 10
    t.string :workflow_id
    t.string :workflow_name
    t.string :workflow_step_id
    t.string :workflow_step_name
    t.timestamps
  end

  create_table :ruby_llm_queued_messages do |t|
    t.references :chat, polymorphic: true, null: false, index: false
    t.references :sender, polymorphic: true, index: false
    t.text :content
    t.boolean :steer, default: true, null: false
    t.timestamps
  end

  create_table :ruby_llm_chat_files do |t|
    t.references :chat, polymorphic: true, null: false, index: false
    t.references :owner, polymorphic: true, index: false
    t.string :path, null: false
    t.string :content_type
    t.bigint :byte_size
    t.string :digest
    t.text :text
    t.string :read_digest
    t.timestamps
  end
end

class Message < ActiveRecord::Base
  acts_as_message
end

class Chat < ActiveRecord::Base
  acts_as_chat
end

class Assistant < Nexo::Agent
  model "gpt-4o-mini"
  provider :openai
  assume_model_exists true # bypass registry validation on the persisted chat (R7)
  instructions "You are a helpful assistant with memory."
  # :write is granted so WriteFile is attached and the re-attach assertion below
  # has three tools to find; the :read_only default would statically deny it.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
end

# --- Backend selection: with ActiveRecord present, hydrate takes the durable path.
abort "FAIL: AR not detected" unless defined?(::ActiveRecord::Base)

# --- Cold resume + prompt: creates exactly one chat row and persists the turn.
stub_replies("Nice to meet you, Mac!")
resp1 = Nexo::Session.resume(Assistant, "user-42").prompt("My name is Mac.")
abort "FAIL: resp1 content (#{resp1.content.inspect})" unless resp1.content == "Nice to meet you, Mac!"
abort "FAIL: one chat row (#{Chat.count})" unless Chat.count == 1
puts "COLD_PROMPT_OK"

chat = Chat.first
# addressing derived from agent_class.name
abort "FAIL: agent_name (#{chat.agent_name.inspect})" unless chat.agent_name == "Assistant"
abort "FAIL: instance_id (#{chat.instance_id.inspect})" unless chat.instance_id == "user-42"
# exactly one system message (the agent's instructions), stored as role: :system
sys = chat.messages.where(role: "system").to_a
abort "FAIL: one system msg (#{sys.size})" unless sys.size == 1
abort "FAIL: system content" unless sys.first.content == "You are a helpful assistant with memory."
# the user + assistant turn persisted
roles = chat.messages.order(:id).pluck(:role)
abort "FAIL: persisted roles (#{roles.inspect})" unless roles == %w[system user assistant]
puts "ADDRESSING_OK"

# --- Warm resume in a fresh Session (fresh agent + fresh record): recalls the turn.
stub_replies("Your name is Mac.")
warm = Nexo::Session.resume(Assistant, "user-42")
# the freshly hydrated thread already holds the earlier turn — that is what the
# next request sends to the model
carried = warm.instance_variable_get(:@chat).to_llm.messages.map { |m| m.content.to_s }.join(" ")
abort "FAIL: prior turn not carried into the hydrated chat (#{carried.inspect})" unless carried.include?("My name is Mac.")
resp2 = warm.prompt("What is my name?")
abort "FAIL: resp2 content (#{resp2.content.inspect})" unless resp2.content.include?("Mac")
# STILL exactly one chat row and one system message (idempotent instructions on resume, R4)
abort "FAIL: still one chat row (#{Chat.count})" unless Chat.count == 1
abort "FAIL: still one system msg (#{Chat.first.messages.where(role: "system").count})" unless
  Chat.first.messages.where(role: "system").count == 1
roles = Chat.first.messages.order(:id).pluck(:role)
abort "FAIL: both turns persisted (#{roles.inspect})" unless roles == %w[system user assistant user assistant]
puts "WARM_RECALL_OK"

# --- Distinct instance_id addresses a distinct thread (the pair is unique).
stub_replies("Hello there.")
Nexo::Session.resume(Assistant, "user-99").prompt("Hi.")
abort "FAIL: second thread not created (#{Chat.count})" unless Chat.count == 2
puts "DISTINCT_THREAD_OK"

# --- The hydrated chat carries the agent's sandbox tools (reused seam, R3).
# The default (:virtual) sandbox has no shell, so the Shell tool is NOT attached
# (Spec 14 R2 — capability-gated tool attach); the other three attach because the
# agent's gate permits read/glob/write.
session = Nexo::Session.resume(Assistant, "user-42")
hydrated = session.instance_variable_get(:@chat)
tool_classes = hydrated.to_llm.tools.values.map(&:class)
[Nexo::Tools::ReadFile, Nexo::Tools::WriteFile, Nexo::Tools::Glob].each do |klass|
  abort "FAIL: missing #{klass} on hydrated chat (#{tool_classes.inspect})" unless tool_classes.include?(klass)
end
abort "FAIL: virtual sandbox should not attach Shell (#{tool_classes.inspect})" if
  tool_classes.include?(Nexo::Tools::Shell)
puts "TOOLS_REATTACHED_OK"

# --- close is safe with no MCP/fetch resources held.
session.close
puts "CLOSE_OK"
