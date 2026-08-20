# frozen_string_literal: true

# Exercises the Rails-only Nexo::Session persistence path against an in-memory
# SQLite database with ruby_llm's acts_as_chat host models and a STUBBED model
# (ruby_llm-test). Run in a SEPARATE process (see test/session_test.rb): loading
# ActiveRecord into the main offline suite would flip Nexo's backend selection
# (Session#hydrate / RunStore.default) to the AR path for every other test.
#
# The host app owns the acts_as_chat schema (via `rails g ruby_llm:install`) plus
# the two addressing columns and their unique composite index — reproduced inline
# here. Prints OK markers the parent asserts on; aborts (non-zero exit) on any
# mismatch.

# ruby_llm reads its bundled models.json (UTF-8) during model resolution; force
# UTF-8 so this child is environment-independent like the core suite.
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

require "active_record"
require "delegate" # ruby_llm-test references SimpleDelegator without requiring it

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "nexo_ai"

# Stub the model so this is offline and deterministic — no API keys, no network.
require "ruby_llm/test"
RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)
RubyLLM.configure { |c| c.openai_api_key = "test" }

# acts_as_chat's association-based API. In a full Rails host the ruby_llm railtie
# mixes this into ActiveRecord::Base once `config.use_new_acts_as = true` (the
# install generator's default); here we require + include it directly.
require "ruby_llm/active_record/model_methods"
require "ruby_llm/active_record/message_methods"
require "ruby_llm/active_record/tool_call_methods"
require "ruby_llm/active_record/chat_methods"
require "ruby_llm/active_record/acts_as"
ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

# The host schema: exactly what `rails g ruby_llm:install` generates, PLUS the two
# addressing columns and their unique composite index that Spec 10 documents as the
# one host-side addition beyond the installer.
ActiveRecord::Schema.define do
  create_table :models do |t|
    t.string :model_id, null: false
    t.string :name, null: false
    t.string :provider, null: false
    t.string :family
    t.integer :context_window
    t.integer :max_output_tokens
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
    t.references :model, foreign_key: true
    t.timestamps
    t.index [:agent_name, :instance_id], unique: true # host-added addressing
  end

  create_table :messages do |t|
    t.string :role, null: false
    t.text :content
    t.json :content_raw
    t.integer :input_tokens
    t.integer :output_tokens
    t.references :chat, null: false, foreign_key: true
    t.references :model, foreign_key: true
    t.references :parent_tool_call, foreign_key: {to_table: :tool_calls}
    t.timestamps
    t.index :role
  end

  create_table :tool_calls do |t|
    t.string :tool_call_id, null: false
    t.string :name, null: false
    t.json :arguments, default: {}
    t.references :message, null: false, foreign_key: true
    t.timestamps
    t.index :tool_call_id, unique: true
  end
end

class Model < ActiveRecord::Base
  acts_as_model
end

class ToolCall < ActiveRecord::Base
  acts_as_tool_call
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

harness = RubyLLM::Test.send(:harness)

# --- Backend selection: with ActiveRecord present, hydrate takes the durable path.
abort "FAIL: AR not detected" unless defined?(::ActiveRecord::Base)

# --- Cold resume + prompt: creates exactly one chat row and persists the turn.
RubyLLM::Test.reset
RubyLLM::Test.stub_response("Nice to meet you, Mac!")
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
RubyLLM::Test.stub_response("Your name is Mac.")
resp2 = Nexo::Session.resume(Assistant, "user-42").prompt("What is my name?")
abort "FAIL: resp2 content (#{resp2.content.inspect})" unless resp2.content.include?("Mac")
# STILL exactly one chat row and one system message (idempotent instructions on resume, R4)
abort "FAIL: still one chat row (#{Chat.count})" unless Chat.count == 1
abort "FAIL: still one system msg (#{Chat.first.messages.where(role: "system").count})" unless
  Chat.first.messages.where(role: "system").count == 1
# the second request carried the earlier turn — the hydrated thread continued
last = harness.last_request
carried = last.messages.map { |m| m.respond_to?(:content) ? m.content : m[:content] }.join(" ")
abort "FAIL: prior turn not carried (#{last.messages.size} msgs)" unless carried.include?("Mac")
puts "WARM_RECALL_OK"

# --- Distinct instance_id addresses a distinct thread (the pair is unique).
RubyLLM::Test.stub_response("Hello there.")
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
