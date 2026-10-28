# frozen_string_literal: true

module ChatTurns
  # Read-only view over the durable evidence a chat turn produced: the messages
  # persisted between the turn's user message and the next turn's user message.
  #
  # The transcript is the checkpoint a stalled turn is recovered from, and the
  # evidence the stall classifier reasons over. It never mutates state.
  class Transcript
    attr_reader :turn

    def initialize(turn)
      @turn = turn
    end

    def self.call(turn)
      new(turn)
    end

    def messages
      @messages ||= turn_messages.to_a
    end

    def chat_session
      turn.chat_session
    end

    # A turn is waiting on a human decision when it left a write-tool
    # confirmation behind.
    # @spec CHAT-TURN-RECOVERY-005
    def pending_confirmation?
      messages.any?(&:pending_confirmation?)
    end

    def pending_confirmation_messages
      messages.select(&:pending_confirmation?)
    end

    # The turn ran out of its token budget and stopped for a reason the
    # platform already explains in the transcript.
    # @spec CHAT-TURN-RECOVERY-006
    def token_limit_exhausted?
      messages.any?(&:token_limit_error?)
    end

    # The provider ended the turn with an error the platform already reported.
    # @spec CHAT-TURN-RECOVERY-006
    def provider_error?
      messages.any?(&:provider_error_notice?)
    end

    # The model produced something before the turn stopped — an answer, a tool
    # call, or a tool result. A turn with no output at all failed before the
    # model ever answered.
    def partial_output?
      messages.any? do |message|
        next true if message.role == "tool"

        message.role == "assistant" && (message.content.present? || message.tool_name.present?)
      end
    end

    def assistant_messages
      messages.select { |message| message.role == "assistant" }
    end

    def tool_call_messages
      messages.select { |message| message.tool_name.present? }
    end

    def tool_result_messages
      messages.select { |message| message.role == "tool" }
    end

    # Write (side-effecting) tool calls observed inside the turn.
    def write_tool_calls
      tool_call_messages.select { |message| Tools::Registry.write_tool?(message.tool_name) }
    end

    def side_effecting_tools_completed?
      write_tool_calls.any? do |message|
        completed_tool_results.key?(message.tool_call_id) ||
          message.tool_status.in?(%w[approved denied])
      end
    end

    # Tool calls that already produced a result inside this turn, keyed by
    # provider tool-call id. Recovery replays the persisted result instead of
    # dispatching the tool again.
    # @spec CHAT-TURN-RECOVERY-010
    def completed_tool_results
      @completed_tool_results ||= tool_result_messages.each_with_object({}) do |message, results|
        next if message.tool_call_id.blank?

        results[message.tool_call_id] = message.tool_result
      end
    end

    # Signatures of the side-effecting tool calls that already completed inside
    # this turn. A recovered turn must never run one of them again.
    # @spec CHAT-TURN-RECOVERY-010
    def completed_side_effect_signatures
      @completed_side_effect_signatures ||= write_tool_calls.filter_map do |message|
        next unless completed_tool_results.key?(message.tool_call_id)

        ChatTurns::ReplayGuard.signature(message.tool_name, message.tool_arguments)
      end.to_set
    end

    # True when the turn's last tool call is one that may legitimately run for
    # a long time, so a quiet turn is not automatically a stall.
    # @spec CHAT-TURN-RECOVERY-006
    def long_running_operation?
      last_tool_call = tool_call_messages.last
      return false unless last_tool_call

      Tools::Registry.long_running?(last_tool_call.tool_name)
    end

    def tool_names
      tool_call_messages.map(&:tool_name).compact.uniq
    end

    def rate_limited?
      chat_session.rate_limited_until.present? && chat_session.rate_limited_until > Time.current
    end

    private

    # Messages persisted after the turn's user message and before the next
    # turn's user message, so a turn never absorbs a later turn's evidence.
    def turn_messages
      scope = chat_session.messages.chronological.where("chat_messages.id > ?", turn.user_message_id)
      upper = next_turn_user_message_id
      scope = scope.where("chat_messages.id < ?", upper) if upper
      scope
    end

    def next_turn_user_message_id
      chat_session.chat_turns
        .where("user_message_id > ?", turn.user_message_id)
        .order(:user_message_id)
        .limit(1)
        .pick(:user_message_id)
    end
  end
end
