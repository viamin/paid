# frozen_string_literal: true

module ChatTurns
  # Builds and persists the in-transcript system notice that explains a stalled
  # or abandoned turn: what completed, what is still unknown, why the turn
  # needs attention, and how to recover it safely.
  #
  # @spec CHAT-TURN-RECOVERY-007
  class StallNotice
    Result = Data.define(:message, :content, :metadata)

    def self.call(turn:, transcript:, classification:, explanation: nil)
      new(turn:, transcript:, classification:, explanation:).call
    end

    def initialize(turn:, transcript:, classification:, explanation: nil)
      @turn = turn
      @transcript = transcript
      @classification = classification
      @explanation = explanation
    end

    def call
      message = chat_session.messages.create!(role: "system", content: content, metadata: metadata)
      Result.new(message:, content:, metadata:)
    end

    # A turn publishes at most one notice: a second classification of the same
    # turn must not stack another explanation on the transcript.
    def self.already_published?(turn)
      turn.chat_session.messages
        .where("metadata ->> 'chat_turn_id' = ?", turn.id.to_s)
        .exists?
    end

    private

    attr_reader :turn, :transcript, :classification, :explanation

    def chat_session
      turn.chat_session
    end

    def content
      [
        headline,
        completed_section,
        unknown_section,
        reason_section,
        guidance_section
      ].compact.join("\n\n")
    end

    def headline
      "This turn stopped without a final answer, so it needs your attention."
    end

    def completed_section
      completed = transcript.tool_names
      return "Completed before it stopped: nothing was recorded as completed." if completed.empty?

      "Completed before it stopped:\n#{completed.map { |name| "- #{name}" }.join("\n")}"
    end

    def unknown_section
      "Still unknown: whether the assistant finished its answer, and the result of any action that had not completed."
    end

    def reason_section
      "Why this needs attention: #{explanation || default_explanation}"
    end

    def guidance_section
      if turn.replay_safe?
        "You can resume this turn: it continues from the last recorded step and does not repeat completed actions."
      else
        "This turn already ran a write action. Resuming needs your confirmation, and completed actions are not repeated."
      end
    end

    def default_explanation
      case classification
      when "ambiguous_model_stop" then "the model stopped before producing a final answer."
      else "no activity was recorded after the message was sent."
      end
    end

    def metadata
      {
        "stalled_turn_notice" => true,
        "chat_turn_id" => turn.id,
        "turn_state" => turn.state,
        "classification" => classification,
        "revision" => turn.revision,
        "completed_tool_names" => transcript.tool_names,
        "tool_message_ids" => transcript.tool_call_messages.map(&:id),
        "side_effecting_tools_completed" => turn.side_effecting_tools_completed,
        "replay_safe" => turn.replay_safe?
      }
    end
  end
end
