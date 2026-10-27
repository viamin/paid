# frozen_string_literal: true

module ChatSessions
  module Turns
    # Opens the durable turn for a persisted user message.
    #
    # The user message is the unit of work: everything the platform does to
    # answer it belongs to one turn, so "did this exchange reach a conclusion?"
    # is answerable without reconstructing it from the transcript.
    class Open
      def self.call(...)
        new(...).call
      end

      def initialize(chat_session:, user_message:)
        @chat_session = chat_session
        @user_message = user_message
      end

      def call
        chat_session.chat_turns.create!(
          user_message: user_message,
          status: "pending",
          started_at: Time.current,
          last_activity_at: Time.current
        )
      end

      private

      attr_reader :chat_session, :user_message
    end
  end
end
