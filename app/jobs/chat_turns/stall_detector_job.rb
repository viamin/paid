# frozen_string_literal: true

module ChatTurns
  # Detects chat turns with no durable activity beyond the configured
  # threshold (#4680): the sweep counterpart to StaleRunDetectorJob. Exempts
  # turns deliberately paused for a write-tool confirmation (a legitimate
  # wait, not a stall). For a turn that never touched a write tool, attempts
  # one bounded automatic recovery; otherwise persists an in-transcript
  # notice with a manual Resume action. Scheduled every 5 minutes via GoodJob
  # cron.
  class StallDetectorJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "chat_turns_stall_detector"
    )

    STALL_THRESHOLD = ->() { ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 180).to_i.seconds }

    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale(before: STALL_THRESHOLD.call.ago).find_each do |turn|
          detected += 1 if process_turn(turn)
        end
      end

      Rails.logger.info(message: "chat_turns.stall_detector_complete", detected_count: detected) if detected > 0
    end

    private

    def process_turn(turn)
      TenantContext.with(turn.chat_session.account) { recover_or_notify(turn) }
    rescue StandardError => e
      Rails.logger.error(
        message: "chat_turns.stall_detector_failed",
        chat_turn_id: turn.id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    # @spec CHAT-TURN-RECOVERY-002
    def recover_or_notify(turn)
      turn.with_lock do
        turn.reload
        return false unless turn.status.in?(ChatTurn::ACTIVE_STATUSES)
        return false if turn.last_activity_at > STALL_THRESHOLD.call.ago
        return false if turn.awaiting_confirmation?
        return false if turn.expected_long_running?

        turn.mark_stalled!
        automatic = attempt_automatic_recovery(turn)
        notice = ChatTurns::PersistStallNotice.call(chat_turn: turn, automatic_recovery_attempted: automatic)
        broadcast_persisted_message(turn.chat_session, notice)
      end
      true
    end

    # @spec CHAT-TURN-RECOVERY-004
    def attempt_automatic_recovery(turn)
      return false unless turn.eligible_for_automatic_recovery?
      return false unless turn.claim_recovery!(triggered_by: "automatic")

      ChatTurns::RecoverStalledTurnJob.perform_later(chat_turn_id: turn.id, triggered_by: "automatic")
      true
    end

    def broadcast_persisted_message(chat_session, message)
      ActionCable.server.broadcast("chat_session:#{chat_session.id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        html: ApplicationController.render(
          partial: "chat_messages/message",
          locals: { message: message }
        )
      })
    end
  end
end
