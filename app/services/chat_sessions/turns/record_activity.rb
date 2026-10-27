# frozen_string_literal: true

module ChatSessions
  module Turns
    # Records durable activity on the session's open turn.
    #
    # Every assistant or tool row the agent loop persists counts as activity,
    # so the stall detector sees a turn that is still producing work instead of
    # one that stopped.
    class RecordActivity
      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:, message:)
        @chat_session = chat_session
        @message = message
      end

      def call
        turn = ChatTurn.active_for(chat_session)
        return nil unless turn

        turn.apply_update!(
          status: "streaming",
          last_activity_at: activity_at,
          checkpoint_message_id: message.id
        )
      end

      private

      attr_reader :chat_session, :message

      def activity_at
        message.created_at || Time.current
      end
    end
  end
end
