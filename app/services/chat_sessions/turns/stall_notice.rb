# frozen_string_literal: true

module ChatSessions
  module Turns
    # Builds and persists the in-transcript notice for a stalled chat turn.
    #
    # The notice explains what completed, what is still unknown, and why the
    # turn needs attention. It never replaces or hides the partial tool
    # evidence the turn produced, and it never claims the turn succeeded.
    class StallNotice
      Result = Data.define(:content, :metadata)

      def self.call(...)
        new(...).call
      end

      def initialize(turn:)
        @turn = turn
      end

      def call
        message = chat_session.messages.create!(
          role: "system",
          content: content,
          metadata: metadata
        )
        message
      end

      private

      attr_reader :turn

      def chat_session
        turn.chat_session
      end

      def evidence
        turn.evidence
      end

      def content
        [
          "This turn stopped before it produced an answer, so nothing after the last saved step is known.",
          completed_summary,
          unknown_summary,
          "Resume continues from the last saved step and does not repeat the work that already completed."
        ].compact.join(" ")
      end

      def completed_summary
        names = evidence.completed_tool_names
        return "No tool action completed before the turn stopped." if names.empty?

        "Completed before the stop: #{names.map { |name| "`#{name}`" }.join(", ")}."
      end

      def unknown_summary
        name = evidence.in_flight_tool_name
        return "The final answer was never recorded." if name.blank?

        "`#{name}` was still running when the turn stopped, so its result is unknown."
      end

      def metadata
        {
          "stalled_turn_notice" => true,
          "turn_id" => turn.id,
          "stall_classification" => turn.stall_classification,
          "detected_at" => turn.detected_at&.iso8601,
          "completed_tool_names" => evidence.completed_tool_names,
          "side_effecting_tool_names" => evidence.side_effecting_tool_names,
          "in_flight_tool_name" => evidence.in_flight_tool_name,
          "pending_confirmation_message_ids" => pending_confirmation_message_ids,
          "agent_run_ids" => agent_run_ids,
          "recovery" => recovery_metadata
        }
      end

      def recovery_metadata
        safety = ReplaySafety.for(turn)
        {
          "action" => "resume",
          "requires_confirmation" => safety.requires_confirmation?,
          "revision" => turn.lock_version,
          "automatic" => safety.automatic_recovery_permitted?
        }
      end

      def pending_confirmation_message_ids
        chat_session.messages.pending_tool_confirmations.order(:id).pluck(:id)
      end

      # Agent runs the turn already triggered: the user can follow the work
      # itself instead of reading only the chat transcript.
      def agent_run_ids
        chat_session.messages
          .where(role: "tool", tool_name: "trigger_agent_run")
          .filter_map { |message| message.tool_result&.dig("id") }
          .uniq
      end
    end
  end
end
