# frozen_string_literal: true

module ChatSessions
  module Turns
    # Decides whether a stalled chat turn may be recovered automatically, and
    # whether a recovery needs an explicit human confirmation.
    #
    # Automatic recovery is opt-in per failure classification, bounded in
    # attempts, and conditional on the replay-safety contract: a tool that was
    # dispatched without a persisted result may already have had its effect, so
    # it is only replayed when the tool itself declares that replaying it is
    # safe.
    class ReplaySafety
      MAX_AUTOMATIC_RECOVERY_ATTEMPTS = 2

      attr_reader :turn, :action

      def self.for(turn, action: "resume")
        new(turn, action: action)
      end

      def initialize(turn, action: "resume")
        @turn = turn
        @action = action
      end

      def automatic_recovery_permitted?
        return false unless action == "resume"
        return false unless opted_in?
        return false unless within_attempt_bound?
        return false unless replay_safe?

        true
      end

      def requires_confirmation?
        ambiguous_stop? || unreplayable_in_flight_tool? || action == "retry"
      end

      def reasons
        reasons = []
        reasons << "not_opted_in" unless opted_in?
        reasons << "attempt_bound_reached" unless within_attempt_bound?
        reasons << "unreplayable_in_flight_tool" if unreplayable_in_flight_tool?
        reasons << "ambiguous_model_stop" if ambiguous_stop?
        reasons << "replay_requested" if action == "retry"
        reasons
      end

      private

      def opted_in?
        allowed = account_settings&.chat_turn_auto_recovery_classifications
        Array(allowed).map(&:to_s).include?(turn.stall_classification.to_s)
      end

      def within_attempt_bound?
        turn.recovery_attempts.to_i < MAX_AUTOMATIC_RECOVERY_ATTEMPTS
      end

      # A tool that was dispatched without a persisted result may already have
      # had its effect. Replaying it is only allowed when the tool declares
      # itself replay-safe.
      def replay_safe?
        name = turn.evidence.in_flight_tool_name
        return true if name.blank?

        Tools::Registry.replay_safe?(name)
      end

      def unreplayable_in_flight_tool?
        name = turn.evidence.in_flight_tool_name
        return false if name.blank?

        !Tools::Registry.replay_safe?(name)
      end

      def ambiguous_stop?
        turn.stall_classification == "model_stop"
      end

      def account_settings
        turn.chat_session.account&.tenant_setting
      end
    end
  end
end
