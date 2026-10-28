# frozen_string_literal: true

module ChatTurns
  class Stall
    NOTICE = "This turn stopped without a final response. Completed tool activity is preserved below; no unfinished action was treated as successful. Review the tool results, then explicitly resume only if it is safe to continue."

    def self.call(...)
      new(...).call
    end

    def initialize(turn:)
      @turn = turn
    end

    def call
      @turn.with_lock do
        return @turn unless @turn.status.in?(%w[pending streaming]) && !@turn.awaiting_confirmation?

        @turn.update!(status: "stalled", classification: "no_durable_activity", stalled_at: Time.current)
        notice = @turn.chat_session.messages.create!(role: "system", content: NOTICE,
          metadata: { "stalled_turn_notice" => true, "chat_turn_id" => @turn.id,
                      "checkpoint_message_id" => @turn.checkpoint_message_id,
                      "resumable" => @turn.resumable? })
        @turn.record!("stalled", checkpoint_message_id: notice.id)
      end
    end
  end
end
