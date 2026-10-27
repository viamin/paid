# frozen_string_literal: true

class ChatTurnRecoveriesController < ApplicationController
  def create
    chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
    turn = chat_session.chat_turns.find(params[:chat_turn_id])
    authorize ChatMessage.new(chat_session:)

    ChatTurns::Recover.call(turn:, actor: current_user)
    redirect_to chat_session_path(chat_session), notice: "Chat recovery was queued."
  rescue ChatTurns::Recover::UnsafeReplayError => e
    redirect_to chat_session_path(chat_session), alert: e.message
  end
end
