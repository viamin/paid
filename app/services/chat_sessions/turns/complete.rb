# frozen_string_literal: true

module ChatSessions
  module Turns
    # Marks the session's open turn as completed.
    #
    # Only a terminal assistant response completes a turn: a stalled turn is
    # never recorded as successful on the strength of partial evidence.
    class Complete
      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:)
        @chat_session = chat_session
      end

      def call
        turn = ChatTurn.active_for(chat_session)
        return nil unless turn

        now = Time.current
        turn.apply_update!(
          { status: "completed", completed_at: now, last_activity_at: now },
          guard: { status: ChatTurn::ACTIVE_STATUSES }
        )
      end

      private

      attr_reader :chat_session
    end
  end
end
