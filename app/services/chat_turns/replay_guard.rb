# frozen_string_literal: true

module ChatTurns
  # Replay safety contract for a recovered turn. Recovery continues from the
  # durable checkpoint (the persisted transcript) instead of replaying the
  # whole turn, but the model may still ask for a tool that already ran. This
  # guard turns such a request into the recorded outcome instead of a second
  # execution:
  #
  # - the same provider tool call replays its persisted result verbatim
  # - a side-effecting tool with the same name and arguments is skipped, so a
  #   write action can never be repeated by a resumed turn
  #
  # @spec CHAT-TURN-RECOVERY-010
  class ReplayGuard
    SKIPPED_REASON = "already_completed_in_turn"

    def self.call(transcript:)
      new(transcript:)
    end

    def self.signature(name, arguments)
      "#{name}:#{Digest::SHA256.hexdigest(canonical(arguments))}"
    end

    def self.canonical(arguments)
      normalize(arguments || {}).to_json
    end

    def self.normalize(value)
      case value
      when Hash
        value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, nested| [ key.to_s, normalize(nested) ] }
      when Array
        value.map { |nested| normalize(nested) }
      else
        value
      end
    end

    def initialize(transcript:)
      @transcript = transcript
    end

    # Returns the result to use instead of dispatching, or nil when the call
    # may proceed.
    def result_for(name:, arguments:, tool_call_id: nil)
      replayed = transcript.completed_tool_results[tool_call_id] if tool_call_id.present?
      return replayed if replayed

      return nil unless completed_side_effect?(name, arguments)

      {
        status: "skipped",
        reason: SKIPPED_REASON,
        message: "`#{name}` already completed in this turn; its recorded result was reused instead of running again."
      }
    end

    private

    attr_reader :transcript

    def completed_side_effect?(name, arguments)
      return false unless Tools::Registry.write_tool?(name)

      transcript.completed_side_effect_signatures.include?(self.class.signature(name, arguments))
    end
  end
end
