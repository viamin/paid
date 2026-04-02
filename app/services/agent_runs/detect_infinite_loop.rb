# frozen_string_literal: true

module AgentRuns
  # Detects when an agent is stuck in an infinite loop by analyzing recent
  # output logs for repeated patterns and lack of progress.
  #
  # Heuristics:
  #   1. Repeated output: N consecutive stdout chunks are identical
  #   2. Cycling/low-uniqueness output: recent outputs cycle through a small
  #      set of output fingerprints (e.g., patterns like A-B-A-B)
  #
  # @example
  #   result = AgentRuns::DetectInfiniteLoop.call(agent_run: agent_run)
  #   result.loop_detected? # => true
  #   result.reason          # => "Repeated output detected: 5 consecutive identical outputs"
  class DetectInfiniteLoop
    # Minimum consecutive identical outputs to trigger detection.
    DEFAULT_WINDOW_SIZE = 5

    # Number of recent log entries to examine.
    LOG_FETCH_LIMIT = 50

    # Minimum content length to consider meaningful (ignore tiny heartbeat lines).
    MIN_CONTENT_LENGTH = 10

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, window_size: DEFAULT_WINDOW_SIZE)
      raise ArgumentError, "window_size must be a positive integer" unless window_size.is_a?(Integer) && window_size.positive?

      @agent_run = agent_run
      @window_size = window_size
    end

    def call
      recent_outputs = fetch_recent_outputs

      return Result.new(detected: false) if recent_outputs.size < @window_size

      check_repeated_outputs(recent_outputs) ||
        check_low_variety_pattern(recent_outputs) ||
        Result.new(detected: false)
    end

    private

    attr_reader :agent_run

    def fetch_recent_outputs
      agent_run
        .agent_run_logs
        .stdout
        .chronological
        .last(LOG_FETCH_LIMIT)
        .map(&:content)
        .select { |c| c.length >= MIN_CONTENT_LENGTH }
    end

    # Check if the last N outputs are all identical.
    def check_repeated_outputs(outputs)
      window = outputs.last(@window_size)
      return nil unless window.size == @window_size

      fingerprints = window.map { |c| fingerprint(c) }
      return nil unless fingerprints.uniq.size == 1

      Result.new(
        detected: true,
        reason: "Repeated output detected: #{@window_size} consecutive identical outputs"
      )
    end

    # Check if recent outputs have very low variety, suggesting the agent is
    # stuck. If the last 2*window_size outputs contain <= 2 unique fingerprints,
    # the agent is likely looping — whether cycling (A-B-A-B) or repeating a
    # small set of outputs in any order.
    def check_low_variety_pattern(outputs)
      cycle_window = @window_size * 2
      return nil if outputs.size < cycle_window

      window = outputs.last(cycle_window)
      fingerprints = window.map { |c| fingerprint(c) }
      unique_count = fingerprints.uniq.size

      return nil unless unique_count <= 2

      Result.new(
        detected: true,
        reason: "Low output variety detected: #{unique_count} unique outputs in last #{cycle_window} entries"
      )
    end

    def fingerprint(content)
      Digest::SHA256.hexdigest(content.strip.gsub(/\s+/, " "))
    end

    class Result
      attr_reader :reason

      def initialize(detected:, reason: nil)
        @detected = detected
        @reason = reason
      end

      def loop_detected?
        @detected
      end

      def no_loop?
        !@detected
      end
    end
  end
end
