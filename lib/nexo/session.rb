# frozen_string_literal: true

module Nexo
  # A continuing, addressable session: a *remembering* instance of an Agent,
  # keyed by +(agent_name, instance_id)+ and resumable across separate
  # invocations. It is the memory half of Nexo's model — the mirror of the
  # fire-and-finish Workflow.
  #
  #   session = Nexo::Session.resume(Assistant, "user-42")
  #   session.prompt("My name is Mac.")
  #   # ... a later request / process ...
  #   Nexo::Session.resume(Assistant, "user-42").prompt("What is my name?")
  #   # => "...Mac..." — the persisted thread carried the earlier turn
  #
  # A Session adds ONLY memory + addressability. Message persistence is RubyLLM's
  # +acts_as_chat+ (a Session defines no message table and serializes nothing);
  # the agent supplies the sandbox, permissions, skills, MCP servers, and fetch
  # allow-list unchanged. Opening or resuming a session therefore never widens
  # what the agent is allowed to do.
  #
  # == Rails-optional
  #
  # Durable persistence requires ActiveRecord. Backend selection guards on
  # +defined?(::ActiveRecord::Base)+, mirroring RunStore.default:
  #
  # * *Rails* — the thread is a row on the host +acts_as_chat+ model
  #   (Nexo.config.session_chat_model, a String class name, constantized here at
  #   resume time so no compile-time AR reference exists). +find_or_create_by+ on
  #   +(agent_name, instance_id)+ loads-or-creates it; +acts_as_chat+'s callbacks
  #   persist every new message. The host app owns the schema (via
  #   +rails g ruby_llm:install+) plus the two addressing columns and their unique
  #   composite index.
  # * *Plain Ruby* — no AR reference at all. A process-wide MemoryStore holds a
  #   live +RubyLLM::Chat+ per pair; the thread lives only for the process and is
  #   documented as non-durable.
  #
  # == Lifecycle
  #
  # A long-lived session accumulates context and any MCP/stdio/SSE connections the
  # agent holds. Call #close when done to tear those down; see the README's
  # retention/PII note.
  class Session
    # Loads-or-creates the persisted thread for +(agent_class.name, instance_id)+
    # and returns a Session whose #prompt appends to it. Extra keyword arguments
    # are forwarded to +agent_class.new+ so a session accepts the same construction
    # inputs an agent does where they don't conflict with addressing (e.g. +cwd:+).
    def self.resume(agent_class, instance_id, **agent_opts)
      new(agent_class.new(**agent_opts), instance_id)
    end

    # The addressing pair for this session: the agent's class name and the
    # caller-supplied instance id.
    attr_reader :agent_name, :instance_id

    # Wraps a built +agent+ and +instance_id+, then hydrates (finds-or-creates)
    # the persisted thread for the +(agent_name, instance_id)+ pair. Prefer the
    # Session.resume entry point over calling this directly.
    def initialize(agent, instance_id)
      @agent = agent
      @agent_name = agent.class.name
      @instance_id = instance_id.to_s
      @chat = hydrate
    end

    # Appends +text+ to the thread, runs the agent's loop over the hydrated chat,
    # and returns the response (respond to +#content+). New messages are persisted
    # by +acts_as_chat+ (Rails) or accumulate on the live in-memory chat (plain
    # Ruby). The optional +&on_event+ block receives the same
    # +(:tool_call | :tool_result | :done, payload)+ events as Loops::RubyLLM.
    def prompt(text, max_turns: 25, &on_event)
      @agent.loop.run(agent: @agent, prompt: text, max_turns: max_turns, chat: @chat, &on_event)
    end

    # Releases any MCP/fetch resources the agent holds. Delegates to
    # Agent#close; idempotent and safe when there is nothing to release.
    def close
      @agent.close if @agent.respond_to?(:close)
    end

    private

    # Returns the chat the loop runs over: the hydrated persisted record (Rails)
    # or the live in-memory chat (plain Ruby). AR is referenced only inside the
    # durable branch and only by the configured String class name, so the
    # plain-Ruby path never touches ActiveRecord.
    def hydrate
      if durable?
        record = session_chat_model.find_or_create_by(agent_name: @agent_name, instance_id: @instance_id)
        # Carry the agent's model onto the persisted chat so its #to_llm resolves
        # exactly as a fresh RubyLLM.chat would — honoring provider/assume_model_exists.
        record.model = @agent.model
        record.provider = @agent.provider if @agent.provider
        record.assume_model_exists = @agent.assume_model_exists
        record.save!
        @agent.chat(base: record)
      else
        MemoryStore.fetch(@agent_name, @instance_id) { @agent.chat }
      end
    end

    # The durable (Rails) path applies only when BOTH ActiveRecord and the
    # configured host chat model are present — mirroring how RunStore.default
    # requires +::ActiveRecord::Base+ AND +Nexo::WorkflowRun+. Checking the host
    # model (rather than AR alone) keeps the plain-Ruby fallback robust even in a
    # process where some other component has loaded ActiveRecord but no
    # +acts_as_chat+ host model exists (e.g. Nexo's own offline test suite). The
    # host model String is only *referenced* — never constantized — when
    # ActiveRecord is absent, so plain Ruby stays AR-free.
    def durable?
      defined?(::ActiveRecord::Base) && Object.const_defined?(Nexo.config.session_chat_model)
    end

    # Constantizes the configured host chat model String lazily, at resume time.
    # Only reached from the durable branch, where #durable? has already
    # confirmed the constant is defined.
    def session_chat_model
      Object.const_get(Nexo.config.session_chat_model)
    end

    # Process-wide, in-memory backend for the plain-Ruby path. Holds one live
    # +RubyLLM::Chat+ per +[agent_name, instance_id]+ pair so a later
    # Session.resume in the same process resumes the very same thread. Not
    # durable — a fresh process starts empty. Mirrors RunStore::Memory's
    # class-level singleton so independent callers share one store.
    class MemoryStore
      @threads = {}

      class << self
        # Returns the stored chat for the pair, building it once (via the block)
        # on first resume and reusing it thereafter.
        def fetch(agent_name, instance_id)
          @threads[[agent_name, instance_id]] ||= yield
        end

        # Clears the shared table. Intended for test isolation.
        def reset!
          @threads = {}
        end
      end
    end
  end
end
