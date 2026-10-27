# frozen_string_literal: true

module ChatSessions
  module Turns
    # Recovers a stalled chat turn.
    #
    # Recovery is idempotent and revision-aware: a concurrent or repeated
    # request is deduplicated instead of running a second recovery, and a
    # request built on an outdated revision is rejected rather than applied to
    # a turn that has since moved on.
    #
    # The `resume` action continues the agent loop over the persisted
    # transcript, so the turn's completed tool calls are never dispatched
    # again. The `retry` action discards the turn's partial work and replays
    # the turn from the user message, which is why it always needs an
    # explicit confirmation.
    class Recover
      include FallbackLoop

      class Error < StandardError; end
      class ConfirmationRequiredError < Error; end
      class DuplicateRecoveryError < Error; end
      class NotRecoverableError < Error; end
      class StaleRevisionError < Error; end
      class UnauthorizedError < Error; end

      ACTIONS = %w[resume retry].freeze
      SOURCES = %w[automatic user].freeze

      Result = Data.define(:status, :message, :error)

      attr_reader :chat_session, :turn, :actor, :action, :source, :confirmed, :idempotency_key, :revision,
        :llm_client, :on_chunk, :on_message_persisted, :stream_message_id, :transport_attempt_message

      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:, turn:, actor:, action: "resume", source: "user", confirmed: false,
        idempotency_key: nil, revision: nil, on_chunk: nil, on_message_persisted: nil)
        @chat_session = chat_session
        @turn = turn
        @actor = actor
        @action = action.to_s
        @source = source.to_s
        @confirmed = confirmed
        @idempotency_key = idempotency_key
        @revision = revision
        @on_chunk = on_chunk
        @on_message_persisted = on_message_persisted
        @transport_attempt_message = turn.user_message
      end

      def call
        validate_action!
        authorize_actor!
        validate_recoverable!
        validate_revision!
        validate_confirmation!
        claim_recovery!
        execute_recovery
      end

      private

      def safety
        @safety ||= ReplaySafety.for(turn, action: action)
      end

      def validate_action!
        raise ArgumentError, "action must be one of #{ACTIONS.join(", ")}" unless ACTIONS.include?(action)
        raise ArgumentError, "source must be one of #{SOURCES.join(", ")}" unless SOURCES.include?(source)
      end

      # A recovery continues the conversation, so it needs the same access the
      # session itself demands.
      def authorize_actor!
        return if actor.blank?
        return if ChatSessionPolicy.new(actor, chat_session).show?
        return if ChatMessagePolicy.new(actor, ChatMessage.new(chat_session: chat_session)).create?

        raise UnauthorizedError, "You are not authorized to recover this chat turn."
      end

      def validate_recoverable!
        raise NotRecoverableError, "This chat turn is not stalled." unless turn.stalled?

        return unless source == "automatic"
        return if safety.automatic_recovery_permitted?

        raise NotRecoverableError, "This chat turn is not eligible for automatic recovery."
      end

      def validate_revision!
        return if revision.blank?
        return if revision.to_i == turn.lock_version

        raise StaleRevisionError, "This recovery request is out of date."
      end

      def validate_confirmation!
        return unless safety.requires_confirmation?
        return if confirmed

        raise ConfirmationRequiredError, "This recovery needs an explicit confirmation."
      end

      # A compare-and-swap on the turn row: only one caller can move the turn
      # into `in_progress`, so a double-click, two browser tabs, or a retried
      # request cannot start a second recovery.
      def claim_recovery!
        if duplicate_idempotency_key?
          record_duplicate_prevented("idempotency_key_reused")
          raise DuplicateRecoveryError, "A recovery for this turn is already in progress."
        end

        updated = ChatTurn.where(id: turn.id, recovery_status: %w[none failed]).update_all(
          recovery_status: "in_progress",
          recovery_key: idempotency_key,
          recovery_attempts: Arel.sql("recovery_attempts + 1"),
          updated_at: Time.current,
          lock_version: Arel.sql("lock_version + 1")
        )
        return true if updated == 1

        record_duplicate_prevented("recovery_already_in_progress")
        raise DuplicateRecoveryError, "A recovery for this turn is already in progress."
      end

      def duplicate_idempotency_key?
        return false if idempotency_key.blank?

        turn.recovery_key == idempotency_key && turn.recovery_status == "in_progress"
      end

      def execute_recovery
        record_attempt
        turn.apply_update!(status: "streaming", recovery_status: "in_progress", last_activity_at: Time.current)

        message = perform_action
        finish_success(message)
      rescue StandardError => error
        finish_failure(error)
        raise
      end

      def perform_action
        discard_partial_work if action == "retry"

        run_with_fallbacks
      end

      # The retry action replays the turn from the user message, so the rows
      # the stalled turn produced are removed first. The user message and the
      # stall notice stay: the transcript keeps the evidence of what happened.
      def discard_partial_work
        scope = chat_session.messages.where(role: %w[assistant tool])
        scope = scope.where("id > ?", turn.user_message_id) if turn.user_message_id
        scope = scope.where("id <= ?", turn.checkpoint_message_id) if turn.checkpoint_message_id
        scope.delete_all

        turn.apply_update!(checkpoint_message_id: turn.user_message_id)
      end

      def finish_success(message)
        ChatSessions::Turns::Complete.call(chat_session: chat_session) if message
        turn.reload
        turn.apply_update!(recovery_status: "succeeded")

        RecordEvent.call(
          turn: turn,
          event_type: "recovery_succeeded",
          outcome: "succeeded",
          actor: actor,
          metadata: { "action" => action, "source" => source }
        )
        Result.new(status: "completed", message: message, error: nil)
      end

      def finish_failure(error)
        turn.reload
        turn.apply_update!(
          status: "stalled",
          recovery_status: "failed",
          failure_class: ClassifyFailure.for(error),
          last_activity_at: Time.current
        )

        RecordEvent.call(
          turn: turn,
          event_type: "recovery_failed",
          outcome: "failed",
          actor: actor,
          metadata: {
            "action" => action,
            "source" => source,
            "error_class" => error.class.name,
            "error" => error.message
          }
        )
        Result.new(status: "failed", message: nil, error: error)
      end

      def record_attempt
        RecordEvent.call(
          turn: turn,
          event_type: "recovery_attempted",
          actor: actor,
          metadata: {
            "action" => action,
            "source" => source,
            "requires_confirmation" => safety.requires_confirmation?,
            "side_effecting_tool_names" => turn.evidence.side_effecting_tool_names,
            "in_flight_tool_name" => turn.evidence.in_flight_tool_name,
            "reasons" => safety.reasons
          }
        )
      end

      def record_duplicate_prevented(reason)
        RecordEvent.call(
          turn: turn,
          event_type: "duplicate_prevented",
          outcome: "duplicate",
          actor: actor,
          metadata: { "reason" => reason, "action" => action, "source" => source }
        )
      end
    end
  end
end
