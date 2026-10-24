# frozen_string_literal: true

module ChatInvestigations
  class Broadcast
    def self.call(investigation)
      ActionCable.server.broadcast("chat_session:#{investigation.chat_session_id}", {
        type: "investigation_updated",
        investigation_id: investigation.id,
        question_position: investigation.clarifying_question_progress.position,
        status: investigation.status,
        result: investigation.result,
        progress: investigation.metadata["progress"]
      }.compact)
    end
  end
end
