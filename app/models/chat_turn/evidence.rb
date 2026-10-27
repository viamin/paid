# frozen_string_literal: true

class ChatTurn
  # Durable evidence about what a turn managed to do before it stopped,
  # computed from the persisted transcript only.
  #
  # The evidence answers the two questions a recovery must ask: which tool
  # calls already ran (so they are never blindly replayed), and which tool
  # call was in flight when the turn stopped (so its effect is unknown).
  class Evidence
    def initialize(turn, messages: nil)
      @turn = turn
      @messages = messages
    end

    # The tool call the turn dispatched whose result was never persisted. It
    # may already have had its effect, so replaying it needs either an
    # idempotent tool or an explicit human confirmation.
    def in_flight_tool_name
      pending_tool_call&.tool_name
    end

    # Tool calls whose result is persisted: these already ran.
    def completed_tool_names
      tool_result_messages.map(&:tool_name).compact.uniq
    end

    # The subset of completed tools that mutated something. A recovery that
    # repeats these must not happen without an explicit confirmation.
    def side_effecting_tool_names
      completed_tool_names.select { |name| Tools::Registry.write_tool?(name) }
    end

    def pending_tool_call
      tool_call_messages.find { |message| !completed_call_ids.include?(message.tool_call_id) }
    end

    private

    attr_reader :turn

    def tool_call_messages
      turn_messages.select { |message| message.role == "assistant" && message.tool_name.present? && message.content.blank? }
    end

    def tool_result_messages
      turn_messages.select { |message| message.role == "tool" }
    end

    def completed_call_ids
      @completed_call_ids ||= tool_result_messages.filter_map(&:tool_call_id)
    end

    # The turn's own rows: everything from the user message that opened it up
    # to the checkpoint it last recorded. Rows from a later turn in the same
    # session are excluded, so evidence never mixes two turns.
    def turn_messages
      @messages ||= begin
        scope = turn.chat_session.messages.order(:id)
        scope = scope.where("id >= ?", turn.user_message_id) if turn.user_message_id
        scope = scope.where("id <= ?", turn.checkpoint_message_id) if turn.checkpoint_message_id
        scope.to_a
      end
    end
  end
end
