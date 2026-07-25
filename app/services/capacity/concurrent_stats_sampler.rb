# frozen_string_literal: true

require "timeout"

module Capacity
  # Fetches Docker stats for a batch of containers concurrently, bounded by a
  # shared deadline and a per-container timeout.
  #
  # Docker's non-streaming stats endpoint samples two CPU counters across an
  # interval, so a single call routinely takes close to a second regardless
  # of load. Sampling containers one at a time therefore exhausts any
  # reasonable budget once more than a handful are running. A small worker
  # pool keeps total wall-clock time roughly flat instead of scaling
  # linearly with container count.
  class ConcurrentStatsSampler
    MAX_THREADS = 8

    Result = Struct.new(:container, :raw_stats, :error, :skipped, keyword_init: true) do
      def success?
        !skipped && error.nil?
      end
    end

    def self.call(...)
      new(...).call
    end

    # monotonic_deadline: must be a Process::CLOCK_MONOTONIC timestamp (e.g.
    # Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget), not a
    # Time.now/Time.current-based value -- it is compared directly against
    # this class's own monotonic clock reads.
    def initialize(containers:, monotonic_deadline:, per_container_timeout:, max_threads: MAX_THREADS, &fetch)
      @containers = containers
      @deadline = monotonic_deadline
      @per_container_timeout = per_container_timeout
      @max_threads = max_threads
      @fetch = fetch
    end

    def call
      return [] if containers.empty?

      results = Array.new(containers.size)
      work = Queue.new
      containers.each_with_index { |container, index| work << [ container, index ] }

      worker_count = [ max_threads, containers.size ].min
      threads = Array.new(worker_count) { Thread.new { drain(work, results) } }
      threads.each(&:join)

      results
    end

    private

    attr_reader :containers, :deadline, :per_container_timeout, :max_threads, :fetch

    def drain(work, results)
      loop do
        container, index = work.pop(true)
        results[index] = sample(container)
      end
    rescue ThreadError
      nil
    end

    def sample(container)
      remaining = deadline - monotonic_now
      return Result.new(container: container, skipped: true) if remaining <= 0

      raw_stats = Timeout.timeout([ per_container_timeout, remaining ].min) { fetch.call(container) }
      Result.new(container: container, raw_stats: raw_stats)
    rescue StandardError => e
      Result.new(container: container, error: e)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
