# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  # @spec CHAT-API-030 CHAT-API-031
  def recover
    turn = policy_scope(ChatSession).find(params[:chat_session_id]).chat_turns.find(params[:id])
    authorize ChatMessage.new(chat_session: turn.chat_session), :create?, policy_class: ChatMessagePolicy
    result = ChatTurns::RequestRecovery.call(turn:, actor: current_user,
      expected_revision: params.require(:revision))
    redirect_to chat_session_path(turn.chat_session),
      notice: ("Recovery queued." if result.success?), alert: result.error
  end
end
