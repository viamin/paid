# frozen_string_literal: true

module ChatSessions
  module Turns
    # Classifies a stalled chat turn from durable evidence only.
    #
    # The detector runs long after the worker that owned the turn is gone, so
    # anything it inferred about intent would be a guess presented to the user
    # as fact. Every classification below is backed by a recorded signal.
    class Classify
      BY_FAILURE_CLASS = {
        "infrastructure_failure" => "infrastructure_failure",
        "provider_timeout" => "provider_timeout",
        "token_limit" => "budget_exhausted"
      }.freeze

      def self.for(turn)
        new(turn).call
      end

      def initialize(turn)
        @turn = turn
      end

      def call
        BY_FAILURE_CLASS.fetch(turn.failure_class) do
          turn.client_disconnected? ? "client_disconnect" : "model_stop"
        end
      end

      private

      attr_reader :turn
    end
  end
end
