# frozen_string_literal: true

module Containers
  # Processes streaming JSONL progress events emitted by CLI agents (e.g. Codex)
  # during container execution. Feeds parsed events into the watchdog as
  # structured activity signals, enabling semantic awareness of agent state
  # beyond raw stdout monitoring.
  #
  # Supported event types:
  #   - progress / token_usage → reset idle timer (like heartbeat)
  #   - error / turn.failed    → trigger early abort
  #   - turn_complete          → log turn duration and token count
  #
  # Falls back gracefully when agent-harness does not yet expose
  # parse_streaming_event (viamin/agent-harness#178).
  class StreamingEventProcessor
    PROGRESS_EVENT_TYPES = %w[progress token_usage].freeze
    TURN_COMPLETE_EVENT_TYPES = %w[turn_complete turn.complete].freeze
    TURN_FAILED_EVENT_TYPES = %w[turn.failed turn_failed].freeze
    ERROR_EVENT_TYPES = %w[error].freeze

    attr_reader :turns_completed, :turns_data, :last_event_type

    def initialize(agent_run:, logger: nil)
      @agent_run = agent_run
      @logger = logger
      @turns_completed = 0
      @turns_data = []
    end

    # Attempts to parse a stdout line as a streaming JSONL progress event.
    # Returns a hash with :type and :event keys on success, nil otherwise.
    def parse_line(line)
      stripped = line.to_s.strip
      return nil if stripped.blank?

      parsed = parse_jsonl_event(stripped)
      return nil unless parsed

      event_type = parsed["type"].to_s
      return nil if event_type.blank?

      { type: classify_event(event_type), event: parsed, raw_type: event_type }
    end

    # Processes a parsed event, updating internal state and returning an action
    # symbol: :activity (reset idle timer), :abort (trigger early abort), or nil.
    def process(parsed)
      return nil unless parsed

      @last_event_type = parsed[:raw_type]

      case parsed[:type]
      when :progress
        log_progress_event(parsed[:event])
        :activity
      when :turn_complete
        record_turn_complete(parsed[:event])
        :activity
      when :turn_failed
        record_turn_failed(parsed[:event])
        :abort
      when :error
        log_error_event(parsed[:event])
        :abort
      end
    end

    # Convenience method: parse + process in one call.
    def handle_line(line)
      parsed = parse_line(line)
      return nil unless parsed

      process(parsed)
    end

    # Persists accumulated turn metrics to the AgentRun record.
    def flush_metrics!
      return unless @agent_run

      @agent_run.update_columns(
        turns_completed: @turns_completed,
        streaming_turns_data: @turns_data
      )
    end

    private

    def parse_jsonl_event(line)
      if harness_streaming_available?
        AgentHarness::Providers::Codex.parse_streaming_event(line)
      else
        fallback_parse(line)
      end
    end

    def harness_streaming_available?
      defined?(AgentHarness::Providers::Codex) &&
        AgentHarness::Providers::Codex.respond_to?(:parse_streaming_event)
    end

    def fallback_parse(line)
      parsed = JSON.parse(line)
      return nil unless parsed.is_a?(Hash) && parsed["type"].present?

      parsed
    rescue JSON::ParserError, TypeError
      nil
    end

    def classify_event(event_type)
      if PROGRESS_EVENT_TYPES.include?(event_type)
        :progress
      elsif TURN_COMPLETE_EVENT_TYPES.include?(event_type)
        :turn_complete
      elsif TURN_FAILED_EVENT_TYPES.include?(event_type)
        :turn_failed
      elsif ERROR_EVENT_TYPES.include?(event_type)
        :error
      end
    end

    def log_progress_event(event)
      log_streaming("container.execute.progress",
        event_type: event["type"],
        turn_number: @turns_completed + 1,
        tokens_input: event.dig("usage", "input_tokens") || event["input_tokens"],
        tokens_output: event.dig("usage", "output_tokens") || event["output_tokens"])
    end

    def record_turn_complete(event)
      @turns_completed += 1

      turn_data = {
        "turn_number" => @turns_completed,
        "completed_at" => Time.current.iso8601,
        "input_tokens" => event.dig("usage", "input_tokens") || event["input_tokens"],
        "output_tokens" => event.dig("usage", "output_tokens") || event["output_tokens"],
        "duration_ms" => event["duration_ms"] || event.dig("metrics", "duration_ms")
      }.compact

      @turns_data << turn_data

      log_streaming("container.execute.turn_complete",
        turn_number: @turns_completed,
        input_tokens: turn_data["input_tokens"],
        output_tokens: turn_data["output_tokens"],
        duration_ms: turn_data["duration_ms"])
    end

    def record_turn_failed(event)
      @turns_completed += 1

      turn_data = {
        "turn_number" => @turns_completed,
        "completed_at" => Time.current.iso8601,
        "status" => "failed",
        "error" => (event["message"] || event.dig("error", "message")).to_s.truncate(500),
        "input_tokens" => event.dig("usage", "input_tokens") || event["input_tokens"],
        "output_tokens" => event.dig("usage", "output_tokens") || event["output_tokens"]
      }.compact

      @turns_data << turn_data

      log_streaming("container.execute.turn_failed",
        turn_number: @turns_completed,
        error: turn_data["error"])
    end

    def log_error_event(event)
      error_message = (event["message"] || event.dig("error", "message")).to_s.truncate(500)

      log_streaming("container.execute.streaming_error",
        event_type: event["type"],
        error: error_message)
    end

    def log_streaming(message, **metadata)
      if @logger
        @logger.call(message, **metadata)
      elsif @agent_run
        @agent_run.log!("system", message, metadata: metadata)
      end
    end
  end
end
