# frozen_string_literal: true

module ChatTurns
  class ClassifyStalled
    def self.call(...) = new(...).call

    def initialize(turn:, cutoff: ChatTurns::StallSweepJob.stall_threshold.ago)
      @turn = turn
      @cutoff = cutoff
    end

    # @spec CHAT-API-028 CHAT-API-029 CHAT-API-032
    def call
      notice = nil
      turn.with_lock do
        turn.reload
        return false unless eligible?

        notice = create_notice
        turn.update!(status: "stalled", stall_classification: "inactivity_timeout",
          stalled_at: Time.current, notice_message: notice,
          audit_events: turn.audit_events + [ audit_event ])
      end
      broadcast(notice)
      true
    end

    private

    attr_reader :turn, :cutoff

    def eligible?
      turn.status.in?(ChatTurn::EXECUTING_STATUSES) && turn.last_activity_at <= cutoff &&
        (turn.lease_expires_at.nil? || turn.lease_expires_at <= Time.current)
    end

    def create_notice
      turn.chat_session.messages.create!(role: "system", content: notice_content, metadata: {
        "stalled_turn_notice" => true,
        "chat_turn_id" => turn.id,
        "chat_turn_revision" => turn.lock_version + 1,
        "checkpoint" => turn.checkpoint,
        "side_effecting_tools_completed" => turn.side_effecting_tools_completed
      })
    end

    def notice_content
      completed = turn.checkpoint["last_message_id"] ? "Progress through message ##{turn.checkpoint['last_message_id']} was saved." : "The request was saved."
      side_effects = turn.side_effecting_tools_completed ? "At least one side-effecting tool completed." : "No completed side-effecting tool is recorded."
      "This chat turn stopped without a final response. #{completed} #{side_effects} The remaining outcome is unknown; review the transcript before resuming."
    end

    def audit_event
      { "event" => "stalled", "at" => Time.current.iso8601,
        "classification" => "inactivity_timeout",
        "side_effecting_tools_completed" => turn.side_effecting_tools_completed }
    end

    def broadcast(message)
      ActionCable.server.broadcast("chat_session:#{turn.chat_session_id}", {
        type: "message_created", message_id: message.id, role: message.role,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: })
      })
    end
  end
end
