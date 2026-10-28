# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def retry
    # @spec CHAT-TURN-002
    chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
    authorize ChatMessage.new(chat_session:), :create?, policy_class: ChatMessagePolicy
    turn = chat_session.chat_turns.find(params[:id])
    ChatTurns::Retry.call(chat_turn: turn, actor: current_user)

    redirect_to chat_session_path(chat_session), notice: "Retrying the saved chat turn."
  rescue ChatTurns::Retry::UnsafeRecoveryError => e
    redirect_to chat_session_path(chat_session), alert: e.message
  end
end
