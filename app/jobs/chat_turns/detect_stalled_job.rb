# frozen_string_literal: true

module ChatTurns
  class DetectStalledJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency
    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled"
    # @spec CHAT-TURN-001 CHAT-TURN-003
    def perform
      TenantContext.with_system_access { ChatTurn.incomplete.includes(:chat_session).find_each { |turn| classify(turn) } }
    end
    private
    def classify(turn)
      turn.with_lock do
        return unless turn.status.in?(%w[pending streaming]) && !turn.pending_confirmation? && !turn.chat_session.rate_limited?
        return unless turn.last_activity_at < ChatTurns::Lifecycle::STALL_TIMEOUT.ago
        turn.update!(status: "stalled", detected_at: Time.current, terminal_at: Time.current)
        notice = turn.chat_session.messages.create!(role: "system", content: notice_content(turn), metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "side_effecting_tools_completed" => turn.side_effecting_tools_completed? })
        ActionCable.server.broadcast("chat_session:#{turn.chat_session_id}", type: "message_created", message_id: notice.id, role: notice.role, html: ApplicationController.render(partial: "chat_messages/message", locals: { message: notice }))
      end
    end
    def notice_content(turn)
      completed = turn.side_effecting_tools_completed? ? "Some tool work completed; its result is preserved above." : "No completed side-effecting tool call was recorded."
      "This chat turn stopped without a final assistant response. #{completed} What remains unknown was not represented as successful. Review the preserved tool activity before explicitly retrying."
    end
  end
end
