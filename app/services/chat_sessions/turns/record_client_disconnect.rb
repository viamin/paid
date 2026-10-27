# frozen_string_literal: true

module ChatSessions
  module Turns
    # Records that the browser disconnected while a turn was in flight.
    #
    # The browser's transient `disconnectedMidTurn` flag is not durable
    # evidence; the ActionCable unsubscribe is.
    class RecordClientDisconnect
      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:)
        @chat_session = chat_session
      end

      def call
        turn = ChatTurn.active_for(chat_session)
        return nil unless turn
        return turn if turn.client_disconnected?

        turn.apply_update!(metadata: turn.metadata.merge("client_disconnect" => true))
        RecordEvent.call(
          turn: turn,
          event_type: "user_action",
          metadata: { "action" => "client_disconnect" }
        )
        turn
      end

      private

      attr_reader :chat_session
    end
  end
end
