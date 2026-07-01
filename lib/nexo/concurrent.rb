# frozen_string_literal: true

module Nexo
  # Bounded fan-out driver for running many agent/workflow calls concurrently on
  # Ruby's fiber scheduler (Spec 5). It is the value Nexo adds over a raw
  # +Async {}+ block: *rate-bounded* concurrency (so you stay under provider rate
  # limits) with proper error propagation (the first task failure is re-raised,
  # never swallowed) and results returned in **submission order**.
  #
  #   results = Nexo.concurrent(max_in_flight: 8) do |c|
  #     docs.each { |d| c.add { SummarizeDocument.run(text: d.body).result } }
  #   end
  #   # => one result per doc, in doc order, never more than 8 calls in flight
  #
  # +async+ is a SOFT (optional) dependency: it is required lazily the moment a
  # fan-out actually runs. With the gem absent, +require "nexo"+ still loads
  # cleanly; only calling {Nexo.concurrent} raises {MissingDependencyError}.
  class Concurrent
    # A submitted unit of work. Wrapping the block in a Struct keeps submission
    # order explicit (the index into +@tasks+ is the index into the results).
    Task = Struct.new(:block)

    def initialize(max_in_flight:)
      @max_in_flight = max_in_flight
      @tasks = []
    end

    # Registers a block to run. Called via the yielded collector inside
    # {Nexo.concurrent}. Order of +add+ calls is the order of the results array.
    def add(&block)
      @tasks << Task.new(block)
    end

    # Runs every added block inside ONE reactor, bounding in-flight work with an
    # +Async::Semaphore+ and coordinating with an +Async::Barrier+. Results are
    # index-assigned, so the returned Array is in submission order regardless of
    # completion order. On the first task that raises, the error propagates out
    # of +barrier.wait+ and the +ensure+ stops the remaining in-flight tasks —
    # errors are never swallowed.
    def run
      require_async!
      results = Array.new(@tasks.size)

      Async do |task|
        semaphore = Async::Semaphore.new(@max_in_flight, parent: task)
        barrier = Async::Barrier.new(parent: semaphore)

        @tasks.each_with_index do |t, i|
          barrier.async { results[i] = t.block.call }
        end

        # barrier.wait re-raises the first task failure (no silent swallowing).
        barrier.wait
      ensure
        barrier&.stop
      end.wait

      results
    end

    private

    # Lazily loads +async+ and its coordination primitives, mirroring the
    # soft-dependency precedent in {Skills.load!} / {Loops::AgentSDK}: a bare
    # +require+ (so tests can stub it on the instance) rescuing stdlib +LoadError+
    # into a {MissingDependencyError} that names the gem and the exact remedy.
    def require_async!
      require "async"
      require "async/barrier"
      require "async/semaphore"
    rescue LoadError
      raise Nexo::MissingDependencyError,
        'Concurrency requires the `async` gem. Add `gem "async", "~> 2.0"` to your Gemfile.'
    end
  end
end
