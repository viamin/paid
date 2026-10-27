# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  # @spec CHAT-TURN-RECOVERY-003
  def retry
    turn = policy_scope(ChatSession).joins(:chat_turns).find_by!(chat_turns: { id: params[:id] }).chat_turns.find(params[:id])
    authorize ChatMessage.new(chat_session: turn.chat_session), :create?, policy_class: ChatMessagePolicy

    claimed = ChatTurn.where(id: turn.id, status: "stalled", side_effecting_tool_completed: false)
      .update_all(status: "streaming", recovery_attempts: turn.recovery_attempts + 1, last_activity_at: Time.current)
    return redirect_to chat_session_path(turn.chat_session), alert: "This turn is already being recovered or needs manual review." if claimed.zero?

    ChatSessions::ProcessMessageJob.perform_later(
      chat_session_id: turn.chat_session_id,
      actor_id: current_user.id,
      content: turn.user_message.content,
      stream_message_id: turn.stream_message_id
    )
    redirect_to chat_session_path(turn.chat_session), notice: "Retry queued from the preserved turn checkpoint."
  end
end
