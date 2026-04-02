# frozen_string_literal: true

module AgentRuns
  # Detects when an agent is stuck in an infinite loop by analyzing recent
  # output logs for repeated patterns and lack of progress.
  #
  # Heuristics:
  #   1. Repeated output: N consecutive stdout chunks are identical
  #   2. No file changes: agent has been running for many iterations with
  #      identical output fingerprints in a sliding window
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
      @agent_run = agent_run
      @window_size = window_size
    end

    def call
      recent_outputs = fetch_recent_outputs

      return Result.new(detected: false) if recent_outputs.size < @window_size

      check_repeated_outputs(recent_outputs) ||
        check_cycling_pattern(recent_outputs) ||
        Result.new(detected: false)
    end

    private

    attr_reader :agent_run

    def fetch_recent_outputs
      agent_run
        .agent_run_logs
        .stdout
        .recent
        .limit(LOG_FETCH_LIMIT)
        .pluck(:content)
        .reverse
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

    # Check if outputs cycle through a small set of patterns (e.g., A-B-A-B).
    # If the last 2*window_size outputs contain <= 2 unique fingerprints,
    # the agent is likely cycling.
    def check_cycling_pattern(outputs)
      cycle_window = @window_size * 2
      return nil if outputs.size < cycle_window

      window = outputs.last(cycle_window)
      fingerprints = window.map { |c| fingerprint(c) }
      unique_count = fingerprints.uniq.size

      return nil unless unique_count <= 2

      Result.new(
        detected: true,
        reason: "Cycling pattern detected: #{unique_count} unique outputs in last #{cycle_window} entries"
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
