# frozen_string_literal: true

module ChatTurns
  # Decides why a quiet chat turn stopped. The distinction matters because only
  # a genuine stall may be reported as one: a turn waiting on a human, a turn
  # running a long tool, a turn whose budget ran out, and a turn whose client
  # left all have their own recovery path and must not be reported as stalls.
  #
  # @spec CHAT-TURN-RECOVERY-004
  class Classify
    Outcome = Data.define(:classification, :state, :stalled, :explanation)

    # Classifications that mean "this turn really stopped without an outcome".
    STALL_CLASSIFICATIONS = %w[infrastructure_failure ambiguous_model_stop].freeze

    def self.call(turn)
      new(turn).call
    end

    def initialize(turn)
      @turn = turn
    end

    def call
      classification = detect
      Outcome.new(
        classification: classification,
        state: state_for(classification),
        stalled: STALL_CLASSIFICATIONS.include?(classification),
        explanation: explanation_for(classification)
      )
    end

    private

    attr_reader :turn

    def transcript
      @transcript ||= ChatTurns::Transcript.call(turn)
    end

    # Ordered from the most specific, most actionable explanation to the
    # generic one. The first match wins.
    def detect
      return "pending_confirmation" if transcript.pending_confirmation?
      return "long_running_operation" if transcript.long_running_operation?
      return "budget_exhausted" if transcript.token_limit_exhausted?
      return "rate_limited" if transcript.rate_limited?
      return "provider_timeout" if transcript.provider_error?
      return "client_disconnect" if client_disconnected?

      transcript.partial_output? ? "ambiguous_model_stop" : "infrastructure_failure"
    end

    # The client only explains the silence when it left *after* the last
    # durable activity. Activity after a disconnect means the server kept
    # working and the turn's silence has another cause.
    def client_disconnected?
      return false if turn.client_disconnected_at.blank?

      turn.client_disconnected_at >= turn.last_activity_at
    end

    def state_for(classification)
      case classification
      when "pending_confirmation", "long_running_operation", "rate_limited" then turn.state
      when "budget_exhausted", "provider_timeout" then "failed"
      when "client_disconnect" then "abandoned"
      else "stalled"
      end
    end

    def explanation_for(classification)
      case classification
      when "pending_confirmation" then "The turn is waiting for a confirmation decision."
      when "long_running_operation" then "The turn is waiting for a long-running tool to finish."
      when "budget_exhausted" then "The turn ran out of its token budget."
      when "rate_limited" then "The runner is rate limited and the session is paused."
      when "provider_timeout" then "The provider ended the turn with an error."
      when "client_disconnect" then "The browser left before the turn finished."
      when "ambiguous_model_stop" then "The model stopped without a final answer."
      else "The turn produced no activity after the message was sent."
      end
    end
  end
end
