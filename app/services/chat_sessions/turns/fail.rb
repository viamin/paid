# frozen_string_literal: true

module ChatSessions
  module Turns
    # Marks the session's open turn as failed and records why.
    #
    # A failure is a terminal conclusion, not a stall: the user was told the
    # turn failed. A turn that stops without any conclusion at all is what the
    # stall detector looks for.
    class Fail
      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:, error:)
        @chat_session = chat_session
        @error = error
      end

      def call
        turn = ChatTurn.active_for(chat_session)
        return nil unless turn

        now = Time.current
        turn.apply_update!(
          {
            status: "failed",
            failure_class: ClassifyFailure.for(error),
            completed_at: now,
            last_activity_at: now
          },
          guard: { status: ChatTurn::ACTIVE_STATUSES }
        )
      end

      private

      attr_reader :chat_session, :error
    end
  end
end
