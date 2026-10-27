# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  before_action :set_chat_session

  # The first release only replays a turn with no tool evidence at all. A
  # transcript is not an idempotency contract for arbitrary tools.
  # @spec CHAT-TURN-003
  def resume
    turn = @chat_session.chat_turns.find(params[:id])
    authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
    return redirect_to(@chat_session, alert: "Confirm recovery before continuing.") unless ActiveModel::Type::Boolean.new.cast(params[:confirmed])

    stream_message_id = nil
    turn.with_lock do
      return redirect_to @chat_session, alert: "This turn is no longer available for recovery." unless turn.status == "stalled"
      return redirect_to @chat_session, alert: "This turn has already used its single safe recovery attempt." if turn.recovery_attempts.positive?
      return redirect_to @chat_session, alert: "Review completed tool activity before sending a new request." if tool_activity?(turn)

      stream_message_id = turn.initiating_message.metadata.fetch("stream_message_id", SecureRandom.uuid)
      turn.initiating_message.update!(metadata: turn.initiating_message.metadata.merge("stream_message_id" => stream_message_id))
      turn.update!(status: "streaming", recovery_attempts: turn.recovery_attempts + 1, activity_at: Time.current)
    end
    ActionCable.server.broadcast("chat_session:#{@chat_session.id}", { type: "message_start", message_id: stream_message_id })
    ChatSessions::ProcessMessageJob.perform_later(
      chat_session_id: @chat_session.id,
      actor_id: current_user.id,
      content: turn.initiating_message.content,
      stream_message_id:
    )
    redirect_to @chat_session, notice: "Recovery started from the preserved user message."
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def tool_activity?(turn)
    @chat_session.messages.where("id > ?", turn.initiating_message_id)
      .where("role = ? OR tool_name IS NOT NULL", "tool").exists?
  end
end
