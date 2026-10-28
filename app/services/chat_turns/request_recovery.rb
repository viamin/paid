# frozen_string_literal: true

module ChatTurns
  class RequestRecovery
    Result = Data.define(:success, :error) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(turn:, actor:, expected_revision:)
      @turn = turn
      @actor = actor
      @expected_revision = expected_revision.to_i
    end

    # @spec CHAT-API-030 CHAT-API-031 CHAT-API-032
    def call
      claimed = claim
      return duplicate_result unless claimed

      ChatTurns::RecoverJob.perform_later(chat_turn_id: turn.id)
      Result.new(success: true, error: nil)
    end

    private

    attr_reader :turn, :actor, :expected_revision

    def claim
      turn.with_lock do
        turn.reload
        return false unless turn.status == "stalled" && turn.lock_version == expected_revision

        turn.assign_attributes(status: "pending", recovery_attempts: turn.recovery_attempts + 1,
          recovery_requested_at: Time.current, recovery_requested_by: actor)
        turn.audit_events += [ recovery_event ]
        turn.save!
      end
      true
    end

    def recovery_event
      { "event" => "recovery_requested", "at" => Time.current.iso8601,
        "actor_id" => actor.id, "revision" => expected_revision }
    end

    def duplicate_result
      turn.append_audit_event!("recovery_deduplicated", actor_id: actor.id,
        expected_revision: expected_revision)
      Rails.logger.info(message: "chat_turn.recovery_deduplicated", chat_turn_id: turn.id,
        actor_id: actor.id, expected_revision:)
      Result.new(success: false, error: "This turn was already recovered or changed. Refresh the transcript.")
    end
  end
end
