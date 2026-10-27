# frozen_string_literal: true

module ChatSessions
  module Turns
    class Recover
      MAX_AUTOMATIC_ATTEMPTS = 2

      class Conflict < ArgumentError; end
      class ConfirmationRequired < ArgumentError; end

      # @spec CHAT-TURN-RECOVERY-006 CHAT-TURN-RECOVERY-008 CHAT-TURN-RECOVERY-009
      def self.call(turn:, actor: nil, revision: nil, confirmed: false, automatic: false)
        new(turn:, actor:, revision:, confirmed:, automatic:).call
      end

      def initialize(turn:, actor:, revision:, confirmed:, automatic:)
        @turn = turn
        @actor = actor
        @revision = revision
        @confirmed = confirmed
        @automatic = automatic
      end

      def call
        turn.with_lock do
          reject_stale_revision!
          reject_duplicate!
          require_confirmation!
          claim!
        end
        ChatSessions::RecoverStalledTurnJob.perform_later(chat_turn_id: turn.id, actor_id: actor&.id)
        true
      rescue Conflict, ConfirmationRequired => error
        record("duplicate_prevented", outcome: error.class.name.demodulize.underscore)
        raise
      end

      private

      attr_reader :turn, :actor, :revision

      def reject_stale_revision!
        return if automatic? || revision.to_i == turn.revision

        raise Conflict, "This recovery notice is out of date. Refresh the conversation before trying again."
      end

      def reject_duplicate!
        raise Conflict, "Recovery is already in progress" if turn.recovery_state == "in_progress"
        raise Conflict, "This turn is no longer available for recovery" unless turn.status.in?(%w[stalled failed])
      end

      def require_confirmation!
        return if automatic? && automatically_recoverable?
        return if !automatic? && @confirmed

        raise ConfirmationRequired, "Confirm recovery before repeating an interrupted turn"
      end

      def automatically_recoverable?
        turn.failure_classification.in?(%w[provider_timeout infrastructure_error]) &&
          !turn.side_effecting_tools_completed? &&
          Array(turn.metadata["completed_tools"]).all? { |name| Tools::Registry.replay_safe?(name) } &&
          turn.recovery_attempts < MAX_AUTOMATIC_ATTEMPTS
      end

      def automatic?
        @automatic
      end

      def claim!
        turn.update!(recovery_state: "in_progress", recovery_attempts: turn.recovery_attempts + 1, revision: turn.revision + 1)
        record("recovery_requested", outcome: "accepted", user_action: automatic? ? "auto_recovery" : "user_resume")
      end

      def record(event_type, outcome:, user_action: "none")
        ChatTurnEvent.create!(chat_turn: turn, chat_session: turn.chat_session, actor:, event_type:, outcome:, user_action:,
          side_effecting_tools_completed: turn.side_effecting_tools_completed?, metadata: { "revision" => turn.revision })
      end
    end
  end
end
