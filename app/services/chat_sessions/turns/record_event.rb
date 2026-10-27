# frozen_string_literal: true

module ChatSessions
  module Turns
    # Appends an auditable row to a chat turn's event trail.
    #
    # The trail is the queryable record behind stall rate, recovery success
    # rate, abandoned-turn rate, and duplicate-prevention counts.
    class RecordEvent
      def self.call(...)
        new(...).call
      end

      def initialize(turn:, event_type:, outcome: nil, actor: nil, metadata: {})
        @turn = turn
        @event_type = event_type
        @outcome = outcome
        @actor = actor
        @metadata = metadata
      end

      def call
        turn.chat_turn_events.create!(
          chat_session_id: turn.chat_session_id,
          event_type: event_type,
          outcome: outcome,
          actor_id: actor&.id,
          metadata: metadata
        )
      end

      private

      attr_reader :turn, :event_type, :outcome, :actor, :metadata
    end
  end
end
